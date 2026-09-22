#!/usr/bin/env bash
# The commands that show why. Run it after 10-break.sh or 30-fix.sh. It asserts nothing.
source "$(dirname "$0")/lib.sh"

run() {
  printf '\n$ %s\n' "$*" | sed 's/^\$ k /$ kubectl /'
  "$@" 2>&1 || true
}

run k -n "$NS" get deployment \
  -o custom-columns=NAME:.metadata.name,SETTINGS:.spec.template.spec.containers[0].env[*].value
echo
show "A2A_TRACE decides whether the message carries the context. SIGTERM_FLUSH decides whether a killed pod exports anything."

run ls -l "$OTEL_HOST_DIR"
echo
show "One file per process, on a hostPath mapped to the laptop, so a file outlives the pod that wrote it."

run python3 "$AGENT_PY" spans "$OTEL_HOST_DIR"
echo
show "Name, kind, trace id, status, task, events. Two trace ids on one task means the A2A hop dropped the context."

run sh -c "cat '$OTEL_HOST_DIR'/events-*.jsonl 2>/dev/null || echo '(no evaluation events; the evaluator runs in the fixed state)'"
echo
show "The evaluation event is a log record carrying the agent span's id. That is how a score reaches a trace."
