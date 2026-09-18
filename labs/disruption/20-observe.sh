#!/usr/bin/env bash
# The commands that show why. Run it after 10-break.sh or 30-fix.sh. It asserts nothing.
source "$(dirname "$0")/lib.sh"

show() {
  printf '\n$ %s\n' "$*" | sed 's/^\$ k /$ kubectl /'
  "$@" || true
}

show k -n "$NS" get pdb agent
show k -n "$NS" get pod "$POD" -o jsonpath='{.spec.terminationGracePeriodSeconds}{"\n"}{.spec.containers[0].lifecycle}{"\n"}'
show k -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].lastState}{"\n"}'
show k -n "$NS" logs "$POD" -c agent --tail=5
show k -n "$NS" logs "$POD" -c agent --previous --tail=5
show k -n "$NS" get events --sort-by=.lastTimestamp
