#!/usr/bin/env bash
# Four fixed tasks against the fixed stubs, in a namespace of their own so the lab's span
# files stay as they are. Every run is clean on the trace; only the evaluation tells them
# apart. Run 00-setup.sh first. Reports land in artifacts/outcome-<scenario>.json.
source "$(dirname "$0")/lib.sh"

OUT_NS=observability-outcomes
OUT_DIR="$OTEL_HOST_DIR/outcomes"

require_tools kubectl python3
ensure_otel_mount
mkdir -p "$OUT_DIR" "$LAB_DIR/artifacts"
chmod 0777 "$OUT_DIR"
ensure_namespace "$OUT_NS"
k -n "$OUT_NS" apply -f "$LAB_DIR/manifests/outcomes.yaml" >/dev/null
for d in agent mcp specialist; do
  k -n "$OUT_NS" rollout restart "deploy/$d" >/dev/null
  k -n "$OUT_NS" rollout status "deploy/$d" --timeout=120s >/dev/null
done

for scenario in correct_answer wrong_answer injection_blocked pods_unhealthy; do
  id="outcome-$scenario-$RUN"
  log "$scenario"
  k -n "$OUT_NS" exec deploy/agent -- python3 /app/agent.py scenario "$id" "$scenario" >/dev/null
  k -n "$OUT_NS" exec deploy/agent -- python3 /app/agent.py evaluate "$id" >/dev/null
  sleep 6  # the batching processor exports within five seconds
  r="$(python3 "$LAB_DIR/outcome_report.py" "$OUT_DIR" "$id")" || die "$scenario: the report check failed"
  printf '%s\n' "$r" > "$LAB_DIR/artifacts/outcome-$scenario.json"
  pass "$scenario: $(json_field '"one trace, %d spans, HTTP 200, %s; answer %r; %s %.1f" % (d["span_count"], d["statuses"][0], d["answer"], d["evaluation"]["attributes"]["gen_ai.evaluation.score.label"], d["evaluation"]["attributes"]["gen_ai.evaluation.score.value"])' <<<"$r")"
done
show "Same trace every time. The evaluation event is the only thing that says which answer was wrong."
finish
log "outcomes: $PASSES scenarios checked, reports in artifacts/"
