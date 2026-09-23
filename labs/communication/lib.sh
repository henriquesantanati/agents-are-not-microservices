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

two_endpoints() {
  [[ "$(k -n "$NS" get endpointslice -l kubernetes.io/service-name="$1" \
    -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}x{end}')" == xx ]]
}

# The API reports endpoints ready before kube-proxy has programmed them, so wait on a call
# that actually crosses the Services.
reachable() {
  wait_for 60 two_endpoints mcp || true
  wait_for 60 two_endpoints a2a || true
  wait_for 60 client ping 2>/dev/null || die "the servers are not answering through their Services"
}

# deploy <manifest>: fresh pods, so no in-memory state or side effect log carries over.
deploy() {
  k -n "$NS" delete deployment --all --wait --ignore-not-found >/dev/null
  k -n "$NS" wait --for=delete pod --all --timeout=120s >/dev/null 2>&1 || true
  k -n "$NS" apply -f "$1" >/dev/null
  local d
  for d in mcp a2a store client; do
    k -n "$NS" rollout status "deployment/$d" --timeout=120s >/dev/null
  done
  reachable
}

deploy_broken() {
  log "BROKEN: handles in a pod's memory, Task state in a pod's memory, idempotency key ignored"
  deploy "$LAB_DIR/manifests/broken.yaml"
}

deploy_fixed() {
  log "FIXED: stateless MCP, Tasks in the shared store, idempotency key honoured"
  deploy "$LAB_DIR/manifests/fixed.yaml"
}

# call <artifact-name> <client command...>: runs the command, prints it with its output,
# saves the capture, and leaves the JSON in REPLY for the assertions.
call() {
  local name="$1"
  shift
  REPLY="$(client "$@")"
  save_artifact "$LAB_DIR" "$name" "kubectl -n $NS exec deploy/client -- python3 /app/agent.py $*" "$REPLY"
}

# Both observations run against whatever is deployed and leave nothing behind, so
# 40-verify.sh can call observe_fixed without redeploying.
observe_broken() {
  reachable
  log "Two replicas of each server, no session affinity. Every answer names the replica that served it."
  echo

  call broken-mcp-sequence mcp-sequence
  show "Opened on one replica, added on the other, which never saw the handle."
  check "MCP add_item on a second replica returns a JSON-RPC error" error "$(json_field 'd["outcome"]' <<<"$REPLY")"
  check "the error names the second replica" true \
    "$(json_field 'str(d["replicas"][1] in d["response"]["error"]["message"]).lower()' <<<"$REPLY")"
  echo

  call broken-a2a-get a2a-get
  show "The Task is in the memory of the replica that created it. The other has never heard of it."
  check "A2A GetTask on a second replica returns an error" error "$(json_field 'd["outcome"]' <<<"$REPLY")"
  check "the error is TaskNotFoundError" -32001 "$(json_field 'd["response"]["error"]["code"]' <<<"$REPLY")"
  echo

  call broken-replay replay "broken-$RANDOM$RANDOM"
  show "The same charge twice, the way a client retries after a timeout. Two side effects."
  check "a replayed charge without idempotency leaves two side effects" 2 "$(json_field 'd["side_effects"]' <<<"$REPLY")"
  echo

  log "BROKEN reproduced. Half the replicas cannot serve a given call, and a retry charges twice."
  echo
}

observe_fixed() {
  reachable
  log "Same replicas, same calls. The handle carries the cart, the Task is in the store, the key is claimed first."
  echo

  call fixed-mcp-sequence mcp-sequence
  show "Both replicas answer the same sequence, because the server keeps nothing of its own."
  check "MCP sequence across two replicas returns a JSON-RPC result" result "$(json_field 'd["outcome"]' <<<"$REPLY")"
  check "the two calls hit different replicas" true "$(json_field 'str(d["replicas"][0] != d["replicas"][1]).lower()' <<<"$REPLY")"
  echo

  call fixed-a2a-get a2a-get
  show "The Task comes back from the replica that did not create it, and says so in served_by."
  check "A2A GetTask on a second replica returns the Task" result "$(json_field 'd["outcome"]' <<<"$REPLY")"
  echo

  call fixed-replay replay "fixed-$RANDOM$RANDOM"
  show "Same retry, one line in the log. The key was claimed in the store before the side effect."
  check "a replayed charge with an idempotency key leaves one side effect" 1 "$(json_field 'd["side_effects"]' <<<"$REPLY")"
  echo

  call fixed-client-persistent whoami persistent 20
  show "One connection, twenty calls, one replica. kube-proxy balances per connection, not per call."
  check "persistent client: all 20 calls name the same replica" 1 "$(json_field 'len(d["distinct_replicas"])' <<<"$REPLY")"
  echo

  call fixed-client-per-request whoami per-request 20
  show "A connection per call reaches both. Without sessions that costs a handshake and nothing else."
  check "per-request client: calls name both replicas" 2 "$(json_field 'len(d["distinct_replicas"])' <<<"$REPLY")"
  echo

  log "FIX holds. Any replica answers any call, the retry is safe, and a reconnecting client sees both."
  echo
}
