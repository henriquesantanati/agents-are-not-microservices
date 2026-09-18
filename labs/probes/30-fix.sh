#!/usr/bin/env bash
# Applies the fixed manifest, runs a task on each pod and shows what changed.
source "$(dirname "$0")/lib.sh"

deploy_fixed
observe_fixed
finish
log "probes: $PASSES assertions passed"
