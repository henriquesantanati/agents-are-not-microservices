#!/usr/bin/env bash
# Disruption lab helpers. Source it, do not run it.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

NS=disruption
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POD=agent-0

uid_of() { k -n "$NS" get pod "$POD" -o jsonpath='{.metadata.uid}' 2>/dev/null; }
step_of() { k -n "$NS" exec "$POD" -c agent -- python3 /app/agent.py status; }
first_log_line() { k -n "$NS" logs "$POD" -c agent 2>/dev/null | head -n 1; }
restarts_of() { k -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}'; }
started_at() { k -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}'; }

step_at_least() { local s; s="$(step_of 2>/dev/null)"; (( ${s:-0} >= $1 )); }
running() { [[ "$(k -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}' 2>/dev/null)" != "" ]]; }
replaced() { local uid; uid="$(uid_of)"; [[ -n "$uid" && "$uid" != "$1" ]] && running && [[ -n "$(first_log_line)" ]]; }
restarted() { (( $(restarts_of) >= 1 )) && running && [[ -n "$(first_log_line)" ]]; }

# First number in the replacement's first log line, the step the chain starts at.
start_step() { first_log_line | sed -E 's/^[a-z ]+step ([0-9]+).*/\1/'; }

# evict: POST to the Eviction API, the path kubectl drain and every autoscaler use.
# Prints the HTTP status code.
evict() {
  local body
  body="$(printf '{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"%s","namespace":"%s"}}' "$POD" "$NS")"
  printf '%s' "$body" | k create --raw "/api/v1/namespaces/$NS/pods/$POD/eviction" -f - -v=6 2>&1 \
    | grep -Eo 'status="?[0-9]{3}' | grep -Eo '[0-9]{3}' | tail -n 1
}

# deploy <manifest-file>: removes every pod, claim and checkpoint so no state carries over.
deploy() {
  k -n "$NS" delete statefulset agent --ignore-not-found --wait >/dev/null
  k -n "$NS" delete pod --all --grace-period=0 --force --ignore-not-found >/dev/null 2>&1 || true
  k -n "$NS" wait --for=delete pod --all --timeout=120s >/dev/null 2>&1 || true
  k -n "$NS" delete pvc --all --ignore-not-found --wait >/dev/null
  k -n "$NS" apply -f "$1" >/dev/null
  k -n "$NS" rollout status statefulset/agent --timeout=180s >/dev/null
  wait_for 60 running || true
}

# lose_chain <grace-seconds>: deploys the broken manifest at that grace period, deletes the
# pod mid-chain, and asserts the replacement starts from zero.
lose_chain() {
  local grace="$1" manifest uid step
  manifest="$(mktemp)"
  sed "s/terminationGracePeriodSeconds: 120/terminationGracePeriodSeconds: $grace/" \
    "$LAB_DIR/manifests/broken.yaml" > "$manifest"
  log "deploying with terminationGracePeriodSeconds $grace"
  deploy "$manifest"
  rm -f "$manifest"

  wait_for 60 step_at_least 3 || true
  step="$(step_of)"
  uid="$(uid_of)"
  log "deleting $POD at step $step; the chain needs $(( (90 - step) * 2 ))s more, grace is ${grace}s"
  k -n "$NS" delete pod "$POD" --wait=false >/dev/null
  check "kubectl delete succeeds despite the PDB (grace $grace)" 0 "$?"
  wait_for $((grace + 90)) replaced "$uid" || true
  capture "$LAB_DIR" "broken-grace-$grace-replacement-log" k -n "$NS" logs "$POD" -c agent
  check "replacement starts the chain from step 0 (grace $grace)" 0 "$(start_step)"
}

observe_broken() {
  log "BROKEN: PDB maxUnavailable 0, long grace period, chain in memory"
  deploy "$LAB_DIR/manifests/broken.yaml"
  wait_for 60 step_at_least 2 || true

  check "Eviction API refuses the pod, the PDB gates it" 429 "$(evict)"
  capture "$LAB_DIR" broken-pdb k -n "$NS" get pdb agent

  lose_chain 30
  lose_chain 120
}

observe_fixed() {
  log "FIXED: preStop checkpoint, SIGTERM checkpoint, checkpoint after every step"
  deploy "$LAB_DIR/manifests/fixed.yaml"

  wait_for 60 step_at_least 5 || true
  local step uid resumed
  step="$(step_of)"
  uid="$(uid_of)"
  log "deleting $POD at step $step (voluntary: preStop, then SIGTERM)"
  k -n "$NS" delete pod "$POD" --wait=false >/dev/null
  check "kubectl delete succeeds" 0 "$?"
  wait_for 210 replaced "$uid" || true
  capture "$LAB_DIR" fixed-delete-replacement-log k -n "$NS" logs "$POD" -c agent
  resumed="$(start_step)"
  expect "replacement resumes from the checkpoint, not from zero" "$resumed" -ge "$step"
  [[ "$(first_log_line)" == resume* ]] && pass "first log line is a resume" || check "first log line is a resume" resume "$(first_log_line)"

  wait_for 60 step_at_least $((resumed + 3)) || true
  step="$(step_of)"
  log "allocating past the memory limit at step $step (involuntary: SIGKILL, no preStop, no SIGTERM)"
  k -n "$NS" exec "$POD" -c agent -- python3 /app/agent.py oom >/dev/null
  wait_for 120 restarted || true
  check "container was OOM killed" OOMKilled \
    "$(k -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}')"
  capture "$LAB_DIR" fixed-oom-last-state k -n "$NS" get pod "$POD" \
    -o jsonpath='{.status.containerStatuses[0].lastState.terminated}{"\n"}'
  capture "$LAB_DIR" fixed-oom-restarted-log k -n "$NS" logs "$POD" -c agent
  capture "$LAB_DIR" fixed-oom-killed-log k -n "$NS" logs "$POD" -c agent --previous --tail=3
  expect "restarted container resumes from the periodic checkpoint" "$(start_step)" -ge "$step"
  check "the killed container never ran preStop or SIGTERM" 0 \
    "$(k -n "$NS" logs "$POD" -c agent --previous | grep -cE 'reason=(prestop|sigterm)' || true)"

  # Why the lab kills with memory and not with kill -9. pid_namespaces(7) only delivers
  # SIGKILL to a namespace init from an ancestor namespace, so from inside the container
  # the command reports success and the process carries on.
  local restarts started_at
  restarts="$(restarts_of)"
  started_at="$(started_at)"
  step="$(step_of)"
  check "kill -9 1 from inside the container reports success" "kill exit=0" \
    "$(k -n "$NS" exec "$POD" -c agent -- sh -c 'kill -9 1; echo "kill exit=$?"' 2>&1 | tail -n 1)"
  wait_for 30 step_at_least $((step + 2)) || true
  expect "the chain keeps going after kill -9 1" "$(step_of)" -ge $((step + 2))
  check "the restart count did not move" "$restarts" "$(restarts_of)"
  check "the container is the same one" "$started_at" "$(started_at)"
}
