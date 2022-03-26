#!/bin/bash

##
## This script brings up a Hyperledger Fabric network for testing the cross-chain design
##

## Import external scripts

. scripts/utils.sh

## Set working directory and some global or local variables

# Prepending $PWD/../bin to PATH to ensure we are picking up the correct binaries
# This may be commented out to resolve installed version of tools if desired
ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
export PATH=$PATH:${ROOT_DIR}/../bin:${PWD}/../bin
# Specify the config directory
export FABRIC_CFG_PATH=${PWD}/configtx
# Use verbose mode or not
export VERBOSE=false
# Specify Docker CLI name
: "${CONTAINER_CLI:="docker"}"
: "${CONTAINER_CLI_COMPOSE:="${CONTAINER_CLI}-compose"}"
#infoln "Using ${CONTAINER_CLI} and ${CONTAINER_CLI_COMPOSE}"

# Push to the required directory & set a trap to go back if needed
pushd "${ROOT_DIR}" >/dev/null || exit
trap "popd > /dev/null" EXIT

## Define some functions

# Do some basic sanity checking to make sure that the appropriate versions of fabric binaries/images are available.
function checkPrereqs() {
  # Check if the peer binaries and configuration files have been installed.
  if ! peer version >/dev/null 2>&1 || [ ! -d "../config" ]; then
    errorln "Peer binary and configuration files not found..."
    exit 1
  fi
  # Check if the peer binaries match your docker images
  local LOCAL_VERSION
  LOCAL_VERSION=$(peer version | sed -ne 's/^ Version: //p')
  local DOCKER_IMAGE_VERSION
  DOCKER_IMAGE_VERSION=$(${CONTAINER_CLI} run --rm hyperledger/fabric-tools:latest peer version | sed -ne 's/^ Version: //p')

  infoln "LOCAL_VERSION=$LOCAL_VERSION"
  infoln "DOCKER_IMAGE_VERSION=$DOCKER_IMAGE_VERSION"
  if [ "$LOCAL_VERSION" != "$DOCKER_IMAGE_VERSION" ]; then
    warnln "Local fabric binaries and docker images are out of sync. This may cause problems."
  fi

  # Check for fabric-ca if used
  if [ "$CRYPTO" == "Certificate Authorities" ]; then
    # Check if the fabric-ca binaries have been installed.
    if ! fabric-ca-client version >/dev/null 2>&1; then
      errorln "fabric-ca-client binary not found..."
      exit 1
    fi
    # Check if the fabric-ca binaries match your docker images
    local CA_LOCAL_VERSION
    CA_LOCAL_VERSION=$(fabric-ca-client version | sed -ne 's/ Version: //p')
    local CA_DOCKER_IMAGE_VERSION
    CA_DOCKER_IMAGE_VERSION=$(docker run --rm hyperledger/fabric-ca:latest fabric-ca-client version | sed -ne 's/ Version: //p' | head -1)

    infoln "CA_LOCAL_VERSION=$CA_LOCAL_VERSION"
    infoln "CA_DOCKER_IMAGE_VERSION=$CA_DOCKER_IMAGE_VERSION"
    if [ "$CA_LOCAL_VERSION" != "$CA_DOCKER_IMAGE_VERSION" ]; then
      warnln "Local fabric-ca binaries and docker images are out of sync. This may cause problems."
    fi
  fi
}

# Before you can bring up a network, each organization needs to generate the crypto
# material that will define that organization on the network. Because Hyperledger
# Fabric is a permissioned blockchain, each node and user on the network needs to
# use certificates and keys to sign and verify its actions. In addition, each user
# needs to belong to an organization that is recognized as a member of the network.
# You can use the Cryptogen tool or Fabric CAs to generate the organization crypto
# material.

# By default, the sample network uses cryptogen. Cryptogen is a tool that is
# meant for development and testing that can quickly create the certificates and keys
# that can be consumed by a Fabric network. The cryptogen tool consumes a series
# of configuration files for each organization in the "organizations/cryptogen"
# directory. Cryptogen uses the files to generate the crypto material for each
# org in the "organizations" directory.

# You can also use Fabric CAs to generate the crypto material. CAs sign the certificates
# and keys that they generate to create a valid root of trust for each organization.
# The script uses Docker Compose to bring up three CAs, one for each peer organization
# and the ordering organization. The configuration file for creating the Fabric CA
# servers are in the "organizations/fabric-ca" directory. Within the same directory,
# the "registerEnroll.sh" script uses the Fabric CA client to create the identities,
# certificates, and MSP folders that are needed to create the test network in the
# "organizations/ordererOrganizations" directory.

## ! To simplify the demo, only use the crypto rather than CAs

