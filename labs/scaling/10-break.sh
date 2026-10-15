#!/usr/bin/env bash
# Applies the broken manifest, waits for the HPA to read CPU, and shows the queue growing
# while the HPA sits at one replica. Then scales the agent by hand and shows it keep growing.
source "$(dirname "$0")/lib.sh"

deploy_broken
observe_broken
finish
log "scaling: $PASSES assertions passed"
