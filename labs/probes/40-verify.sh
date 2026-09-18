#!/usr/bin/env bash
# Checks the fixed state as it is deployed, without redeploying. Runs one task on each pod
# and asserts what the README says you should see. Exits non-zero if any check fails.
# Run 30-fix.sh first, or run.sh for the whole sequence.
export ANM_CAPTURE=0
source "$(dirname "$0")/lib.sh"

path="$(k -n "$NS" get deployment agent-async -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
[[ "$path" == /ready ]] || die "the fixed manifest is not deployed (readiness probe is '${path:-none}', expected /ready); run 30-fix.sh first"

log "VERIFY: the fixed state as deployed, one more task on each pod"
observe_fixed
finish
log "probes: $PASSES assertions passed"
