#!/usr/bin/env bash
# Applies the fixed manifest and waits for KEDA to scale the dependency until every
# replica's queue is at the target.
source "$(dirname "$0")/lib.sh"

deploy_fixed
observe_fixed
finish
log "scaling: $PASSES assertions passed"
