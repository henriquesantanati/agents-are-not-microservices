#!/usr/bin/env bash
# The commands that show why. Run it while a task is in flight, after 10-break.sh or
# 30-fix.sh. It asserts nothing.
source "$(dirname "$0")/lib.sh"

async="$(pod_of agent-async)"

show() {
  printf '\n$ %s\n' "$*" | sed 's/^\$ k /$ kubectl /'
  "$@" || true
}

show k -n "$NS" get pod -o wide
show k -n "$NS" get deployment agent-async -o jsonpath='{.spec.template.spec.containers[0].livenessProbe}{"\n"}{.spec.template.spec.containers[0].readinessProbe}{"\n"}'
show k -n "$NS" exec "$async" -- python3 -c 'import urllib.request as u; print(u.urlopen("http://127.0.0.1:8080/health").read().decode())'
show k -n "$NS" exec "$async" -- python3 -c '
import urllib.request as u, urllib.error as e
try: r = u.urlopen("http://127.0.0.1:8080/ready"); print(r.status, r.read().decode())
except e.HTTPError as x: print(x.code, x.read().decode())'
show k -n "$NS" get endpointslice -l kubernetes.io/service-name=agent-async \
  -o custom-columns=POD:.endpoints[*].targetRef.name,READY:.endpoints[*].conditions.ready
show k -n "$NS" get events --field-selector reason=Unhealthy --sort-by=.lastTimestamp
