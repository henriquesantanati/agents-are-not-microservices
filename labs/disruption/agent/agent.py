"""Stub agent for the disruption lab. Standard library only.

  python3 agent.py serve     run a STEPS step chain and serve HTTP on the side
  python3 agent.py status    print the last completed step
  python3 agent.py oom       ask the agent to allocate past its memory limit

CHECKPOINT=none  the chain lives in memory. On SIGTERM the agent tries to finish the
                 chain inside the grace period, which is what a long grace period hopes for.
CHECKPOINT=all   the chain is written to CHECKPOINT_PATH after every step, on
                 POST /checkpoint (the preStop hook), and on SIGTERM. A new process
                 resumes from it.

The first log line of every process says where the chain starts. The lab asserts on it.
"""

import json
import os
import signal
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CHECKPOINT = os.environ.get("CHECKPOINT", "none")
CHECKPOINT_PATH = os.environ.get("CHECKPOINT_PATH", "/state/checkpoint.json")
STEPS = int(os.environ.get("STEPS", "90"))
STEP_SECONDS = float(os.environ.get("STEP_SECONDS", "2"))
PORT = int(os.environ.get("PORT", "8080"))

lock = threading.Lock()
step = 0  # last completed step
saved = -1


def log(msg):
    print(msg, flush=True)


def load_checkpoint():
    if CHECKPOINT != "all":
        return 0, "checkpointing disabled"
    try:
        with open(CHECKPOINT_PATH) as f:
            return json.load(f)["step"], "checkpoint"
    except FileNotFoundError:
        return 0, "no checkpoint"


def checkpoint(reason):
    """Write the chain's progress where the next pod can read it."""
    global saved
    if CHECKPOINT != "all":
        return
    with lock:
        if step == saved:
            return
        tmp = CHECKPOINT_PATH + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"step": step, "reason": reason, "at": time.time()}, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, CHECKPOINT_PATH)
        saved = step
    log(f"checkpoint step={step} reason={reason}")


def on_sigterm(signum, frame):
    if CHECKPOINT == "all":
        checkpoint("sigterm")
        log(f"SIGTERM received, checkpointed at step {step}, exiting")
        sys.exit(0)
    # No checkpoint to fall back on, so the only hope is finishing inside the grace period.
    log(f"SIGTERM received at step {step}, finishing the chain ({STEPS - step} steps left)")


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/health", "/status"):
            self.reply(200, {"step": step, "steps": STEPS, "checkpoint": CHECKPOINT})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/checkpoint":
            # Logged even when the periodic checkpoint already holds this step, so the log
            # shows the hook ran.
            log(f"preStop hook called at step {step}")
            checkpoint("prestop")
            self.reply(200, {"step": step})
        elif self.path == "/oom":
            self.reply(202, {"step": step})
            threading.Thread(target=allocate, daemon=True).start()
        else:
            self.reply(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        pass


def allocate():
    # Grows past any sensible limit. The kernel's OOM killer sends SIGKILL, which no
    # handler and no hook can see.
    hog = []
    for _ in range(64):
        hog.append(bytearray(32 * 1024 * 1024))
        time.sleep(0.05)
    log("allocated 2GiB and nothing stopped it, the memory limit is not enforced")


def serve():
    global step, saved
    step, source = load_checkpoint()
    if source == "checkpoint":
        saved = step
        log(f"resume chain at step {step} of {STEPS} from checkpoint")
    else:
        log(f"start chain at step 0 of {STEPS}, {source}")

    signal.signal(signal.SIGTERM, on_sigterm)
    threading.Thread(target=ThreadingHTTPServer(("", PORT), Handler).serve_forever, daemon=True).start()

    while step < STEPS:
        time.sleep(STEP_SECONDS)  # one reasoning step
        with lock:
            step += 1
        checkpoint("periodic")
    log(f"chain complete at step {STEPS}")
    while True:
        time.sleep(3600)


def status():
    with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/status", timeout=5) as resp:
        print(json.load(resp)["step"])


def oom():
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/oom", method="POST")
    with urllib.request.urlopen(req, timeout=5) as resp:
        print(resp.status)


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "serve"
    {"serve": serve, "status": status, "oom": oom}.get(command, lambda: sys.exit(f"unknown command {command}"))()
