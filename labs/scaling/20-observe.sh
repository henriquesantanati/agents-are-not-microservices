#!/usr/bin/env bash
# The commands that show why. Run it after 10-break.sh or 30-fix.sh, while load runs.
# It asserts nothing.
source "$(dirname "$0")/lib.sh"

run() {
  printf '\n$ %s\n' "$*" | sed 's/^\$ k /$ kubectl /'
  "$@" 2>&1 || true
}

run k -n "$NS" get deployment
echo
show "Which tier has replicas. After 10-break.sh it is the agent, after 30-fix.sh it is the dependency."

run k -n "$NS" get hpa
run k -n "$NS" get scaledobject
echo
show "What is being scaled, and on what. An HPA named agent reads CPU. An HPA made by KEDA for the dependency reads the queue."

run k -n "$NS" top pod
echo
show "CPU as metrics-server sees it. The agent waits on the network and stays near idle however deep the queue is."

run get http://agent/metrics
echo
show "The agent's view. agent_downstream_calls_inflight is the load it puts on the dependency, and no CPU number shows it."

for pod in $(dependency_pods); do
  run k -n "$NS" exec "$pod" -- python3 /app/agent.py get http://127.0.0.1:8080/metrics
done
echo
show "One block per dependency replica. dependency_queue_depth is the number that should drive scaling, and after the fix it is what does."
