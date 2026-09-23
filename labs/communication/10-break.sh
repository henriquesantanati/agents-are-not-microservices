#!/usr/bin/env bash
# Applies the broken manifest and runs the three calls that fail across replicas.
source "$(dirname "$0")/lib.sh"

deploy_broken
observe_broken
finish
log "communication: $PASSES assertions passed"
