#!/usr/bin/env bash
# Observability lab helpers. Source it, do not run it.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

NS=observability
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_PY="$LAB_DIR/agent/agent.py"

in_agent() { k -n "$NS" exec deploy/agent -- python3 /app/agent.py "$@"; }
report() { python3 "$AGENT_PY" report "$OTEL_HOST_DIR" "$1"; }

# json_field <python-expression-on-d>: reads a JSON document on stdin as d and prints the
# expression. eval only ever sees expressions written in this file, never command output.
json_field() { python3 -c 'import json, sys; d = json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

has() { [[ "$(report "$1" | json_field "$2")" == True ]]; }

# deploy <manifest>: fresh pods and empty span files, so no earlier run can satisfy an assertion.
deploy() {
  k -n "$NS" delete deployment --all --wait --ignore-not-found >/dev/null
  k -n "$NS" wait --for=delete pod --all --timeout=120s >/dev/null 2>&1 || true
  rm -f "$OTEL_HOST_DIR"/*.jsonl
  k -n "$NS" apply -f "$1" >/dev/null
  local d
  for d in agent mcp specialist; do
    k -n "$NS" rollout status "deployment/$d" --timeout=120s >/dev/null
  done
}

# run_task <id>: one complete task, then wait for the batch processor to export it.
run_task() {
  local out
  out="$(in_agent task "$1" 1)"
  printf '%s\n' "$out"
  wait_for 60 has "$1" 'd["agent"] is not None and d["specialist"] is not None and d["tool_server"] is not None' || true
}

# Assertions that hold in both states.
check_mcp_hop() {
  local r="$1"
  check "agent and MCP tool client span share one trace id" True \
    "$(json_field 'd["agent"]["trace_id"] == d["tool_client"]["trace_id"]' <<<"$r")"
  check "MCP server span joins the same trace through params._meta" True \
    "$(json_field 'd["agent"]["trace_id"] == d["tool_server"]["trace_id"]' <<<"$r")"
  check "agent span gen_ai.operation.name" invoke_agent "$(json_field 'd["agent"]["operation"]' <<<"$r")"
  check "tool client span gen_ai.operation.name" execute_tool "$(json_field 'd["tool_client"]["operation"]' <<<"$r")"
  check "tool server span gen_ai.operation.name" execute_tool "$(json_field 'd["tool_server"]["operation"]' <<<"$r")"
}

# interrupt <id>: starts a long task, deletes the agent pod mid-task, waits until the pod is gone.
interrupt() {
  local out pod
  pod="$(k -n "$NS" get pod -l app=agent -o jsonpath='{.items[0].metadata.name}')"
  out="$(in_agent task "$1" 300 detach)"
  printf '%s\n' "$out" >&2
  log "deleting $pod mid-task" >&2
  k -n "$NS" delete pod "$pod" --wait=true >/dev/null
  json_field 'd["trace_id"]' <<<"$out"
}

observe_broken() {
  log "BROKEN: no trace context in A2A, no SIGTERM handler"
  deploy "$LAB_DIR/manifests/broken.yaml"
  local r trace_id

  run_task broken-1 >/dev/null
  r="$(report broken-1)"
  save_artifact "$LAB_DIR" broken-report "python3 agent/agent.py report .anm/otel broken-1" "$r"
  check_mcp_hop "$r"
  check "every span in the trace is OK or unset" True "$(json_field 'set(d["statuses"]) <= {"OK", "UNSET"}' <<<"$r")"
  check "and the answer is wrong, nothing in the trace says so" 0 "$(json_field 'len(d["evaluations"])' <<<"$r")"
  check "A2A specialist span has a different trace id, nothing carried the context" True \
    "$(json_field 'd["specialist"]["trace_id"] != d["agent"]["trace_id"]' <<<"$r")"

  trace_id="$(interrupt broken-2)"
  r="$(report broken-2)"
  save_artifact "$LAB_DIR" broken-interrupted-report "python3 agent/agent.py report .anm/otel broken-2" "$r"
  check "deleted pod's trace $trace_id is absent from the span files" 0 \
    "$(grep -h -c "0x$trace_id" "$OTEL_HOST_DIR"/spans-*.jsonl 2>/dev/null | awk '{s+=$1} END {print s+0}')"
}

observe_fixed() {
  log "FIXED: traceparent in A2A message.metadata, SIGTERM flush, evaluation event"
  deploy "$LAB_DIR/manifests/fixed.yaml"
  local r trace_id

  run_task fixed-1 >/dev/null
  save_artifact "$LAB_DIR" fixed-evaluate "kubectl -n $NS exec deploy/agent -- python3 /app/agent.py evaluate" "$(in_agent evaluate)"
  wait_for 30 has fixed-1 'len(d["evaluations"]) > 0' || true
  r="$(report fixed-1)"
  save_artifact "$LAB_DIR" fixed-report "python3 agent/agent.py report .anm/otel fixed-1" "$r"
  check_mcp_hop "$r"
  check "A2A specialist span carries the agent's trace id" True \
    "$(json_field 'd["specialist"]["trace_id"] == d["agent"]["trace_id"]' <<<"$r")"
  check "evaluation event is gen_ai.evaluation.result" gen_ai.evaluation.result \
    "$(json_field 'd["evaluations"][0]["event_name"]' <<<"$r")"
  check "evaluation event's span id matches the agent span" True \
    "$(json_field 'd["evaluations"][0]["span_id"] == d["agent"]["span_id"]' <<<"$r")"
  check "evaluation says fail" fail \
    "$(json_field 'd["evaluations"][0]["attributes"]["gen_ai.evaluation.score.label"]' <<<"$r")"

  trace_id="$(interrupt fixed-2)"
  wait_for 30 has fixed-2 'd["agent"] is not None' || true
  r="$(report fixed-2)"
  save_artifact "$LAB_DIR" fixed-interrupted-report "python3 agent/agent.py report .anm/otel fixed-2" "$r"
  check "deleted pod's agent span $trace_id is in the file" True "$(json_field 'd["agent"] is not None' <<<"$r")"
  check "it carries the interruption event" True "$(json_field '"agent.interrupted" in d["agent"]["events"]' <<<"$r")"
  check "every span except the interrupted one is OK or unset" True \
    "$(json_field 'set(d["statuses"]) <= {"OK", "UNSET"}' <<<"$r")"
}
