#!/usr/bin/env bash
# Additional checks in the fixed demo. Run 00-setup.sh and 30-fix.sh first.
# Deletion and SIGKILL target only this lab's agent pod/container.
source "$(dirname "$0")/lib.sh"

require_tools kubectl python3
[[ "$(k -n "$NS" get deploy agent -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SIGTERM_FLUSH")].value}')" == on ]] \
  || die "run 30-fix.sh first"
id="explore-$RUN"
log "Validate parent-child relationships, not just identical trace ids."
run_task "$id"
out="$(python3 - "$OTEL_HOST_DIR" "$id" <<'PY'
import glob, json, os, sys
spans = [json.loads(line) for path in glob.glob(os.path.join(sys.argv[1], 'spans-*.jsonl'))
         for line in open(path) if line.strip()]
trace_ids = {s['context']['trace_id'] for s in spans if s['attributes'].get('anm.task.id') == sys.argv[2]}
spans = [s for s in spans if s['context']['trace_id'] in trace_ids]
def pick(name, kind):
    return next(s for s in spans if s['name'] == name and s['kind'] == 'SpanKind.' + kind)
agent = pick('invoke_agent travel-planner', 'INTERNAL')
tool_client = pick('tools/call get_weather', 'CLIENT')
tool_server = pick('tools/call get_weather', 'SERVER')
a2a_client = pick('invoke_agent specialist', 'CLIENT')
specialist = pick('invoke_agent specialist', 'SERVER')
links = [(tool_client, agent), (tool_server, tool_client), (a2a_client, agent), (specialist, a2a_client)]
print(json.dumps({'span_count': len(spans), 'trace_count': len(trace_ids),
    'parent_links_valid': all(child['parent_id'] == parent['context']['span_id'] for child, parent in links),
    'statuses': sorted({s['status']['status_code'] for s in spans})}))
PY
)"
save_artifact "$LAB_DIR" explore-parent-links "validate all four parent-child links" "$out"
check "five exported spans" 5 "$(json_field 'd["span_count"]' <<<"$out")"
check "one trace" 1 "$(json_field 'd["trace_count"]' <<<"$out")"
check "MCP and A2A server spans are children of their client spans" True "$(json_field 'd["parent_links_valid"]' <<<"$out")"
show "UNSET is the default span status. It is not a correctness score."

log "SIGTERM ends and exports the interrupted span."
int="explore-term-$RUN"
trace_id="$(interrupt "$int")"
wait_for 30 has "$int" 'd["agent"] is not None' || true
r="$(report "$int")"
save_artifact "$LAB_DIR" explore-term "report SIGTERM-interrupted task" "$r"
check "gracefully interrupted span is ERROR" ERROR "$(json_field '(d["agent"] or {}).get("status")' <<<"$r")"
check "interruption event is present" True "$(json_field '"agent.interrupted" in (d["agent"] or {}).get("events", [])' <<<"$r")"

log "Zero-grace deletion is not guaranteed to skip SIGTERM. Capture what this runtime does."
int="explore-kill-$RUN"
pod="$(k -n "$NS" get pod -l app=agent -o jsonpath='{.items[0].metadata.name}')"
started="$(in_agent task "$int" 300 detach)"
save_artifact "$LAB_DIR" explore-kill-start "start task before force deletion" "$started"
k -n "$NS" delete pod "$pod" --grace-period=0 --force
# Force deletion returns before the runtime confirms death. Wait for the replacement
# and allow another batch interval before reading evidence, not for an exact duration.
k -n "$NS" rollout status deploy/agent --timeout=120s
sleep 6
r="$(report "$int")"
save_artifact "$LAB_DIR" explore-kill "report force-deleted task" "$r"
show "A zero-grace delete can still allow the handler to run. Use an actual SIGKILL for the next test."

log "SIGKILL from the kind node's ancestor PID namespace skips the handler."
int="explore-sigkill-$RUN"
pod="$(k -n "$NS" get pod -l app=agent -o jsonpath='{.items[0].metadata.name}')"
container_id="$(k -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].containerID}')"
container_id="${container_id#containerd://}"
restarts="$(k -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}')"
agent_pid="$("$RUNTIME" exec "${CLUSTER_NAME}-control-plane" crictl inspect "$container_id" | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["pid"])')"
[[ "$agent_pid" =~ ^[0-9]+$ && "$agent_pid" -gt 1 ]] || die "invalid agent PID"
started="$(in_agent task "$int" 300 detach)"
save_artifact "$LAB_DIR" explore-sigkill-start "start task before SIGKILL" "$started"
"$RUNTIME" exec "${CLUSTER_NAME}-control-plane" kill -KILL "$agent_pid"
restarted() {
  local count
  count="$(k -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}')"
  [[ "$count" =~ ^[0-9]+$ && "$count" -gt "$restarts" ]]
}
wait_for 60 restarted || die "agent container did not restart"
k -n "$NS" wait --for=condition=Ready "pod/$pod" --timeout=120s
sleep 6
r="$(report "$int")"
save_artifact "$LAB_DIR" explore-sigkill "report SIGKILL-interrupted task" "$r"
check "unfinished span is absent despite SIGTERM_FLUSH=on" True "$(json_field 'd["agent"] is None' <<<"$r")"
show "force_flush cannot export an unfinished span after its process has been killed."
finish
log "observability exploration: $PASSES assertions passed"
