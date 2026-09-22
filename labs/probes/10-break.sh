#!/usr/bin/env bash
# Applies the broken manifest, runs a task on each pod and shows what Kubernetes sees.
source "$(dirname "$0")/lib.sh"

deploy_broken
observe_broken
finish
log "probes: $PASSES assertions passed"
