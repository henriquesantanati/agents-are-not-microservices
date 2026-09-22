#!/usr/bin/env bash
# Applies the broken manifest, runs one task and one interrupted task, and shows what
# reached the span files.
source "$(dirname "$0")/lib.sh"

deploy_broken
observe_broken
finish
log "observability: $PASSES assertions passed"
