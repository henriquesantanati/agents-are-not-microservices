#!/usr/bin/env bash
# Probes lab helpers. Source it, do not run it.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

NS=probes
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Longer than three failed probes at the default ten-second period, with room to observe.
TASK_SECONDS=90

pod_of() { k -n "$NS" get pod -l app="$1" -o jsonpath='{.items[0].metadata.name}'; }
ready_of() { k -n "$NS" get pod "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'; }
restarts_of() { k -n "$NS" get pod "$1" -o jsonpath='{.status.containerStatuses[0].restartCount}'; }
inflight_of() { k -n "$NS" exec "$1" -- python3 /app/agent.py status; }
fire() { k -n "$NS" exec "$1" -- python3 /app/agent.py fire "$TASK_SECONDS" >/dev/null; }

# endpoint_ready <service> <pod>: prints true, false, or absent for the pod's endpoint.
endpoint_ready() {
  k -n "$NS" get endpointslice -l kubernetes.io/service-name="$1" -o json | python3 -c '
import json, sys
pod = sys.argv[1]
for s in json.load(sys.stdin)["items"]:
    for e in s.get("endpoints") or []:
        if (e.get("targetRef") or {}).get("name") == pod:
            print("true" if e.get("conditions", {}).get("ready") else "false")
            sys.exit()
print("absent")
' "$2"
}

is_ready() { [[ "$(ready_of "$1")" == "$2" ]]; }
# restarted_past <pod> <count>: true once the pod has more restarts than <count>.
restarted_past() { (( $(restarts_of "$1") > $2 )); }

# deploy <manifest>: fresh pods every time, so restart counts start at zero.
deploy() {
  k -n "$NS" delete deployment --all --wait --ignore-not-found >/dev/null
  k -n "$NS" wait --for=delete pod --all --timeout=120s >/dev/null 2>&1 || true
  k -n "$NS" apply -f "$1" >/dev/null
  k -n "$NS" rollout status deployment/agent-async --timeout=120s >/dev/null
  k -n "$NS" rollout status deployment/agent-blocking --timeout=120s >/dev/null
}

deploy_broken() {
  log "BROKEN: both probes on /health"
  deploy "$LAB_DIR/manifests/broken.yaml"
}

deploy_fixed() {
  log "FIXED: liveness on /health, readiness on /ready"
  deploy "$LAB_DIR/manifests/fixed.yaml"
}

# observe_broken: fires a task on each pod and watches. Asserts and captures as it goes.
observe_broken() {
  local async blocking r0
  async="$(pod_of agent-async)"
  blocking="$(pod_of agent-blocking)"
  r0="$(restarts_of "$blocking")"

  log "Two pods, one async and one blocking. Each gets a ${TASK_SECONDS}s task. Watch READY and RESTARTS."
  fire "$async"
  fire "$blocking"

  # The blocking pod restarting proves the kubelet has probed for at least three
  # periods, so the async pod's readiness has had the same chance to change.
  log "waiting for the blocking pod's liveness probe to fail"
  wait_for 120 restarted_past "$blocking" "$r0" || true
  echo

  capture "$LAB_DIR" broken-get-pod k -n "$NS" get pod "$async"
  capture "$LAB_DIR" broken-endpointslice k -n "$NS" get endpointslice -l kubernetes.io/service-name=agent-async \
    -o custom-columns=POD:.endpoints[*].targetRef.name,READY:.endpoints[*].conditions.ready
  show "Busy this whole time and still 1/1 and in the Service. Kubernetes keeps sending it work."
  check "async pod is mid-task" 1 "$(inflight_of "$async")"
  check "async pod is still Ready mid-task" True "$(ready_of "$async")"
  check "async pod is still a ready endpoint of the Service" true "$(endpoint_ready agent-async "$async")"
  check "async pod has not restarted" 0 "$(restarts_of "$async")"
  echo

  capture "$LAB_DIR" broken-blocking-restarts k -n "$NS" get pod "$blocking"
  show "Could not answer /health while working, so liveness restarted it. The task is gone."
  check "blocking pod restarted mid-task, liveness could not get an answer" $((r0 + 1)) "$(restarts_of "$blocking")"
  echo

  log "BROKEN reproduced. The async pod lied, the blocking pod died."
  echo
}

# observe_fixed: same task, same watch, against the fixed manifest. Works on a fresh
# deployment or on one that already ran, so 40-verify.sh can call it without redeploying.
observe_fixed() {
  local async blocking r0
  async="$(pod_of agent-async)"
  blocking="$(pod_of agent-blocking)"
  r0="$(restarts_of "$blocking")"

  log "Same two pods, same task. Readiness now asks /ready, which says 503 while busy."
  fire "$async"
  fire "$blocking"

  log "waiting for the async pod to report not ready"
  wait_for 60 is_ready "$async" False || true
  echo

  capture "$LAB_DIR" fixed-get-pod-busy k -n "$NS" get pod "$async"
  capture "$LAB_DIR" fixed-endpointslice-busy k -n "$NS" get endpointslice -l kubernetes.io/service-name=agent-async \
    -o custom-columns=POD:.endpoints[*].targetRef.name,READY:.endpoints[*].conditions.ready
  show "0/1 and out of the Service while it works. No restart, nothing lost."
  check "async pod is mid-task" 1 "$(inflight_of "$async")"
  check "async pod is not Ready mid-task" False "$(ready_of "$async")"
  check "async pod is not a ready endpoint of the Service" false "$(endpoint_ready agent-async "$async")"
  check "async pod has not restarted" 0 "$(restarts_of "$async")"
  echo

  log "waiting for the task to finish and the async pod to come back"
  wait_for $((TASK_SECONDS + 60)) is_ready "$async" True || true
  echo

  capture "$LAB_DIR" fixed-get-pod-idle k -n "$NS" get pod "$async"
  show "Task done, back to 1/1 on its own."
  check "async pod is idle" 0 "$(inflight_of "$async")"
  check "async pod is Ready again" True "$(ready_of "$async")"
  check "async pod is a ready endpoint again" true "$(endpoint_ready agent-async "$async")"
  check "async pod still has not restarted" 0 "$(restarts_of "$async")"
  echo

  # Readiness cannot help a server that cannot answer at all.
  wait_for 60 restarted_past "$blocking" "$r0" || true
  capture "$LAB_DIR" fixed-blocking-restarts k -n "$NS" get pod "$blocking"
  show "Still restarts. Readiness cannot help a server that cannot answer."
  check "blocking pod still restarts, the fix needs a server that answers while it works" $((r0 + 1)) "$(restarts_of "$blocking")"
  echo

  log "FIX holds. Readiness on /ready took the busy pod out of the Service and brought it back."
  echo
}
