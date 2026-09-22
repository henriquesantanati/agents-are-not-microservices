#!/usr/bin/env bash
# Checks the fixed state as it is deployed, without redeploying and without clearing the
# span files. Its tasks carry this process id, so it reads its own spans and not the ones
# 30-fix.sh left. Exits non-zero if any check fails.
# Run 30-fix.sh first, or run.sh for the whole sequence.
export ANM_CAPTURE=0
source "$(dirname "$0")/lib.sh"

trace="$(k -n "$NS" get deployment agent -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="A2A_TRACE")].value}' 2>/dev/null)"
[[ "$trace" == on ]] || die "the fixed manifest is not deployed (A2A_TRACE is '${trace:-none}', expected on); run 30-fix.sh first"

log "VERIFY: the fixed state as deployed, another task and another interruption"
observe_fixed
finish
log "observability: $PASSES assertions passed"
