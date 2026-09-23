#!/usr/bin/env bash
# Scaling lab helpers. Source it, do not run it.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

NS=scaling
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METRICS_SERVER_CHART_VERSION=3.14.0
KEDA_CHART_VERSION=2.20.2

# One phrase under a block of output, saying what it shows.
show() { printf -- '--> %s\n\n' "$*"; }

# get <url> [key]: read a metrics document from inside the cluster, through the loadgen pod.
# Three tries, because one slow answer from a dependency under load is not a finding.
get() { retry 3 2 k -n "$NS" exec deploy/loadgen -- python3 /app/agent.py get "$@"; }
service_queue() { get http://dependency/metrics dependency_queue_depth; }
dependency_pods() { k -n "$NS" get pod -l app=dependency --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}'; }
pod_queue() { retry 3 2 k -n "$NS" exec "$1" -- python3 /app/agent.py get http://127.0.0.1:8080/metrics dependency_queue_depth; }
ready_replicas() { k -n "$NS" get deployment "$1" -o jsonpath='{.status.readyReplicas}'; }
hpa_cpu() { k -n "$NS" get hpa agent -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}'; }

# The deepest queue across every dependency replica, read from each pod directly.
max_pod_queue() {
  local pod q max=0
  for pod in $(dependency_pods); do
    q="$(pod_queue "$pod")"
    (( q > max )) && max="$q"
  done
  echo "$max"
}

agent_pods() { k -n "$NS" get pod -l app=agent --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}'; }
agent_tasks() { retry 3 2 k -n "$NS" exec "$1" -- python3 /app/agent.py get http://127.0.0.1:8080/metrics agent_tasks_received; }
every_agent_has_tasks() {
  local pod
  for pod in $(agent_pods); do
    (( $(agent_tasks "$pod") > 0 )) || return 1
  done
}
served_since() { (( $(get http://dependency/metrics dependency_calls_served) >= $1 + $2 )); }

hpa_has_cpu_reading() { [[ "$(hpa_cpu)" =~ ^[0-9]+$ ]]; }
queue_above() { (( $(service_queue) > $1 )); }
replicas_at_least() { local r; r="$(ready_replicas "$1")"; (( ${r:-0} >= $2 )); }
all_queues_at_most() { (( $(max_pod_queue) <= $1 )); }

# deploy <manifest>: fresh pods and no leftover autoscalers, so no state carries over.
deploy() {
  k -n "$NS" delete hpa,scaledobject --all --ignore-not-found >/dev/null
  k -n "$NS" delete deployment --all --wait --ignore-not-found >/dev/null
  k -n "$NS" wait --for=delete pod --all --timeout=120s >/dev/null 2>&1 || true
  k -n "$NS" apply -f "$1" >/dev/null
  local d
  for d in agent dependency loadgen; do
    k -n "$NS" rollout status "deployment/$d" --timeout=120s >/dev/null
  done
}

deploy_broken() {
  log "BROKEN: HorizontalPodAutoscaler on the agent at 70 percent CPU, the dependency not scaled at all"
  deploy "$LAB_DIR/manifests/broken.yaml"
}

deploy_fixed() {
  log "FIXED: agent at 1 replica, KEDA ScaledObject on the dependency, reading its queue"
  deploy "$LAB_DIR/manifests/fixed.yaml"
}

observe_broken() {
  log "Load is 2 tasks a second, each task 20 calls, so 40 calls a second at a dependency that serves 20."
  log "waiting for metrics-server to give the HPA a CPU reading, then for the queue to pass 40"
  wait_for 240 hpa_has_cpu_reading || true
  wait_for 60 queue_above 40 || true
  echo

  capture "$LAB_DIR" broken-hpa k -n "$NS" get hpa agent
  show "CPU at $(hpa_cpu) percent of the request against a target of 70. The HPA sees an agent with room to spare and keeps 1 replica."
  expect "HPA has a numeric CPU reading for the agent" "$(hpa_cpu)" -ge 0
  check "HPA wants 1 agent replica, the agent's CPU is idle while it waits" 1 \
    "$(k -n "$NS" get hpa agent -o jsonpath='{.status.desiredReplicas}')"
  echo

  capture "$LAB_DIR" broken-dependency-metrics get http://dependency/metrics
  show "dependency_queue_depth past 40 and climbing. Two calls arrive for every one served, and nothing is watching this number."
  expect "dependency_queue_depth is above 40" "$(service_queue)" -gt 40
  echo

  capture "$LAB_DIR" broken-top k -n "$NS" top pod
  capture "$LAB_DIR" broken-agent-metrics get http://agent/metrics
  show "The agent spends its time waiting on the network. agent_downstream_calls_inflight is the load it creates, and it costs almost no CPU."
  echo

  log "Scaling the agent by hand to 3 replicas, the other thing people try."
  k -n "$NS" delete hpa agent --ignore-not-found >/dev/null
  k -n "$NS" scale deployment agent --replicas=3 >/dev/null
  if ! k -n "$NS" rollout status deployment/agent --timeout=120s >/dev/null; then
    capture "$LAB_DIR" broken-agent-x3-pods k -n "$NS" get pod -l app=agent
    die "not all three agent replicas came up; a Pending one usually means the node is out of CPU requests"
  fi
  # The backlog alone keeps the queue above 40 for a while, so that proves nothing.
  # Wait until every agent replica has taken tasks and the dependency has served 30
  # seconds of its capacity, then require the queue to have grown.
  local q0 served0 pod
  q0="$(service_queue)"
  served0="$(get http://dependency/metrics dependency_calls_served)"
  log "queue is $q0 with three agents coming up; waiting for all three to take tasks and for 30s of serving"
  wait_for 120 every_agent_has_tasks || true
  wait_for 120 served_since "$served0" 600 || true
  echo

  capture "$LAB_DIR" broken-agent-x3 k -n "$NS" get deployment agent dependency
  show "Three agents, one dependency. Every agent replica is taking tasks."
  check "agent Deployment runs 3 replicas" 3 "$(ready_replicas agent)"
  for pod in $(agent_pods); do
    expect "agent replica ${pod##*-} is taking tasks" "$(agent_tasks "$pod")" -gt 0
  done
  echo

  capture "$LAB_DIR" broken-x3-dependency-metrics get http://dependency/metrics
  show "The queue grew from $q0 while three agents ran. 2 tasks a second times 20 calls is 40 calls a second, whoever makes them."
  expect "dependency_queue_depth is still above 40" "$(service_queue)" -gt 40
  expect "dependency_queue_depth grew while three agents ran (was $q0)" "$(service_queue)" -gt "$q0"
  echo

  log "BROKEN reproduced. The autoscaler watched the agent's CPU and saw nothing wrong. More agents made the queue worse."
  echo
}

# observe_fixed: waits for KEDA and reads every replica. Runs against whatever fixed state
# is there, so 40-verify.sh can call it without redeploying.
observe_fixed() {
  log "Same load. The agent stays at 1, and the dependency scales on dependency_queue_depth, target 10, max 3."
  log "waiting for KEDA to scale the dependency out, then for every replica's queue to reach the target"
  wait_for 240 replicas_at_least dependency 2 || true
  wait_for 420 all_queues_at_most 10 || true
  echo

  capture "$LAB_DIR" fixed-scaledobject k -n "$NS" get scaledobject dependency
  capture "$LAB_DIR" fixed-hpa k -n "$NS" get hpa
  show "KEDA reads the dependency's own /metrics and drives an HPA of its own. The signal is the queue, on the tier that has one."
  echo

  capture "$LAB_DIR" fixed-deployments k -n "$NS" get deployment agent dependency
  show "One agent, $(ready_replicas dependency) dependency replicas. The tier that scaled is the tier that was saturating."
  check "agent Deployment runs 1 replica" 1 "$(ready_replicas agent)"
  expect "dependency runs 2 or more replicas" "$(ready_replicas dependency)" -ge 2
  echo

  # Numbered, not named after the pod, so the file set stays the same between runs.
  local pod n=1
  for pod in $(dependency_pods); do
    capture "$LAB_DIR" "fixed-metrics-replica-$n" k -n "$NS" exec "$pod" -- python3 /app/agent.py get http://127.0.0.1:8080/metrics
    n=$((n + 1))
  done
  show "Every replica's queue at or under 10. Three replicas, because two would only match the offered load, and a queue at full utilisation never drains."
  expect "deepest dependency_queue_depth across replicas is at or below 10" "$(max_pod_queue)" -le 10
  echo

  log "FIX holds. The queue that grew is the signal that scales, and it drains."
  echo
}
