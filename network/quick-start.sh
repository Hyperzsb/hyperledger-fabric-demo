#!/bin/bash

#
# All-in-one script to quick start the Hyperledger Fabric demo network
# To simplify the demo, this script remove unnecessary check and rollback functions
#

. scripts/utils.sh

# Get docker sock path from environment variable
SOCK="${DOCKER_HOST:-/var/run/docker.sock}"
DOCKER_SOCK="${SOCK##unix://}"

# * Step 1: generate crypto materials of organizations using cryptogen tool

createOrgsUsingCryptogen() {
  # Clean up artifacts created by previous run
  if [ -d "organizations/peerOrganizations" ] || [ -d "organizations/ordererOrganizations" ]; then
    rm -Rf organizations/peerOrganizations && rm -Rf organizations/ordererOrganizations
  fi
  # Generate crypto materials
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

  infoln "Generating CCP files for Org1 and Org2"
  ./organizations/ccp-generate.sh
}

# * Step 2: create the demo network using Docker Compose

createNetworkUsingDockerCompose() {
  # Create the demo network
  infoln "Creating network using Docker Compose..."
  DOCKER_SOCK=$DOCKER_SOCK docker-compose -f compose/compose-test-net.yaml -f compose/docker/docker-compose-test-net.yaml up -d 2>&1
}

# * Main: run the previous steps

createOrgsUsingCryptogen

createNetworkUsingDockerCompose
