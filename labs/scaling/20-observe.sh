#!/usr/bin/env bash
# The commands that show why. Run it after 10-break.sh or 30-fix.sh, while load runs.
# It asserts nothing.
source "$(dirname "$0")/lib.sh"

show() {
  printf '\n$ %s\n' "$*" | sed 's/^\$ k /$ kubectl /'
  "$@" || true
}

show k -n "$NS" get deployment
show k -n "$NS" get hpa
show k -n "$NS" get scaledobject
show k -n "$NS" top pod
show get http://agent/metrics
for pod in $(dependency_pods); do
  show k -n "$NS" exec "$pod" -- python3 /app/agent.py get http://127.0.0.1:8080/metrics
done
