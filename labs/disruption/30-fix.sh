#!/usr/bin/env bash
# Applies the fixed manifest, then the same delete, an OOM kill, and a kill -9 from inside.
source "$(dirname "$0")/lib.sh"

deploy_fixed
observe_fixed
finish
log "disruption: $PASSES assertions passed"
