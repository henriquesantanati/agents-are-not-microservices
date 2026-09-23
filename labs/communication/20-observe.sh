#!/usr/bin/env bash
# The commands that show why. Run it after 10-break.sh or 30-fix.sh. It asserts nothing.
source "$(dirname "$0")/lib.sh"

run() {
  printf '\n$ %s\n' "$*" | sed 's/^\$ k /$ kubectl /'
  "$@" 2>&1 || true
}

run k -n "$NS" get pod -o wide
echo
show "Two replicas of mcp and two of a2a. Any of them can get the next call."

run k -n "$NS" get service mcp a2a \
  -o custom-columns=NAME:.metadata.name,CLUSTER-IP:.spec.clusterIP,AFFINITY:.spec.sessionAffinity
echo
show "No session affinity anywhere. Nothing pins a caller to a replica, and that is the point."

run k -n "$NS" get deployment mcp a2a \
  -o custom-columns=NAME:.metadata.name,SETTINGS:.spec.template.spec.containers[0].env[*].value
echo
show "The whole difference between the two states is in these three settings. Local handle or stateless, local or shared Tasks, idempotency off or on."

run k -n "$NS" exec deploy/client -- python3 /app/agent.py whoami per-request 6
echo
show "Six calls, one connection each, and both replicas answer. This is what breaks a server that keeps state of its own."