# Create Organization crypto material using cryptogen
function createOrgs() {

  # Clean up artifacts created by previous run
  if [ -d "organizations/peerOrganizations" ] || [ -d "organizations/ordererOrganizations" ]; then
    rm -Rf organizations/peerOrganizations && rm -Rf organizations/ordererOrganizations
  fi

  # Create crypto material using cryptogen
  if [ "$CRYPTO" == "cryptogen" ]; then

    if ! which cryptogen >/dev/null 2>&1; then
      fatalln "cryptogen tool not found. exiting"
    fi

    infoln "Generating certificates using cryptogen tool"

    infoln "Creating Org1 Identities"
    if ! cryptogen generate --config=./organizations/cryptogen/crypto-config-org1.yaml --output="organizations"; then
      fatalln "Failed to generate certificates..."
    fi

    infoln "Creating Org2 Identities"
    if ! cryptogen generate --config=./organizations/cryptogen/crypto-config-org2.yaml --output="organizations"; then
      fatalln "Failed to generate certificates..."
    fi

    infoln "Creating Orderer Org Identities"
    if ! cryptogen generate --config=./organizations/cryptogen/crypto-config-orderer.yaml --output="organizations"; then
      fatalln "Failed to generate certificates..."
    fi
  fi

  infoln "Generating CCP files for Org1 and Org2"
  ./organizations/ccp-generate.sh
}

# Once you create the organization crypto material, you need to create the
# genesis block of the application channel.

# The configtxgen tool is used to create the genesis block. Configtxgen consumes a
# "configtx.yaml" file that contains the definitions for the sample network. The
# genesis block is defined using the "TwoOrgsApplicationGenesis" profile at the bottom
# of the file. This profile defines an application channel consisting of our two Peer Orgs.
# The peer and ordering organizations are defined in the "Profiles" section at the
# top of the file. As part of each organization profile, the file points to the
# location of the MSP directory for each member. This MSP is used to create the channel
# MSP that defines the root of trust for each organization. In essence, the channel
# MSP allows the nodes and users to be recognized as network members.
#
# If you receive the following warning, it can be safely ignored:
#
# [bccsp] GetDefault -> WARN 001 Before using BCCSP, please call InitFactories(). Falling back to bootBCCSP.
#
# You can ignore the logs regarding intermediate certs, we are not using them in
# this crypto implementation.

# After we create the org crypto material and the application channel genesis block,
# we can now bring up the peers and ordering service. By default, the base
# file for creating the network is "docker-compose-test-net.yaml" in the ``docker``
# folder. This file defines the environment variables and file mounts that
# point the crypto material and genesis block that were created in earlier.

# Bring up the peer and orderer nodes using docker compose.
function networkUp() {
  # Check prerequisites by calling checkPrereqs()
  checkPrereqs

  # Generate artifacts if they don't exist
  if [ ! -d "organizations/peerOrganizations" ]; then
    createOrgs
  fi

  local COMPOSE_FILES="-f compose/${COMPOSE_FILE_BASE} -f compose/${CONTAINER_CLI}/${CONTAINER_CLI}-${COMPOSE_FILE_BASE}"

  DOCKER_SOCK="${DOCKER_SOCK}" "${CONTAINER_CLI_COMPOSE}" "${COMPOSE_FILES}" up -d 2>&1
}

# Call the script to create the channel, join the peers of org1 and org2, and then update the anchor peers for each organization
function createChannel() {
  if ! scripts/createChannel.sh "$CHANNEL_NAME" "$CLI_DELAY" "$MAX_RETRY" "$VERBOSE"; then
    fatalln "Create channel failed"
  fi
}

## Call the script to deploy a chaincode to the channel
function deployCC() {
  if ! scripts/deployCC.sh "$CHANNEL_NAME" "$CC_NAME" "$CC_SRC_PATH" "$CC_SRC_LANGUAGE" "$CC_VERSION" "$CC_SEQUENCE" "$CC_INIT_FCN" "$CC_END_POLICY" "$CC_COLL_CONFIG" "$CLI_DELAY" "$MAX_RETRY" "$VERBOSE"; then
    fatalln "Deploying chaincode failed"
  fi
}

## Call the script to deploy a chaincode to the channel using CCaaS
function deployCCAAS() {
  if ! scripts/deployCCAAS.sh "$CHANNEL_NAME" "$CC_NAME" "$CC_SRC_PATH" "$CCAAS_DOCKER_RUN" "$CC_VERSION" "$CC_SEQUENCE" "$CC_INIT_FCN" "$CC_END_POLICY" "$CC_COLL_CONFIG" "$CLI_DELAY" "$MAX_RETRY" $VERBOSE "$CCAAS_DOCKER_RUN"; then
    fatalln "Deploying chaincode-as-a-service failed"
  fi
}

