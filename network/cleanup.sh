#!/bin/bash

#
# Cleanup script to remove artifacts created by previous runs
#

. scripts/utils.sh

# Get docker sock path from environment variable
SOCK="${DOCKER_HOST:-/var/run/docker.sock}"
DOCKER_SOCK="${SOCK##unix://}"

# * Step 1: remove crypto materials of organizations created by cryptogen

removeOrgs() {
  # Remove artifacts
  infoln "Removing crypto materials of organizations..."
  if [ -d "organizations/peerOrganizations" ] || [ -d "organizations/ordererOrganizations" ]; then
    rm -rf organizations/peerOrganizations && rm -rf organizations/ordererOrganizations
  fi
}

# * Step 2: remove the demo network created by Docker Compose

removeNetwork() {
  # Remove containers
  infoln "Removing containers of organizations..."
  DOCKER_SOCK=$DOCKER_SOCK docker-compose -f compose/compose-test-net.yaml -f compose/docker/docker-compose-test-net.yaml down --volumes --remove-orphans
}

# * Main: run the previous steps

removeOrgs

removeNetwork
