"""Stub agent, fake dependency and load generator for the scaling lab. Standard library only.

  MODE=agent       POST /task fans out FANOUT concurrent calls to the dependency.
  MODE=dependency  POST /call holds one of CAPACITY slots for CALL_SECONDS.
  MODE=load        POSTs RATE tasks per second to the agent, forever.

  python3 agent.py get URL [KEY]   print one metrics value or document, used by the lab scripts

Both servers publish /metrics as JSON. Nothing scrapes them.

The servers run on asyncio, one thread each. A waiting call costs a coroutine, not a
thread, so the dependency's queue can climb into the thousands. The thread-per-connection
version stopped at the container's pid limit (about 1060 on kind and Finch) and closed
every new connection unanswered, which capped the queue and broke the metrics read.
"""

import asyncio
import json
import os
import socket
import sys
import threading
import time
import urllib.request
from urllib.parse import urlsplit

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

counters = {
    "agent_downstream_calls_inflight": 0,
    "agent_tasks_received": 0,
    "dependency_queue_depth": 0,
    "dependency_calls_inflight": 0,
    "dependency_calls_served": 0,
}


def bump(name, delta):
    # Single-threaded event loop, so a plain increment is atomic enough.
    counters[name] += delta


# ---- minimal HTTP/1.1 over asyncio, enough for the lab's four routes ----

async def read_request(reader):
    line = await reader.readline()
    if not line:
        return None, None
    method, path, _ = line.decode().split(" ", 2)
    length = 0
    while True:
        header = await reader.readline()
        if header in (b"\r\n", b"\n", b""):
            break
        name, _, value = header.decode().partition(":")
        if name.strip().lower() == "content-length":
            length = int(value)
    if length:
        await reader.readexactly(length)
    return method, path


async def write_response(writer, code, body):
    data = json.dumps(body).encode()
    reason = {200: "OK", 202: "Accepted", 404: "Not Found"}[code]
    head = (f"HTTP/1.1 {code} {reason}\r\nContent-Type: application/json\r\n"
            f"Content-Length: {len(data)}\r\nConnection: close\r\n\r\n").encode()
    try:
        writer.write(head + data)
        await writer.drain()
    except (BrokenPipeError, ConnectionResetError):
        pass
    finally:
        writer.close()


async def http_post(url, timeout):
    # POST with an empty body, read the whole answer, close. No keep-alive on purpose:
    # every call is its own connection, the shape a fan-out has on the wire.
    u = urlsplit(url)
    reader, writer = await asyncio.wait_for(
        asyncio.open_connection(u.hostname, u.port or 80), timeout=timeout)
    try:
        writer.write((f"POST {u.path or '/'} HTTP/1.1\r\nHost: {u.hostname}\r\n"
                      f"Content-Length: 0\r\nConnection: close\r\n\r\n").encode())
        await writer.drain()
        await asyncio.wait_for(reader.read(), timeout=timeout)
    finally:
        writer.close()


# ---- the three roles ----

async def downstream_call():
    bump("agent_downstream_calls_inflight", 1)
    try:
        await http_post(f"{DEPENDENCY_URL}/call", timeout=900)
    except (OSError, asyncio.TimeoutError, asyncio.IncompleteReadError) as err:
        print(f"downstream call failed: {err!r}", flush=True)
    finally:
        bump("agent_downstream_calls_inflight", -1)


def run_task():
    # The agent decides the fan-out at run time. Here it is always FANOUT, all at once.
    for _ in range(FANOUT):
        asyncio.ensure_future(downstream_call())


slots = None  # asyncio.Semaphore(CAPACITY), created inside the loop


async def serve_call():
    bump("dependency_queue_depth", 1)
    async with slots:
        bump("dependency_queue_depth", -1)
        bump("dependency_calls_inflight", 1)
        await asyncio.sleep(CALL_SECONDS)
        bump("dependency_calls_inflight", -1)
        bump("dependency_calls_served", 1)


async def handle(reader, writer):
    try:
        method, path = await read_request(reader)
    except (ValueError, asyncio.IncompleteReadError, ConnectionResetError):
        writer.close()
        return
    if method is None:
        writer.close()
        return
    if method == "GET" and path == "/metrics":
        prefix = "agent_" if MODE == "agent" else "dependency_"
        body = {k: v for k, v in counters.items() if k.startswith(prefix)}
        await write_response(writer, 200, {"pod": POD, **body})
    elif method == "GET" and path == "/health":
        await write_response(writer, 200, {"pod": POD})
    elif method == "POST" and MODE == "agent" and path == "/task":
        bump("agent_tasks_received", 1)
        run_task()
        await write_response(writer, 202, {"pod": POD, "accepted": True})
    elif method == "POST" and MODE == "dependency" and path == "/call":
        await serve_call()
        await write_response(writer, 200, {"pod": POD})
    else:
        await write_response(writer, 404, {"error": "not found"})


async def serve_async():
    global slots
    slots = asyncio.Semaphore(CAPACITY)
    # Twenty calls arrive together per task. The default backlog would drop connections
    # and turn the lab into a test of SYN retries.
    server = await asyncio.start_server(handle, "", PORT, backlog=4096)
    print(f"{POD} serving on :{PORT} mode={MODE}", flush=True)
    async with server:
        await server.serve_forever()


def serve():
    asyncio.run(serve_async())


def post_task():
    try:
        req = urllib.request.Request(f"{AGENT_URL}/task", method="POST")
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp.read()
    except OSError as err:
        print(f"task post failed: {err}", flush=True)


def load():
    # The agent answers 202 at once, so each post is a short-lived thread.
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
