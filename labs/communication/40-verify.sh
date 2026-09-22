#!/usr/bin/env bash
# Checks the fixed state as it is deployed, without redeploying. Runs the same calls and
# asserts what the README says you should see. Exits non-zero if any check fails.
# Run 30-fix.sh first, or run.sh for the whole sequence.
export ANM_CAPTURE=0
source "$(dirname "$0")/lib.sh"

state="$(k -n "$NS" get deployment mcp -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MCP_STATE")].value}' 2>/dev/null)"
[[ "$state" == stateless ]] || die "the fixed manifest is not deployed (MCP_STATE is '${state:-none}', expected stateless); run 30-fix.sh first"

log "VERIFY: the fixed state as deployed, the same calls again"
observe_fixed
finish
log "communication: $PASSES assertions passed"
