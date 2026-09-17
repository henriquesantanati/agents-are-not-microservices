"""Stub MCP server, A2A server, shared store and client for the communication lab.
Standard library only.

  MODE=mcp    JSON-RPC tools/call on POST /mcp.
              MCP_STATE=local-handle  open_cart mints a handle kept in this pod's memory.
              MCP_STATE=stateless     the handle carries the cart, the pod keeps nothing.
              IDEMPOTENCY=off|on      whether charge honours an idempotency key.
  MODE=a2a    JSON-RPC SendMessage and GetTask (A2A v1.0) on POST /a2a.
              TASK_STORE=local|shared where the Task lives.
  MODE=store  a key-value store and append-only logs over HTTP, the shared store.
  MODE=client sleeps. The lab runs the client commands below inside it.

Client commands, each prints one JSON document:
  python3 agent.py mcp-sequence   open a cart on one replica, add to it on another
  python3 agent.py a2a-get        create a Task on one replica, get it from another
  python3 agent.py replay RUN     send the same charge twice with one idempotency key
  python3 agent.py whoami persistent|per-request N
  python3 agent.py call mcp|a2a JSON   one raw JSON-RPC request on a new connection
"""

import base64
import http.client
import json
import os
import socket
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE = os.environ.get("MODE", "client")
PORT = int(os.environ.get("PORT", "8080"))
POD = os.environ.get("POD_NAME", socket.gethostname())
MCP_STATE = os.environ.get("MCP_STATE", "stateless")
IDEMPOTENCY = os.environ.get("IDEMPOTENCY", "off")
TASK_STORE = os.environ.get("TASK_STORE", "local")
STORE_URL = os.environ.get("STORE_URL", "http://store")
MCP_HOST = os.environ.get("MCP_HOST", "mcp")
# MCP 2026-07-28 has no handshake. Every request names its protocol version in _meta.
MCP_PROTOCOL_VERSION = "2026-07-28"
A2A_HOST = os.environ.get("A2A_HOST", "a2a")

lock = threading.Lock()
carts = {}   # local-handle MCP state, this pod only
tasks = {}   # local A2A Task state, this pod only
kv = {}      # store mode
logs = {}    # store mode


# ---------- shared store client ----------

def store(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{STORE_URL}{path}", data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.load(resp)
    except urllib.error.HTTPError as err:
        return err.code, json.load(err)


# ---------- servers ----------

def rpc_result(req_id, result):
    return {"jsonrpc": "2.0", "id": req_id, "result": result}


def rpc_error(req_id, code, message):
    return {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message, "data": {"replica": POD}}}


def tool_result(req_id, payload):
    payload = {**payload, "replica": POD}
    return rpc_result(req_id, {"resultType": "complete", "content": [{"type": "text", "text": json.dumps(payload)}],
                               "structuredContent": payload,
                               "_meta": {"io.modelcontextprotocol/serverInfo": {"name": "anm-mcp", "version": "0.1.0"}}})


def handle_mcp(msg):
    req_id = msg.get("id")
    if msg.get("method") != "tools/call":
        return rpc_error(req_id, -32601, f"method not found on replica {POD}")
    name = msg["params"]["name"]
    args = msg["params"].get("arguments", {})

    if name == "whoami":
        return tool_result(req_id, {})

    if name == "open_cart":
        if MCP_STATE == "local-handle":
            handle = uuid.uuid4().hex
            with lock:
                carts[handle] = []
        else:
            handle = base64.urlsafe_b64encode(json.dumps({"items": []}).encode()).decode()
        return tool_result(req_id, {"handle": handle})

    if name == "add_item":
        handle = args["handle"]
        if MCP_STATE == "local-handle":
            with lock:
                if handle not in carts:
                    return rpc_error(req_id, -32602, f"unknown handle {handle} on replica {POD}")
                carts[handle].append(args["item"])
                items = list(carts[handle])
            return tool_result(req_id, {"handle": handle, "items": items})
        cart = json.loads(base64.urlsafe_b64decode(handle))
        cart["items"].append(args["item"])
        new_handle = base64.urlsafe_b64encode(json.dumps(cart).encode()).decode()
        return tool_result(req_id, {"handle": new_handle, "items": cart["items"]})

    if name == "charge":
        key = args.get("idempotency_key")
        if IDEMPOTENCY == "on" and key:
            status, _ = store("POST", f"/kv/idem-{key}?if_absent=1", {"replica": POD})
            if status == 409:
                return tool_result(req_id, {"charged": False, "duplicate": True})
        store("POST", f"/log/charges-{args['run']}", {"amount": args["amount"], "replica": POD, "key": key})
        return tool_result(req_id, {"charged": True})

    return rpc_error(req_id, -32602, f"unknown tool {name}")


def handle_a2a(msg):
    req_id = msg.get("id")
    method = msg.get("method")
    if method == "SendMessage":
        task = {"id": uuid.uuid4().hex, "contextId": uuid.uuid4().hex,
                "status": {"state": "TASK_STATE_WORKING"}, "metadata": {"replica": POD}}
        if TASK_STORE == "shared":
            store("POST", f"/kv/task-{task['id']}", task)
        else:
            with lock:
                tasks[task["id"]] = task
        return rpc_result(req_id, {"task": task})
    if method == "GetTask":
        task_id = msg["params"]["id"]
        if TASK_STORE == "shared":
            status, task = store("GET", f"/kv/task-{task_id}")
            task = task if status == 200 else None
        else:
            task = tasks.get(task_id)
        if task is None:
            return rpc_error(req_id, -32001, f"Task not found on replica {POD}")
        return rpc_result(req_id, {**task, "metadata": {**task["metadata"], "served_by": POD}})
    return rpc_error(req_id, -32601, "method not found")


