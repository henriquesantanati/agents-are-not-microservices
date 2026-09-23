#!/usr/bin/env bash
# Checks the fixed state as it is deployed, without redeploying. Runs the same delete, OOM
# kill and kill -9 and asserts what the README says you should see. Exits non-zero if any
# check fails. Run 30-fix.sh first, or run.sh for the whole sequence.
export ANM_CAPTURE=0
source "$(dirname "$0")/lib.sh"

mode="$(checkpoint_mode)"
[[ "$mode" == all ]] || die "the fixed manifest is not deployed (CHECKPOINT is '${mode:-none}', expected all); run 30-fix.sh first"
step="$(step_of 2>/dev/null || echo 0)"
(( step < 60 )) || die "the chain is at step $step of $STEPS, too far along to disrupt again; run 30-fix.sh for a fresh one"

log "VERIFY: the fixed state as deployed, the same delete, OOM kill and kill -9 again"
observe_fixed
finish
log "disruption: $PASSES assertions passed"
