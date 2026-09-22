#!/usr/bin/env bash
# Applies the fixed manifest, runs the same two tasks and the evaluator, and shows what
# changed in the span files.
source "$(dirname "$0")/lib.sh"

deploy_fixed
observe_fixed
finish
log "observability: $PASSES assertions passed"
