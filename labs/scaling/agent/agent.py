"""Stub agent, fake dependency and load generator for the scaling lab. Standard library only.

  MODE=agent       POST /task fans out FANOUT concurrent calls to the dependency.
  MODE=dependency  POST /call holds one of CAPACITY slots for CALL_SECONDS.
  MODE=load        POSTs RATE tasks per second to the agent, forever.

  python3 agent.py get URL      print one metrics value or document, used by the lab scripts

Both servers publish /metrics as JSON. Nothing scrapes them.
"""

import json
import os
import socket
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE = os.environ.get("MODE", "agent")
PORT = int(os.environ.get("PORT", "8080"))
POD = os.environ.get("POD_NAME", socket.gethostname())

# Fixed values from the plan. One dependency replica serves CAPACITY / CALL_SECONDS
# calls per second, 20. Load offers RATE * FANOUT calls per second, 40.
CAPACITY = int(os.environ.get("CAPACITY", "4"))
CALL_SECONDS = float(os.environ.get("CALL_SECONDS", "0.2"))
FANOUT = int(os.environ.get("FANOUT", "20"))
RATE = float(os.environ.get("RATE", "2"))
DEPENDENCY_URL = os.environ.get("DEPENDENCY_URL", "http://dependency")
AGENT_URL = os.environ.get("AGENT_URL", "http://agent")

lock = threading.Lock()
slots = threading.Semaphore(CAPACITY)
counters = {
    "agent_downstream_calls_inflight": 0,
    "agent_tasks_received": 0,
    "dependency_queue_depth": 0,
    "dependency_calls_inflight": 0,
    "dependency_calls_served": 0,
}


def bump(name, delta):
    with lock:
        counters[name] += delta


def downstream_call():
    bump("agent_downstream_calls_inflight", 1)
    try:
        req = urllib.request.Request(f"{DEPENDENCY_URL}/call", method="POST")
        with urllib.request.urlopen(req, timeout=900) as resp:
            resp.read()
    except OSError as err:
        print(f"downstream call failed: {err}", flush=True)
    finally:
        bump("agent_downstream_calls_inflight", -1)


def run_task():
    # The agent decides the fan-out at run time. Here it is always FANOUT, all at once.
    for _ in range(FANOUT):
        threading.Thread(target=downstream_call, daemon=True).start()


def serve_call():
    bump("dependency_queue_depth", 1)
    with slots:
        bump("dependency_queue_depth", -1)
        bump("dependency_calls_inflight", 1)
        time.sleep(CALL_SECONDS)
        bump("dependency_calls_inflight", -1)
        bump("dependency_calls_served", 1)


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body):
        data = json.dumps(body).encode()
        try:
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        if self.path == "/metrics":
            prefix = "agent_" if MODE == "agent" else "dependency_"
            with lock:
                body = {k: v for k, v in counters.items() if k.startswith(prefix)}
            self.reply(200, {"pod": POD, **body})
        elif self.path == "/health":
            self.reply(200, {"pod": POD})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        if MODE == "agent" and self.path == "/task":
            bump("agent_tasks_received", 1)
            run_task()
            self.reply(202, {"pod": POD, "accepted": True})
        elif MODE == "dependency" and self.path == "/call":
            serve_call()
            self.reply(200, {"pod": POD})
        else:
            self.reply(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        pass


class Server(ThreadingHTTPServer):
    # Twenty calls arrive together per task. The default backlog of five would drop
    # connections and turn the lab into a test of SYN retries.
    request_queue_size = 1024


def serve():
    print(f"{POD} serving on :{PORT} mode={MODE}", flush=True)
    Server(("", PORT), Handler).serve_forever()


def post_task():
    try:
        req = urllib.request.Request(f"{AGENT_URL}/task", method="POST")
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp.read()
    except OSError as err:
        print(f"task post failed: {err}", flush=True)


def load():
    print(f"{POD} sending {RATE} tasks per second to {AGENT_URL}", flush=True)
    interval = 1 / RATE
    next_at = time.monotonic()
    while True:
        threading.Thread(target=post_task, daemon=True).start()
        next_at += interval
        time.sleep(max(0, next_at - time.monotonic()))


def get(url, key=None):
    with urllib.request.urlopen(url, timeout=10) as resp:
        body = json.load(resp)
    print(body[key] if key else json.dumps(body))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "get":
        get(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
    elif MODE == "load":
        load()
    else:
        serve()
