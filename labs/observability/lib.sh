#!/usr/bin/env bash
# Observability lab helpers. Source it, do not run it.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

NS=observability
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_PY="$LAB_DIR/agent/agent.py"
# Task ids carry the process id, so a second run never reads the first run's spans.
RUN="$$"

in_agent() { k -n "$NS" exec deploy/agent -- python3 /app/agent.py "$@"; }
report() { python3 "$AGENT_PY" report "$OTEL_HOST_DIR" "$1"; }
spans() { python3 "$AGENT_PY" spans "$OTEL_HOST_DIR" "$@"; }

# json_field <python-expression-on-d>: reads a JSON document on stdin as d and prints the
# expression. eval only ever sees expressions written in this file, never command output.
json_field() { python3 -c 'import json, sys; d = json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

has() { [[ "$(report "$1" | json_field "$2")" == True ]]; }

# deploy <manifest>: fresh pods and empty span files, so no earlier run can satisfy an
# assertion.
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

deploy_broken() {
  log "BROKEN: no trace context in the A2A message, no SIGTERM handler"
  deploy "$LAB_DIR/manifests/broken.yaml"
}

deploy_fixed() {
  log "FIXED: traceparent in message.metadata, an evaluator, and a SIGTERM handler that flushes"
  deploy "$LAB_DIR/manifests/fixed.yaml"
}

# run_task <id>: one complete task, then wait for the batching processor to export it.
run_task() {
  in_agent task "$1" 1
  wait_for 60 has "$1" 'd["agent"] is not None and d["specialist"] is not None and d["tool_server"] is not None' || true
}

# interrupt <id>: starts a task that will not finish, deletes the agent pod while it runs,
# and prints the trace id the agent reported when it started.
interrupt() {
  local out pod
  pod="$(k -n "$NS" get pod -l app=agent -o jsonpath='{.items[0].metadata.name}')"
  out="$(in_agent task "$1" 300 detach)"
  printf '%s\n' "$out" >&2
  log "deleting $pod while the task is still running" >&2
  k -n "$NS" delete pod "$pod" --wait=true >/dev/null
  k -n "$NS" rollout status deployment/agent --timeout=120s >/dev/null 2>&1 || true
  json_field 'd["trace_id"]' <<<"$out"
}

# Assertions that hold in both states: the MCP hop carries the trace.
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

# Both observations run against whatever is deployed and use task ids of their own, so
# 40-verify.sh can call observe_fixed without redeploying or clearing the span files.
observe_broken() {
  local id="broken-$RUN" int="broken-int-$RUN" r trace_id

  log "One task: think, call an MCP tool, delegate a step over A2A, answer."
  run_task "$id"
  echo
  save_artifact "$LAB_DIR" broken-spans "python3 agent/agent.py spans .anm/otel $id" "$(spans "$id")"
  show "Four spans in one trace, and the specialist under a trace id of its own. The A2A hop lost it."
  r="$(report "$id")"
  save_artifact "$LAB_DIR" broken-report "python3 agent/agent.py report .anm/otel $id" "$r"
  check_mcp_hop "$r"
  check "every span in the trace is OK or unset" True "$(json_field 'set(d["statuses"]) <= {"OK", "UNSET"}' <<<"$r")"
  check "and the answer is wrong, with nothing in the trace to say so" 0 "$(json_field 'len(d["evaluations"])' <<<"$r")"
  check "A2A specialist span has a different trace id, nothing carried the context" True \
    "$(json_field 'd["specialist"]["trace_id"] != d["agent"]["trace_id"]' <<<"$r")"
  echo

  log "Now a task that will not finish, and a delete while it runs."
  trace_id="$(interrupt "$int")"
  save_artifact "$LAB_DIR" broken-interrupted-report "python3 agent/agent.py report .anm/otel $int" "$(report "$int")"
  show "The trace of the running task is in no file. The span never ended, and nothing flushed."
  check "deleted pod's trace $trace_id is absent from the span files" 0 \
    "$(grep -h -c "0x$trace_id" "$OTEL_HOST_DIR"/spans-*.jsonl 2>/dev/null | awk '{s+=$1} END {print s+0}')"
  echo

  log "BROKEN reproduced. Green trace, wrong answer, a second trace for the delegation, nothing for the killed task."
  echo
}

observe_fixed() {
  local id="fixed-$RUN" int="fixed-int-$RUN" r trace_id

  log "Same task. The A2A message now carries traceparent in its metadata."
  run_task "$id"
  echo
  save_artifact "$LAB_DIR" fixed-spans "python3 agent/agent.py spans .anm/otel $id" "$(spans "$id")"
  show "Five spans, one trace id. The specialist joined it through the message, not the header."
  echo

  log "The evaluator reads finished runs and scores them, after the request, not inside it."
  save_artifact "$LAB_DIR" fixed-evaluate "kubectl -n $NS exec deploy/agent -- python3 /app/agent.py evaluate" "$(in_agent evaluate)"
  wait_for 30 has "$id" 'len(d["evaluations"]) > 0' || true
  r="$(report "$id")"
  save_artifact "$LAB_DIR" fixed-report "python3 agent/agent.py report .anm/otel $id" "$r"
  show "The event carries the agent span's id and a failing score."
  check_mcp_hop "$r"
  check "A2A specialist span carries the agent's trace id" True \
    "$(json_field 'd["specialist"]["trace_id"] == d["agent"]["trace_id"]' <<<"$r")"
  check "evaluation event is gen_ai.evaluation.result" gen_ai.evaluation.result \
    "$(json_field 'd["evaluations"][0]["event_name"]' <<<"$r")"
  check "evaluation event's span id matches the agent span" True \
    "$(json_field 'd["evaluations"][0]["span_id"] == d["agent"]["span_id"]' <<<"$r")"
  check "evaluation says fail" fail \
    "$(json_field 'd["evaluations"][0]["attributes"]["gen_ai.evaluation.score.label"]' <<<"$r")"
  echo

  log "Now the same delete, against an agent that handles SIGTERM."
  trace_id="$(interrupt "$int")"
  wait_for 30 has "$int" 'd["agent"] is not None' || true
  r="$(report "$int")"
  save_artifact "$LAB_DIR" fixed-interrupted-report "python3 agent/agent.py report .anm/otel $int" "$r"
  show "The span of the killed task is in the file, ERROR, with the event that says why."
  check "deleted pod's agent span $trace_id is in the file" True "$(json_field 'd["agent"] is not None' <<<"$r")"
  check "it carries the interruption event" True "$(json_field '"agent.interrupted" in d["agent"]["events"]' <<<"$r")"
  check "every span except the interrupted one is OK or unset" True \
    "$(json_field 'set(d["statuses"]) <= {"OK", "UNSET"}' <<<"$r")"
  echo

  log "FIX holds. One trace across both hops, a score on the span, the interrupted task exported."
  echo
}
