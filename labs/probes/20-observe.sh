#!/usr/bin/env bash
# The commands that show why. Run it while a task is in flight, right after 10-break.sh or
# 30-fix.sh. It asserts nothing.
source "$(dirname "$0")/lib.sh"

async="$(pod_of agent-async)"
blocking="$(pod_of agent-blocking)"

run() {
  echo
  cmdline "$@"
  "$@" 2>&1 || true
}

run k -n "$NS" get pod -o wide
run k -n "$NS" get deployment agent-async -o jsonpath='{"liveness:  "}{.spec.template.spec.containers[0].livenessProbe.httpGet.path}{"\n"}{"readiness: "}{.spec.template.spec.containers[0].readinessProbe.httpGet.path}{"\n"}'
run k -n "$NS" exec "$async" -- python3 -c 'import urllib.request as u; r = u.urlopen("http://127.0.0.1:8080/health"); print("/health ->", r.status, r.read().decode())'
run k -n "$NS" exec "$async" -- python3 -c '
import urllib.request as u, urllib.error as e
try: r = u.urlopen("http://127.0.0.1:8080/ready"); print("/ready  ->", r.status, r.read().decode())
except e.HTTPError as x: print("/ready  ->", x.code, x.read().decode())'
echo
show "/health says 200 while the agent is busy. /ready says 503. Whichever one the probes ask decides everything below."

run k -n "$NS" get endpointslice -l kubernetes.io/service-name=agent-async \
  -o custom-columns=POD:.endpoints[*].targetRef.name,READY:.endpoints[*].conditions.ready
echo
show "READY here is what the Service believes. true means it is still sending this pod work."

run k -n "$NS" get events --field-selector reason=Unhealthy,involvedObject.name="$blocking" --sort-by=.lastTimestamp
echo
show "The blocking pod cannot answer while it works. Three liveness timeouts in a row and the kubelet restarts it."
