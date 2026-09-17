#!/usr/bin/env bash
# Asserts both states. A lab that only proves the fix says nothing about whether the
# break still reproduces.
export ANM_CAPTURE=0
source "$(dirname "$0")/lib.sh"

observe_broken
observe_fixed
finish
log "observability: all assertions passed"