# Tear down running network
function networkDown() {

  # stop org3 containers also in addition to org1 and org2, in case we were running sample to add org3
  for descriptor in $COMPOSE_FILE_BASE $COMPOSE_FILE_COUCH $COMPOSE_FILE_CA; do #$COMPOSE_FILE_COUCH_ORG3 $COMPOSE_FILE_ORG3
    infoln "Decomposing $descriptor"
    if [ "${CONTAINER_CLI}" == "docker" ]; then
      DOCKER_SOCK=$DOCKER_SOCK ${CONTAINER_CLI_COMPOSE} -f compose/$descriptor -f compose/${CONTAINER_CLI}/${CONTAINER_CLI}-${descriptor} down --volumes --remove-orphans
    elif [ "${CONTAINER_CLI}" == "podman" ]; then
      ${CONTAINER_CLI_COMPOSE} -f compose/$descriptor -f compose/${CONTAINER_CLI}/${CONTAINER_CLI}-${descriptor} down --volumes
    else
      fatalln "Container CLI  ${CONTAINER_CLI} not supported"
    fi
  done

  # Don't remove the generated artifacts -- note, the ledgers are always removed
  if [ "$MODE" != "restart" ]; then
    # Bring down the network, deleting the volumes
    ${CONTAINER_CLI} volume rm docker_orderer.example.com docker_peer0.org1.example.com docker_peer0.org2.example.com
    # Cleanup the chaincode containers
    infoln "Removing remaining containers"
    ${CONTAINER_CLI} rm -f "$(${CONTAINER_CLI} ps -aq --filter label=service=hyperledger-fabric)" 2>/dev/null || true
    ${CONTAINER_CLI} rm -f "$(${CONTAINER_CLI} ps -aq --filter name='dev-peer*')" 2>/dev/null || true
    #Cleanup images
    infoln "Removing generated chaincode docker images"
    ${CONTAINER_CLI} image rm -f "$(${CONTAINER_CLI} images -aq --filter reference='dev-peer*')" 2>/dev/null || true
    #
    ${CONTAINER_CLI} kill $(${CONTAINER_CLI} ps -q --filter name=ccaas) || true
    # remove orderer block and other channel configuration transactions and certs
    ${CONTAINER_CLI} run --rm -v "$(pwd):/data" busybox sh -c 'cd /data && rm -rf system-genesis-block/*.block organizations/peerOrganizations organizations/ordererOrganizations'
    ## remove fabric ca artifacts
    ${CONTAINER_CLI} run --rm -v "$(pwd):/data" busybox sh -c 'cd /data && rm -rf organizations/fabric-ca/org1/msp organizations/fabric-ca/org1/tls-cert.pem organizations/fabric-ca/org1/ca-cert.pem organizations/fabric-ca/org1/IssuerPublicKey organizations/fabric-ca/org1/IssuerRevocationPublicKey organizations/fabric-ca/org1/fabric-ca-server.db'
    ${CONTAINER_CLI} run --rm -v "$(pwd):/data" busybox sh -c 'cd /data && rm -rf organizations/fabric-ca/org2/msp organizations/fabric-ca/org2/tls-cert.pem organizations/fabric-ca/org2/ca-cert.pem organizations/fabric-ca/org2/IssuerPublicKey organizations/fabric-ca/org2/IssuerRevocationPublicKey organizations/fabric-ca/org2/fabric-ca-server.db'
    ${CONTAINER_CLI} run --rm -v "$(pwd):/data" busybox sh -c 'cd /data && rm -rf organizations/fabric-ca/ordererOrg/msp organizations/fabric-ca/ordererOrg/tls-cert.pem organizations/fabric-ca/ordererOrg/ca-cert.pem organizations/fabric-ca/ordererOrg/IssuerPublicKey organizations/fabric-ca/ordererOrg/IssuerRevocationPublicKey organizations/fabric-ca/ordererOrg/fabric-ca-server.db'
    ${CONTAINER_CLI} run --rm -v "$(pwd):/data" busybox sh -c 'cd /data && rm -rf addOrg3/fabric-ca/org3/msp addOrg3/fabric-ca/org3/tls-cert.pem addOrg3/fabric-ca/org3/ca-cert.pem addOrg3/fabric-ca/org3/IssuerPublicKey addOrg3/fabric-ca/org3/IssuerRevocationPublicKey addOrg3/fabric-ca/org3/fabric-ca-server.db'
    # remove channel and script artifacts
    ${CONTAINER_CLI} run --rm -v "$(pwd):/data" busybox sh -c 'cd /data && rm -rf channel-artifacts log.txt *.tar.gz'
  fi
}

