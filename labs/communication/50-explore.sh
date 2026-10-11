#!/usr/bin/env bash
# What the fix does not cover, against the fixed state. Run 00-setup.sh and 30-fix.sh
# first. Deletes the client pod twice and restarts the store, nothing else.
source "$(dirname "$0")/lib.sh"

require_tools kubectl python3
reachable
[[ "$(k -n "$NS" get deploy mcp -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="IDEMPOTENCY")].value}')" == on ]] \
  || die "run 30-fix.sh first"

# py <args...>: runs the Python on stdin in the client pod, with agent.py loaded as demo.
py() {
  k -n "$NS" exec -i deploy/client -- python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("demo", "/app/agent.py")
demo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(demo)
exec(sys.stdin.read(), {"demo": demo})' "$@"
}

log "SendMessage twice with the same messageId. This stub has no A2A deduplication."
out="$(py <<'PY'
import json, uuid
message = {'jsonrpc': '2.0', 'id': 1, 'method': 'SendMessage', 'params': {
    'message': {'role': 'ROLE_USER', 'messageId': uuid.uuid4().hex, 'parts': [{'text': 'plan a trip'}]}}}
tasks = [demo.call_new_connection(demo.A2A_HOST, '/a2a', message)['result']['task']['id'] for _ in range(2)]
print(json.dumps({'task_ids': tasks, 'distinct_tasks': len(set(tasks))}))
PY
)"
save_artifact "$LAB_DIR" explore-a2a-replay "SendMessage twice with one messageId" "$out"
check "same messageId creates two tasks in this implementation" 2 "$(json_field 'd["distinct_tasks"]' <<<"$out")"

log "A key is claimed, then the worker dies before charging."
out="$(py <<'PY'
import json, urllib.request, uuid
key, run = uuid.uuid4().hex, 'gap-' + uuid.uuid4().hex
status, _ = demo.store('POST', '/kv/idem-' + key + '?if_absent=1', {'replica': 'crashed-worker'})
retry = demo.tools_call('charge', {'amount': 42, 'run': run, 'idempotency_key': key})
effects = json.load(urllib.request.urlopen(demo.STORE_URL + '/log/charges-' + run, timeout=10))
print(json.dumps({'claim_status': status, 'retry': retry['result']['structuredContent'], 'side_effects': len(effects)}))
PY
)"
save_artifact "$LAB_DIR" explore-claim-gap "claim the key, retry the charge, read the log" "$out"
check "claim accepted" 200 "$(json_field 'd["claim_status"]' <<<"$out")"
check "retry is considered duplicate" True "$(json_field 'd["retry"]["duplicate"]' <<<"$out")"
check "no charge actually happened" 0 "$(json_field 'd["side_effects"]' <<<"$out")"
show "Claiming the key and charging are two writes. A crash between them loses the charge."

# The response is lost, so the client sends the call again. MCP 2026-07-28 says a broken
# stream is reissued as a new request with a new id, so only the key can match the two.
log "The response to a charge is lost and the call is reissued with a new request id."
for mode in without-key with-key; do
  out="$(py "$mode" <<'PY'
import json, socket, sys, time, urllib.request, uuid
run = 'stream-' + uuid.uuid4().hex
args = {'amount': 42, 'run': run}
if sys.argv[1] == 'with-key':
    args['idempotency_key'] = uuid.uuid4().hex
first_id = uuid.uuid4().hex
body = json.dumps({'jsonrpc': '2.0', 'id': first_id, 'method': 'tools/call', 'params': {
    'name': 'charge', 'arguments': args,
    '_meta': {'io.modelcontextprotocol/protocolVersion': demo.MCP_PROTOCOL_VERSION}}}).encode()
# Send the whole request and close before reading a byte of the response.
s = socket.create_connection((demo.MCP_HOST, 80), timeout=10)
s.sendall(b'POST /mcp HTTP/1.1\r\nHost: mcp\r\nContent-Type: application/json\r\nConnection: close\r\n'
          b'Content-Length: %d\r\n\r\n' % len(body) + body)
s.close()
time.sleep(1)
retry = demo.tools_call('charge', args)  # same arguments, a new id
effects = json.load(urllib.request.urlopen(f'{demo.STORE_URL}/log/charges-{run}', timeout=10))
print(json.dumps({'first_id': first_id, 'retry_id': retry['id'], 'retry': retry['result']['structuredContent'],
                  'side_effects': len(effects)}))
PY
)"
  save_artifact "$LAB_DIR" "explore-broken-stream-$mode" "drop the response, reissue with a new id, $mode" "$out"
  check "$mode: the reissue has a new request id" True "$(json_field 'd["first_id"] != d["retry_id"]' <<<"$out")"
  if [[ "$mode" == without-key ]]; then
    check "without-key: charged twice" 2 "$(json_field 'd["side_effects"]' <<<"$out")"
  else
    check "with-key: the tool answers duplicate" True "$(json_field 'd["retry"].get("duplicate", False)' <<<"$out")"
    check "with-key: charged once" 1 "$(json_field 'd["side_effects"]' <<<"$out")"
  fi
