#!/usr/bin/env bash
# Applies the broken manifest, asks the Eviction API, then deletes the pod mid-chain at two
# grace periods and shows the replacement starting from zero.
source "$(dirname "$0")/lib.sh"

deploy_broken
observe_broken
finish
log "disruption: $PASSES assertions passed"