class Handler(BaseHTTPRequestHandler):
    # HTTP/1.1 so a client can keep one connection open, which is the point of the
    # persistent client.
    protocol_version = "HTTP/1.1"

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length)) if length else None

    def do_GET(self):
        if self.path == "/health":
            return self.reply(200, {"pod": POD})
        if MODE == "store" and self.path.startswith("/kv/"):
            with lock:
                value = kv.get(self.path[4:])
            return self.reply(200, value) if value is not None else self.reply(404, {"error": "not found"})
        if MODE == "store" and self.path.startswith("/log/"):
            with lock:
                return self.reply(200, list(logs.get(self.path[5:], [])))
        self.reply(404, {"error": "not found"})

    def do_POST(self):
        body = self.body()
        if MODE == "mcp" and self.path == "/mcp":
            return self.reply(200, handle_mcp(body))
        if MODE == "a2a" and self.path == "/a2a":
            return self.reply(200, handle_a2a(body))
        if MODE == "store" and self.path.startswith("/kv/"):
            key, _, query = self.path[4:].partition("?")
            with lock:
                if "if_absent=1" in query and key in kv:
                    return self.reply(409, {"error": "exists"})
                kv[key] = body
            return self.reply(200, {"ok": True})
        if MODE == "store" and self.path.startswith("/log/"):
            with lock:
                logs.setdefault(self.path[5:], []).append(body)
            return self.reply(200, {"ok": True})
        self.reply(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        pass


# ---------- client ----------

def call_new_connection(host, path, msg):
    """One connection per request."""
    req = urllib.request.Request(f"http://{host}{path}", data=json.dumps(msg).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Connection": "close"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.load(resp)


def tools_call(name, arguments, conn=None):
    msg = {"jsonrpc": "2.0", "id": uuid.uuid4().hex, "method": "tools/call",
           "params": {"name": name, "arguments": arguments,
                      "_meta": {"io.modelcontextprotocol/protocolVersion": MCP_PROTOCOL_VERSION}}}
    if conn is None:
        return call_new_connection(MCP_HOST, "/mcp", msg)
    conn.request("POST", "/mcp", body=json.dumps(msg), headers={"Content-Type": "application/json"})
    return json.load(conn.getresponse())


def replica_of(resp):
    if "error" in resp:
        return resp["error"]["data"]["replica"]
    result = resp["result"]
    return result.get("structuredContent", {}).get("replica") or result["metadata"].get("served_by") or result["metadata"]["replica"]


def mcp_sequence():
    for _ in range(50):
        opened = tools_call("open_cart", {})
        first = replica_of(opened)
        added = tools_call("add_item", {"handle": opened["result"]["structuredContent"]["handle"], "item": "book"})
        second = replica_of(added)
        if first != second:
            print(json.dumps({"replicas": [first, second], "outcome": "error" if "error" in added else "result",
                              "response": added}))
            return
    sys.exit("fifty sequences landed on one replica, is the Deployment at two replicas?")


def a2a_get():
    created = call_new_connection(A2A_HOST, "/a2a", {"jsonrpc": "2.0", "id": 1, "method": "SendMessage",
                                                    "params": {"message": {"role": "ROLE_USER", "messageId": uuid.uuid4().hex,
                                                                           "parts": [{"text": "plan a trip"}]}}})
    task = created["result"]["task"]
    first = task["metadata"]["replica"]
    for _ in range(50):
        got = call_new_connection(A2A_HOST, "/a2a", {"jsonrpc": "2.0", "id": 2, "method": "GetTask",
                                                    "params": {"id": task["id"]}})
        second = replica_of(got)
        if second != first:
            print(json.dumps({"replicas": [first, second], "outcome": "error" if "error" in got else "result",
                              "response": got}))
            return
    sys.exit("fifty gets landed on the creating replica, is the Deployment at two replicas?")


def replay(run):
    # A retry after a timeout looks exactly like this: the same call, twice.
    key = uuid.uuid4().hex
    for _ in range(2):
        tools_call("charge", {"amount": 42, "run": run, "idempotency_key": key})
    with urllib.request.urlopen(f"{STORE_URL}/log/charges-{run}", timeout=10) as resp:
        lines = json.load(resp)
    print(json.dumps({"side_effects": len(lines), "log": lines}))


def ping():
    """Exit non-zero unless every Service answers. The API reports endpoints ready before
    kube-proxy has programmed them, so the lab waits on this, not on the API."""
    for host in (MCP_HOST, A2A_HOST, STORE_URL.removeprefix("http://")):
        with urllib.request.urlopen(f"http://{host}/health", timeout=2) as resp:
            resp.read()


def whoami(mode, n):
    conn = http.client.HTTPConnection(MCP_HOST, 80, timeout=10) if mode == "persistent" else None
    replicas = [replica_of(tools_call("whoami", {}, conn)) for _ in range(n)]
    print(json.dumps({"mode": mode, "calls": n, "distinct_replicas": sorted(set(replicas))}))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "serve"
    if cmd == "mcp-sequence":
        mcp_sequence()
    elif cmd == "a2a-get":
        a2a_get()
    elif cmd == "replay":
        replay(sys.argv[2])
    elif cmd == "call":
        print(json.dumps(call_new_connection(MCP_HOST if sys.argv[2] == "mcp" else A2A_HOST,
                                             "/" + sys.argv[2], json.loads(sys.argv[3])), indent=2))
    elif cmd == "ping":
        ping()
    elif cmd == "whoami":
        whoami(sys.argv[2], int(sys.argv[3]))
    elif MODE == "client":
        while True:
            time.sleep(3600)
    else:
        print(f"{POD} serving on :{PORT} mode={MODE}", flush=True)
        ThreadingHTTPServer(("", PORT), Handler).serve_forever()