done
show "The request id changes on every reissue. The key in the arguments does not."

# A worker checkpoints step 7, charges, and its pod is deleted before it records the step
# as done. The replacement resumes step 7. The checkpoint is in the store, which survives
# the client pod. The only difference between the two runs is whether the key is in it.
worker() {
  py "$@" <<'PY'
import json, socket, sys, urllib.request, uuid
phase, mode, run = sys.argv[1:4]
if phase == 'first':
    key = uuid.uuid4().hex
    checkpoint = {'step': 7, 'key': key if mode == 'key-in-checkpoint' else None}
    demo.store('POST', f'/kv/ckpt-{run}', checkpoint)
else:
    checkpoint = json.load(urllib.request.urlopen(f'{demo.STORE_URL}/kv/ckpt-{run}', timeout=10))
    key = checkpoint['key'] or uuid.uuid4().hex
charge = demo.tools_call('charge', {'amount': 42, 'run': run, 'idempotency_key': key})['result']['structuredContent']
effects = json.load(urllib.request.urlopen(f'{demo.STORE_URL}/log/charges-{run}', timeout=10))
print(json.dumps({'pod': socket.gethostname(), 'checkpoint': checkpoint, 'key': key, 'charge': charge,
                  'side_effects': len(effects)}))
PY
}

replace_client() {
  local old
  old="$(k -n "$NS" get pod -l app=client -o jsonpath='{.items[0].metadata.name}')"
  k -n "$NS" delete pod "$old" --wait=false >/dev/null
  k -n "$NS" wait --for=delete "pod/$old" --timeout=120s >/dev/null
  k -n "$NS" rollout status deploy/client --timeout=120s >/dev/null
  wait_for 60 client ping 2>/dev/null || die "the new client pod does not reach the Services"
}

for mode in key-in-memory key-in-checkpoint; do
  log "$mode: checkpoint step 7, charge, delete the pod, resume step 7 in the new one"
  run="ckpt-$mode-$$"
  first="$(worker first "$mode" "$run")"
  replace_client
  resumed="$(worker resume "$mode" "$run")"
  save_artifact "$LAB_DIR" "explore-checkpoint-$mode" "charge, delete the client pod, resume ($mode)" "$first"$'\n'"$resumed"
  both="$(printf '[%s,%s]' "$first" "$resumed")"
  check "$mode: resumed in another pod" True "$(json_field 'd[0]["pod"] != d[1]["pod"]' <<<"$both")"
  if [[ "$mode" == key-in-memory ]]; then
    check "$mode: the new pod sends a new key" True "$(json_field 'd[0]["key"] != d[1]["key"]' <<<"$both")"
    check "$mode: charged twice" 2 "$(json_field 'd[1]["side_effects"]' <<<"$both")"
  else
    check "$mode: the new pod sends the same key" True "$(json_field 'd[0]["key"] == d[1]["key"]' <<<"$both")"
    check "$mode: the tool answers duplicate" True "$(json_field 'd[1]["charge"].get("duplicate", False)' <<<"$both")"
    check "$mode: charged once" 1 "$(json_field 'd[1]["side_effects"]' <<<"$both")"
  fi
done
show "The key only helps if the pod that resumes has it. Save it with the checkpoint."

log "Create an A2A task, then restart the shared in-memory store."
created="$(client call a2a '{"jsonrpc":"2.0","id":1,"method":"SendMessage","params":{"message":{"role":"ROLE_USER","messageId":"store-restart","parts":[{"text":"plan a trip"}]}}}')"
task_id="$(json_field 'd["result"]["task"]["id"]' <<<"$created")"
before="$(client call a2a "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"GetTask\",\"params\":{\"id\":\"$task_id\"}}")"
check "task is present before store restart" True "$(json_field '"result" in d' <<<"$before")"
old_store="$(k -n "$NS" get pod -l app=store -o jsonpath='{.items[0].metadata.name}')"
k -n "$NS" rollout restart deploy/store >/dev/null
k -n "$NS" rollout status deploy/store --timeout=120s >/dev/null
k -n "$NS" wait --for=delete "pod/$old_store" --timeout=120s >/dev/null
reachable
after="$(client call a2a "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"GetTask\",\"params\":{\"id\":\"$task_id\"}}")"
save_artifact "$LAB_DIR" explore-store-restart "GetTask after store rollout restart" "$after"
check "shared state is lost when the in-memory store restarts" -32001 "$(json_field 'd.get("error", {}).get("code")' <<<"$after")"
show "Shared is not durable. The store has to outlive its own pod too."
finish
log "communication exploration: $PASSES assertions passed"
