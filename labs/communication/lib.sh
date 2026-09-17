#!/usr/bin/env bash
# Communication lab helpers. Source it, do not run it.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

NS=communication
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# client <command...>: runs an agent.py client command inside the client pod.
client() { k -n "$NS" exec deploy/client -- python3 /app/agent.py "$@"; }

# json_field <python-expression-on-d>: reads a JSON document on stdin as d and prints the
# expression. eval only ever sees expressions written in this file, never command output.
json_field() { python3 -c 'import json, sys; d = json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

# deploy <manifest>: fresh pods, so no in-memory state or log carries over.
deploy() {
  k -n "$NS" delete deployment --all --wait --ignore-not-found >/dev/null
  k -n "$NS" wait --for=delete pod --all --timeout=120s >/dev/null 2>&1 || true
  k -n "$NS" apply -f "$1" >/dev/null
  local d
  for d in mcp a2a store client; do
    k -n "$NS" rollout status "deployment/$d" --timeout=120s >/dev/null
  done
  # Both replicas must be endpoints before a sequence can hit two of them.
  wait_for 60 two_endpoints mcp || true
  wait_for 60 two_endpoints a2a || true
  wait_for 60 client ping 2>/dev/null || true
}

two_endpoints() {
  [[ "$(k -n "$NS" get endpointslice -l kubernetes.io/service-name="$1" \
    -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}x{end}')" == xx ]]
}

observe_broken() {
  log "BROKEN: local handles, Task state in memory, idempotency key ignored"
  deploy "$LAB_DIR/manifests/broken.yaml"
  local out cmd

  cmd="mcp-sequence"; out="$(client $cmd)"
  save_artifact "$LAB_DIR" broken-mcp-sequence "kubectl -n $NS exec deploy/client -- python3 /app/agent.py $cmd" "$out"
  check "MCP add_item on a second replica returns a JSON-RPC error" error "$(json_field 'd["outcome"]' <<<"$out")"
  check "the error names the second replica" true \
    "$(json_field 'str(d["replicas"][1] in d["response"]["error"]["message"]).lower()' <<<"$out")"

  cmd="a2a-get"; out="$(client $cmd)"
  save_artifact "$LAB_DIR" broken-a2a-get "kubectl -n $NS exec deploy/client -- python3 /app/agent.py $cmd" "$out"
  check "A2A tasks/get on a second replica returns an error" error "$(json_field 'd["outcome"]' <<<"$out")"
  check "the error is TaskNotFoundError" -32001 "$(json_field 'd["response"]["error"]["code"]' <<<"$out")"

  cmd="replay broken-$RANDOM$RANDOM"; out="$(client $cmd)"
  save_artifact "$LAB_DIR" broken-replay "kubectl -n $NS exec deploy/client -- python3 /app/agent.py $cmd" "$out"
  check "a replayed charge without idempotency leaves two side effects" 2 "$(json_field 'd["side_effects"]' <<<"$out")"
}

observe_fixed() {
  log "FIXED: stateless MCP, Tasks in the shared store, idempotency key honoured"
  deploy "$LAB_DIR/manifests/fixed.yaml"
  local out cmd

  cmd="mcp-sequence"; out="$(client $cmd)"
  save_artifact "$LAB_DIR" fixed-mcp-sequence "kubectl -n $NS exec deploy/client -- python3 /app/agent.py $cmd" "$out"
  check "MCP sequence across two replicas returns a JSON-RPC result" result "$(json_field 'd["outcome"]' <<<"$out")"
  check "the two calls hit different replicas" true "$(json_field 'str(d["replicas"][0] != d["replicas"][1]).lower()' <<<"$out")"

  cmd="a2a-get"; out="$(client $cmd)"
  save_artifact "$LAB_DIR" fixed-a2a-get "kubectl -n $NS exec deploy/client -- python3 /app/agent.py $cmd" "$out"
  check "A2A tasks/get on a second replica returns the Task" result "$(json_field 'd["outcome"]' <<<"$out")"

  cmd="replay fixed-$RANDOM$RANDOM"; out="$(client $cmd)"
  save_artifact "$LAB_DIR" fixed-replay "kubectl -n $NS exec deploy/client -- python3 /app/agent.py $cmd" "$out"
  check "a replayed charge with an idempotency key leaves one side effect" 1 "$(json_field 'd["side_effects"]' <<<"$out")"

  cmd="whoami persistent 20"; out="$(client $cmd)"
  save_artifact "$LAB_DIR" fixed-client-persistent "kubectl -n $NS exec deploy/client -- python3 /app/agent.py $cmd" "$out"
  check "persistent client: all 20 calls name the same replica" 1 "$(json_field 'len(d["distinct_replicas"])' <<<"$out")"

  cmd="whoami per-request 20"; out="$(client $cmd)"
  save_artifact "$LAB_DIR" fixed-client-per-request "kubectl -n $NS exec deploy/client -- python3 /app/agent.py $cmd" "$out"
  check "per-request client: calls name both replicas" 2 "$(json_field 'len(d["distinct_replicas"])' <<<"$out")"
}