# Using crypto vs CA. default is cryptogen
CRYPTO="cryptogen"
# Timeout duration - the duration the CLI should wait for a response from another container before giving up
MAX_RETRY=5
# Default for delay between commands
CLI_DELAY=3
# Channel name defaults to "mychannel"
CHANNEL_NAME="mychannel"
# Chaincode name defaults to "NA"
CC_NAME="NA"
# Chaincode path defaults to "NA"
CC_SRC_PATH="NA"
# Endorsement policy defaults to "NA". This would allow chaincodes to use the majority default policy.
CC_END_POLICY="NA"
# Collection configuration defaults to "NA"
CC_COLL_CONFIG="NA"
# Chaincode init function defaults to "NA"
CC_INIT_FCN="NA"
# Use this as the default docker-compose yaml definition
COMPOSE_FILE_BASE=compose-test-net.yaml
# Chaincode language defaults to "NA"
CC_SRC_LANGUAGE="NA"
# Default to running the docker commands for the CCAAS
CCAAS_DOCKER_RUN=true
# Chaincode version
CC_VERSION="1.0"
# Chaincode definition sequence
CC_SEQUENCE=1
# Default database
DATABASE="leveldb"

# Get docker sock path from environment variable
SOCK="${DOCKER_HOST:-/var/run/docker.sock}"
DOCKER_SOCK="${SOCK##unix://}"

## Parse commandline args

# Parse mode
if [[ $# -lt 1 ]]; then
  printHelp
  exit 0
else
  MODE=$1
  shift
fi

# Parse a createChannel subcommand if used
if [[ $# -ge 1 ]]; then
  key="$1"
  if [[ "$key" == "createChannel" ]]; then
    export MODE="createChannel"
    shift
  fi
fi

# Parse flags

while [[ $# -ge 1 ]]; do
  key="$1"
  case $key in
  -h)
    printHelp $MODE
    exit 0
    ;;
  -c)
    CHANNEL_NAME="$2"
    shift
    ;;
  -ca)
    CRYPTO="Certificate Authorities"
    ;;
  -r)
    MAX_RETRY="$2"
    shift
    ;;
  -d)
    CLI_DELAY="$2"
    shift
    ;;
  -s)
    DATABASE="$2"
    shift
    ;;
  -ccl)
    CC_SRC_LANGUAGE="$2"
    shift
    ;;
  -ccn)
    CC_NAME="$2"
    shift
    ;;
  -ccv)
    CC_VERSION="$2"
    shift
    ;;
  -ccs)
    CC_SEQUENCE="$2"
    shift
    ;;
  -ccp)
    CC_SRC_PATH="$2"
    shift
    ;;
  -ccep)
    CC_END_POLICY="$2"
    shift
    ;;
  -cccg)
    CC_COLL_CONFIG="$2"
    shift
    ;;
  -cci)
    CC_INIT_FCN="$2"
    shift
    ;;
  -ccaasdocker)
    CCAAS_DOCKER_RUN="$2"
    shift
    ;;
  -verbose)
    VERBOSE=true
    ;;
  *)
    errorln "Unknown flag: $key"
    printHelp
    exit 1
    ;;
  esac
  shift
done

# Are we generating crypto material with this command?
if [ ! -d "organizations/peerOrganizations" ]; then
  CRYPTO_MODE="with crypto from '${CRYPTO}'"
else
  CRYPTO_MODE=""
fi

# Determine mode of operation and printing out what we asked for
if [ "$MODE" == "up" ]; then
  infoln "Starting nodes with CLI timeout of '${MAX_RETRY}' tries and CLI delay of '${CLI_DELAY}' seconds and using database '${DATABASE}' ${CRYPTO_MODE}"
  networkUp
elif [ "$MODE" == "createChannel" ]; then
  infoln "Creating channel '${CHANNEL_NAME}'."
  infoln "If network is not up, starting nodes with CLI timeout of '${MAX_RETRY}' tries and CLI delay of '${CLI_DELAY}' seconds and using database '${DATABASE} ${CRYPTO_MODE}"
  createChannel
elif [ "$MODE" == "down" ]; then
  infoln "Stopping network"
  networkDown
elif [ "$MODE" == "restart" ]; then
  infoln "Restarting network"
  networkDown
  networkUp
elif [ "$MODE" == "deployCC" ]; then
  infoln "deploying chaincode on channel '${CHANNEL_NAME}'"
  deployCC
elif [ "$MODE" == "deployCCAAS" ]; then
  infoln "deploying chaincode-as-a-service on channel '${CHANNEL_NAME}'"
  deployCCAAS
else
  printHelp
  exit 1
fi
