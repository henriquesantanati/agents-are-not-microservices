"""Stub agent for the probes lab. Standard library only.

  python3 agent.py serve        run the server
  python3 agent.py fire SECONDS start a task on the local server and return at once
  python3 agent.py status       print the local server's in-flight task count

MODE=async     one thread per request. A task runs in the background, so /health and
               /ready keep answering while it works.
MODE=blocking  one thread for everything. A task runs inside the request, so nothing
               answers until it ends.
"""

import json
import os
import socket
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

MODE = os.environ.get("MODE", "async")
MAX_TASKS = int(os.environ.get("MAX_TASKS", "1"))
PORT = int(os.environ.get("PORT", "8080"))
POD = os.environ.get("POD_NAME", socket.gethostname())

inflight = 0
lock = threading.Lock()


def run_task(seconds):
    """Stands in for a multi-step reasoning chain. The caller has already counted it."""
    global inflight
    try:
        time.sleep(seconds)
    finally:
        with lock:
            inflight -= 1


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
        if self.path == "/health":
            # Is the process alive? Nothing else.
            self.reply(200, {"pod": POD, "alive": True})
        elif self.path == "/ready":
            # Can it take another task?
            ready = inflight < MAX_TASKS
            self.reply(200 if ready else 503, {"pod": POD, "inflight": inflight, "max_tasks": MAX_TASKS})
        elif self.path == "/status":
            self.reply(200, {"pod": POD, "mode": MODE, "inflight": inflight})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        url = urlparse(self.path)
        if url.path != "/task":
            return self.reply(404, {"error": "not found"})
        seconds = float(parse_qs(url.query).get("seconds", ["90"])[0])
        global inflight
        with lock:
            inflight += 1
        if MODE == "blocking":
            run_task(seconds)
            self.reply(200, {"pod": POD, "done": True})
        else:
            threading.Thread(target=run_task, args=(seconds,), daemon=True).start()
            self.reply(202, {"pod": POD, "accepted": True})

    def log_message(self, fmt, *args):
        # Probes hit every ten seconds; logging them would bury everything else.
        pass


def serve():
    server_class = HTTPServer if MODE == "blocking" else ThreadingHTTPServer
    print(f"{POD} serving on :{PORT} mode={MODE} max_tasks={MAX_TASKS}", flush=True)
    server_class(("", PORT), Handler).serve_forever()


def fire(seconds):
    # Send the request and hang up. A blocking server would hold the connection for the
    # whole task, and the caller only needs the task started.
    with socket.create_connection(("127.0.0.1", PORT), timeout=5) as conn:
        conn.sendall(
            f"POST /task?seconds={seconds} HTTP/1.1\r\nHost: localhost\r\n"
            "Content-Length: 0\r\nConnection: close\r\n\r\n".encode()
        )
        if MODE != "blocking":
            print(conn.recv(4096).decode().splitlines()[0])


def status():
    with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/status", timeout=5) as resp:
        print(json.load(resp)["inflight"])


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "serve"
    if command == "serve":
        serve()
    elif command == "fire":
        fire(float(sys.argv[2]))
    elif command == "status":
        status()
    else:
        sys.exit(f"unknown command {command}")
