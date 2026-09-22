#!/usr/bin/env bash
# Applies the fixed manifest and runs the same calls, plus the two client modes.
source "$(dirname "$0")/lib.sh"

deploy_fixed
observe_fixed
finish
log "communication: $PASSES assertions passed"
