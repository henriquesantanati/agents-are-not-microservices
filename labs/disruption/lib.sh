#!/usr/bin/env bash
# Disruption lab helpers. Source it, do not run it.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

NS=disruption
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POD=agent-0
STEPS=90

uid_of() { k -n "$NS" get pod "$POD" -o jsonpath='{.metadata.uid}' 2>/dev/null; }
step_of() { k -n "$NS" exec "$POD" -c agent -- python3 /app/agent.py status; }
# sed reads the whole stream. head would exit after one line, and under pipefail the
# SIGPIPE kubectl gets on its next write fails the script.
first_log_line() { k -n "$NS" logs "$POD" -c agent 2>/dev/null | sed -n 1p; }
restarts_of() { k -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}'; }
started_at() { k -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}'; }
last_exit_code() { k -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}'; }
checkpoint_mode() { k -n "$NS" get statefulset agent -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CHECKPOINT")].value}' 2>/dev/null; }

step_at_least() { local s; s="$(step_of 2>/dev/null)"; (( ${s:-0} >= $1 )); }
running() { [[ "$(started_at 2>/dev/null)" != "" ]]; }
replaced() { local uid; uid="$(uid_of)"; [[ -n "$uid" && "$uid" != "$1" ]] && running && [[ -n "$(first_log_line)" ]]; }
restarted() { (( $(restarts_of) >= 1 )) && running && [[ -n "$(first_log_line)" ]]; }

# First number in the first log line, the step the chain starts at.
start_step() { first_log_line | sed -E 's/^[a-z ]+step ([0-9]+).*/\1/'; }

# evict: POST to the Eviction API, the path kubectl drain and every autoscaler take. Leaves
# the status line and the server's message in EVICT_OUT and the code in EVICT_CODE.
evict() {
  local out
  out="$(k create --raw "/api/v1/namespaces/$NS/pods/$POD/eviction" -f "$LAB_DIR/eviction.json" -v=6 2>&1)" || true
  EVICT_CODE="$(grep -Eo 'status="[0-9]{3}' <<<"$out" | grep -Eo '[0-9]{3}' | tail -n 1)"
  EVICT_OUT="$(grep -Eo 'status="[0-9]{3}[^"]*' <<<"$out" | tail -n 1 | cut -d'"' -f2; grep -E '^Error|^pod/' <<<"$out" || true)"
}

# follow_old_pod / old_pod_log: kubectl logs -f is attached before the delete, so whatever
# the pod prints while it is terminating is kept. The stream ends when the container does.
follow_old_pod() {
  FOLLOW_FILE="$(mktemp)"
  k -n "$NS" logs -f "$POD" -c agent --tail=0 >"$FOLLOW_FILE" 2>&1 &
  FOLLOW_PID=$!
  sleep 2
}
follow_done() { ! kill -0 "$FOLLOW_PID" 2>/dev/null; }
old_pod_log() {
  wait_for 15 follow_done || kill "$FOLLOW_PID" 2>/dev/null || true
  wait "$FOLLOW_PID" 2>/dev/null || true
  OLD_LOG="$(cat "$FOLLOW_FILE")"
  rm -f "$FOLLOW_FILE"
  save_artifact "$LAB_DIR" "$1" "kubectl -n $NS logs -f $POD -c agent    (attached before the delete)" "$OLD_LOG"
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

deploy_broken() {
  log "BROKEN: PDB maxUnavailable 0, grace period 120s, chain in memory"
  deploy "$LAB_DIR/manifests/broken.yaml"
}

deploy_fixed() {
  log "FIXED: preStop checkpoint, SIGTERM checkpoint, checkpoint after every step"
  deploy "$LAB_DIR/manifests/fixed.yaml"
}

# lose_chain <grace-seconds>: deploys the broken manifest at that grace period, deletes the
# pod mid-chain, and shows the replacement starting from zero.
lose_chain() {
  local grace="$1" manifest uid step t0
  manifest="$(mktemp)"
  sed "s/terminationGracePeriodSeconds: 120/terminationGracePeriodSeconds: $grace/" \
    "$LAB_DIR/manifests/broken.yaml" > "$manifest"
  log "Same manifest with terminationGracePeriodSeconds $grace"
  deploy "$manifest"
  rm -f "$manifest"

  wait_for 60 step_at_least 3 || true
  step="$(step_of)"
  uid="$(uid_of)"
  log "kubectl delete pod $POD at step $step. The chain needs $(( (STEPS - step) * 2 ))s more, grace is ${grace}s."
  follow_old_pod
  t0=$SECONDS
  k -n "$NS" delete pod "$POD" --wait=false >/dev/null
  check "kubectl delete succeeds despite the PDB (grace $grace)" 0 "$?"
  wait_for $((grace + 90)) replaced "$uid" || true
  echo

  old_pod_log "broken-grace-$grace-old-pod-log"
  show "The agent says it will finish inside the grace period, but it cannot. It writes no checkpoint while it tries."
  check "the agent tries to finish the chain inside the grace period (grace $grace)" 1 \
    "$(grep -c 'finishing the chain' <<<"$OLD_LOG" || true)"
  echo

  capture "$LAB_DIR" "broken-grace-$grace-replacement-log" k -n "$NS" logs "$POD" -c agent
  show "The replacement came up $((SECONDS - t0))s after the delete and starts from zero. The grace period delayed the restart without saving progress."
  check "replacement starts the chain from step 0 (grace $grace)" 0 "$(start_step)"
  echo
}

observe_broken() {
  wait_for 60 step_at_least 2 || true
  log "One pod, a PodDisruptionBudget with maxUnavailable 0, and a chain of $STEPS steps at two seconds each."
  echo

  evict
  save_artifact "$LAB_DIR" broken-evict \
    "kubectl create --raw /api/v1/namespaces/$NS/pods/$POD/eviction -f eviction.json" "$EVICT_OUT"
  show "The budget refuses the eviction. This is the path kubectl drain and the autoscalers take, and the only one it gates."
  check "Eviction API refuses the pod, the PDB gates it" 429 "$EVICT_CODE"
  echo

  capture "$LAB_DIR" broken-pdb k -n "$NS" get pdb agent
  show "ALLOWED DISRUPTIONS 0. A plain delete, an OOM kill or a lost node never asks."

  lose_chain 30
  lose_chain 120

  log "BROKEN reproduced. The budget stopped the eviction and nothing else. The chain died at 30s and at 120s alike."
  echo
}

# observe_fixed: deletes the pod, then OOM kills the container, then tries kill -9 from
# inside. Runs against whatever fixed pod is there, so 40-verify.sh can call it without
# redeploying.
observe_fixed() {
  wait_for 60 step_at_least 5 || true
  local step uid resumed t0 restarts started
  step="$(step_of)"
  uid="$(uid_of)"
  log "Same delete, at step $step. Voluntary path, so preStop runs and SIGTERM follows."
  follow_old_pod
  t0=$SECONDS
  k -n "$NS" delete pod "$POD" --wait=false >/dev/null
  check "kubectl delete succeeds" 0 "$?"
  wait_for 210 replaced "$uid" || true
  echo

  old_pod_log fixed-delete-old-pod-log
  show "preStop asked the agent to checkpoint, SIGTERM checkpointed again, and the agent left without using the grace period."
  check "preStop hook ran" 1 "$(grep -c 'preStop hook called' <<<"$OLD_LOG" || true)"
  check "SIGTERM handler checkpointed and exited" 1 "$(grep -c 'SIGTERM received, checkpointed' <<<"$OLD_LOG" || true)"
  echo

  capture "$LAB_DIR" fixed-delete-replacement-log k -n "$NS" logs "$POD" -c agent
  resumed="$(start_step)"
  show "The replacement came up $((SECONDS - t0))s after the delete and picks the chain up where the checkpoint left it."
  expect "replacement resumes from the checkpoint, not from zero" "$resumed" -ge "$step"
  check "first log line is a resume" resume "$(first_log_line | cut -d' ' -f1)"
  echo

  wait_for 60 step_at_least $((resumed + 3)) || true
  step="$(step_of)"
  log "Allocating past the memory limit at step $step. Involuntary path, so no preStop and no SIGTERM."
  k -n "$NS" exec "$POD" -c agent -- python3 /app/agent.py oom >/dev/null
  wait_for 120 restarted || true
  echo

  capture "$LAB_DIR" fixed-oom-last-state k -n "$NS" get pod "$POD" \
    -o jsonpath='{.status.containerStatuses[0].lastState.terminated}{"\n"}'
  show "Exit code 137 is SIGKILL. The kernel killed the container at its memory limit, so neither preStop nor the SIGTERM handler ran."
  # The check reads the exit code. For this same kill the reason field has read OOMKilled on
  # some runs and Error on others.
  check "container was killed with SIGKILL" 137 "$(last_exit_code)"
  echo

  capture "$LAB_DIR" fixed-oom-killed-log k -n "$NS" logs "$POD" -c agent --previous --tail=3
  show "The dead container's last lines show periodic checkpoints. Neither preStop nor the SIGTERM handler ran."
  check "the killed container never ran preStop or SIGTERM" 0 \
    "$(k -n "$NS" logs "$POD" -c agent --previous | grep -cE 'reason=(prestop|sigterm)' || true)"
  echo

  capture "$LAB_DIR" fixed-oom-restarted-log k -n "$NS" logs "$POD" -c agent
  show "Resumed from the last periodic checkpoint. That checkpoint is the only thing that bounded the loss."
  expect "restarted container resumes from the periodic checkpoint" "$(start_step)" -ge "$step"
  echo

  # Why the lab kills with memory and not with kill -9. pid_namespaces(7) only delivers
  # SIGKILL to a namespace init from an ancestor namespace, so from inside the container
  # the command reports success and the process carries on.
  restarts="$(restarts_of)"
  started="$(started_at)"
  step="$(step_of)"
  save_artifact "$LAB_DIR" fixed-kill-9 "kubectl -n $NS exec $POD -c agent -- sh -c 'kill -9 1; echo kill exit=\$?'" \
    "$(k -n "$NS" exec "$POD" -c agent -- sh -c 'kill -9 1; echo "kill exit=$?"' 2>&1 | tail -n 1)"
  wait_for 30 step_at_least $((step + 2)) || true
  show "Exit 0 and nothing happened. A container cannot kill its own PID 1, which is why the lab uses the memory limit."
  expect "the chain keeps going after kill -9 1" "$(step_of)" -ge $((step + 2))
  check "the restart count did not move" "$restarts" "$(restarts_of)"
  check "the container is the same one" "$started" "$(started_at)"
  echo

  log "FIX holds. The voluntary path checkpointed on the way out, the involuntary path lost one step at most."
  echo
}
