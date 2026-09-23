#!/usr/bin/env bash
# Checks the fixed state as it is deployed, without redeploying. Reads the autoscaler, the
# replica counts and every replica's queue, and asserts what the README says you should
# see. Exits non-zero if any check fails. Run 30-fix.sh first, or run.sh for the whole
# sequence.
export ANM_CAPTURE=0
source "$(dirname "$0")/lib.sh"

target="$(k -n "$NS" get scaledobject dependency -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null)"
[[ "$target" == dependency ]] || die "the fixed manifest is not deployed (no ScaledObject on the dependency, found '${target:-none}'); run 30-fix.sh first"

log "VERIFY: the fixed state as deployed, same load, read again"
observe_fixed
finish
log "scaling: $PASSES assertions passed"
