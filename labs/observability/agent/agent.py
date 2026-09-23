"""Stub agent, MCP server, A2A specialist and evaluator for the observability lab.

Servers use the OpenTelemetry SDK and export spans to files under OTEL_DIR, a hostPath,
so the files outlive the pod that wrote them.

  MODE=agent       POST /task runs one task: think, call an MCP tool, delegate to the
                   specialist over A2A, answer. The answer is wrong on purpose.
  MODE=mcp         JSON-RPC tools/call. Extracts trace context from params._meta.
  MODE=specialist  JSON-RPC SendMessage (A2A v1.0).

  A2A_TRACE=off|on       on: inject traceparent into message.metadata under the extension
                         URI (and the HTTP header), and extract it in the specialist.
  SIGTERM_FLUSH=off|on   on: end open spans with an interruption event and force_flush.

Commands:
  python3 agent.py task ID THINK_SECONDS [detach]   inside the agent pod
  python3 agent.py evaluate                        inside the agent pod, fixed state
  python3 agent.py report DIR ID                   on the laptop, standard library only
  python3 agent.py spans DIR [TASK_ID]             on the laptop, one line per exported span
"""

import glob
import json
import os
import signal
import socket
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE = os.environ.get("MODE", "agent")
PORT = int(os.environ.get("PORT", "8080"))
POD = os.environ.get("POD_NAME", socket.gethostname())
OTEL_DIR = os.environ.get("OTEL_DIR", "/otel")
A2A_TRACE = os.environ.get("A2A_TRACE", "off")
SIGTERM_FLUSH = os.environ.get("SIGTERM_FLUSH", "off")
MCP_URL = os.environ.get("MCP_URL", "http://mcp")
SPECIALIST_URL = os.environ.get("SPECIALIST_URL", "http://specialist")

# Where #2103 and #2026 propose the context travels: message.metadata under the URI of
# an extension. The URI is ours. The protocol has nothing normative here yet.
TRACE_EXTENSION_URI = "https://github.com/henriquesantanati/agents-are-not-microservices/extensions/a2a-trace-context/v1"

QUESTION = "What is the capital of France?"
WRONG_ANSWER = "The capital of France is Lyon."


# ---------- OpenTelemetry setup, servers only ----------

def setup_tracing():
    global trace, propagate, StatusCode, SpanKind, provider, tracer
    from opentelemetry import propagate, trace
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter
    from opentelemetry.trace import SpanKind, StatusCode

    out = open(f"{OTEL_DIR}/spans-{POD}-{os.getpid()}.jsonl", "a", buffering=1)
    provider = TracerProvider(resource=Resource.create({"service.name": MODE, "k8s.pod.name": POD}))
    # Default batching: finished spans wait up to five seconds before export.
    provider.add_span_processor(BatchSpanProcessor(
        ConsoleSpanExporter(out=out, formatter=lambda span: span.to_json(indent=None) + "\n")))
    trace.set_tracer_provider(provider)
    tracer = trace.get_tracer("anm.observability")


def post_json(url, body, headers=None):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", **(headers or {})})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


# ---------- agent ----------

open_spans = {}
open_lock = threading.Lock()


def call_tool(task_id):
    with tracer.start_as_current_span("tools/call get_weather", kind=SpanKind.CLIENT, attributes={
        "mcp.method.name": "tools/call", "gen_ai.operation.name": "execute_tool",
        "gen_ai.tool.name": "get_weather", "jsonrpc.request.id": "1", "anm.task.id": task_id,
    }):
        meta = {"io.modelcontextprotocol/protocolVersion": "2026-07-28"}
        propagate.inject(meta)  # traceparent and tracestate, into params._meta
        return post_json(f"{MCP_URL}/mcp", {
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": "get_weather", "arguments": {"city": "Paris"}, "_meta": meta},
        })


def delegate(task_id):
    with tracer.start_as_current_span("invoke_agent specialist", kind=SpanKind.CLIENT, attributes={
        "gen_ai.operation.name": "invoke_agent", "gen_ai.agent.name": "specialist", "anm.task.id": task_id,
    }):
        metadata, headers = {"anm.task.id": task_id}, {}
        if A2A_TRACE == "on":
            carrier = {}
            propagate.inject(carrier)
            metadata[TRACE_EXTENSION_URI] = carrier
            headers = dict(carrier)
        return post_json(f"{SPECIALIST_URL}/a2a", {
            "jsonrpc": "2.0", "id": 1, "method": "SendMessage",
            "params": {"message": {"role": "ROLE_USER", "messageId": task_id, "metadata": metadata,
                                   "parts": [{"text": QUESTION}]}},
        }, headers)


def run_task(task_id, think_seconds, started):
    with tracer.start_as_current_span("invoke_agent travel-planner", end_on_exit=True, attributes={
        "gen_ai.operation.name": "invoke_agent", "gen_ai.agent.name": "travel-planner", "anm.task.id": task_id,
    }) as span:
        ctx = span.get_span_context()
        with open_lock:
            open_spans[task_id] = span
        started.update(trace_id=format(ctx.trace_id, "032x"), span_id=format(ctx.span_id, "016x"))
        started["event"].set()
        try:
            time.sleep(think_seconds)  # reasoning
            call_tool(task_id)
            delegate(task_id)
            # Every span is fine. The answer is not.
            with open(f"{OTEL_DIR}/results-{POD}.jsonl", "a") as f:
                f.write(json.dumps({"task_id": task_id, "question": QUESTION, "answer": WRONG_ANSWER,
                                    "trace_id": started["trace_id"], "span_id": started["span_id"]}) + "\n")
            started["answer"] = WRONG_ANSWER
        finally:
            with open_lock:
                open_spans.pop(task_id, None)


def on_sigterm(signum, frame):
    # Without this, Python dies on SIGTERM without running atexit, so the SDK never
    # flushes, and the span of the running task never ends, so it is never exported.
    with open_lock:
        spans = list(open_spans.values())
    for span in spans:
        span.add_event("agent.interrupted", {"signal": "SIGTERM"})
        span.set_status(StatusCode.ERROR, "interrupted by SIGTERM")
        span.end()
    provider.force_flush(timeout_millis=10000)
    print(f"SIGTERM: ended {len(spans)} open span(s) and flushed", flush=True)
    sys.exit(0)


# ---------- servers ----------

class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply(200, {"pod": POD}) if self.path == "/health" else self.reply(404, {})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length)) if length else {}
        if MODE == "agent" and self.path == "/task":
            started = {"event": threading.Event()}
            worker = threading.Thread(target=run_task, args=(body["id"], body["think"], started), daemon=True)
            worker.start()
            started["event"].wait()
            if not body.get("detach"):
                worker.join()
            started.pop("event")
            return self.reply(200, started)
        if MODE == "mcp" and self.path == "/mcp":
            params = body["params"]
            parent = propagate.extract(params.get("_meta", {}))
            with tracer.start_as_current_span("tools/call get_weather", context=parent, kind=SpanKind.SERVER, attributes={
                "mcp.method.name": "tools/call", "gen_ai.operation.name": "execute_tool",
                "gen_ai.tool.name": params["name"], "jsonrpc.request.id": str(body["id"]),
            }):
                return self.reply(200, {"jsonrpc": "2.0", "id": body["id"], "result": {
                    "resultType": "complete", "content": [{"type": "text", "text": "sunny, 24C"}]}})
        if MODE == "specialist" and self.path == "/a2a":
            message = body["params"]["message"]
            carrier = message.get("metadata", {}).get(TRACE_EXTENSION_URI, {}) if A2A_TRACE == "on" else {}
            parent = propagate.extract(carrier)
            with tracer.start_as_current_span("invoke_agent specialist", context=parent, kind=SpanKind.SERVER, attributes={
                "gen_ai.operation.name": "invoke_agent", "gen_ai.agent.name": "specialist",
                "anm.task.id": message.get("metadata", {}).get("anm.task.id", ""),
            }):
                return self.reply(200, {"jsonrpc": "2.0", "id": body["id"], "result": {"message": {
                    "role": "ROLE_AGENT", "messageId": message["messageId"] + "-reply",
                    "parts": [{"text": "Lyon"}]}}})
        self.reply(404, {})

    def log_message(self, fmt, *args):
        pass


def serve():
    setup_tracing()
    if MODE == "agent" and SIGTERM_FLUSH == "on":
        signal.signal(signal.SIGTERM, on_sigterm)
    print(f"{POD} serving on :{PORT} mode={MODE} a2a_trace={A2A_TRACE} sigterm_flush={SIGTERM_FLUSH}", flush=True)
    server = ThreadingHTTPServer(("", PORT), Handler)
    server.daemon_threads = True
    server.serve_forever()


# ---------- commands ----------

def task(task_id, think, detach=False):
    print(json.dumps(post_json(f"http://127.0.0.1:{PORT}/task", {"id": task_id, "think": think, "detach": detach})))


def evaluate():
    """A separate job. Reads finished runs after the fact and scores the output."""
    from opentelemetry._logs import LogRecord
    from opentelemetry.sdk._logs import LoggerProvider
    from opentelemetry.sdk._logs.export import ConsoleLogRecordExporter, SimpleLogRecordProcessor
    from opentelemetry.trace import TraceFlags

    out = open(f"{OTEL_DIR}/events-evaluator-{os.getpid()}.jsonl", "a", buffering=1)
    logs = LoggerProvider()
    logs.add_log_record_processor(SimpleLogRecordProcessor(
        ConsoleLogRecordExporter(out=out, formatter=lambda record: record.to_json(indent=None) + "\n")))
    logger = logs.get_logger("anm.evaluator")
    count = 0
    for path in glob.glob(f"{OTEL_DIR}/results-*.jsonl"):
        for line in open(path):
            run = json.loads(line)
            # A toy rubric. Real evaluators are models or graders; the event is the same.
            score = 1.0 if "Paris" in run["answer"] else 0.4 if "France" in run["answer"] else 0.0
            logger.emit(LogRecord(
                trace_id=int(run["trace_id"], 16), span_id=int(run["span_id"], 16),
                trace_flags=TraceFlags(TraceFlags.SAMPLED),
                event_name="gen_ai.evaluation.result",
                attributes={"gen_ai.evaluation.name": "correctness", "gen_ai.evaluation.score.value": score,
                            "gen_ai.evaluation.score.label": "pass" if score >= 0.8 else "fail",
                            "anm.task.id": run["task_id"]},
            ))
            count += 1
    logs.shutdown()
    print(json.dumps({"evaluated": count}))


def report(directory, task_id):
    """Standard library only, so it runs on the laptop against the hostPath files."""
    spans, events = [], []
    for path in glob.glob(os.path.join(directory, "spans-*.jsonl")):
        spans += [json.loads(line) for line in open(path) if line.strip()]
    for path in glob.glob(os.path.join(directory, "events-*.jsonl")):
        events += [json.loads(line) for line in open(path) if line.strip()]

    def pick(name, kind):
        for s in spans:
            if s["name"] == name and s["kind"].endswith(kind) and s["attributes"].get("anm.task.id") == task_id:
                return {"trace_id": s["context"]["trace_id"], "span_id": s["context"]["span_id"],
                        "status": s["status"]["status_code"], "events": [e["name"] for e in s["events"]],
                        "operation": s["attributes"].get("gen_ai.operation.name")}
        return None

    # The MCP server span carries no task id; it is found through its parent, the client span.
    tool_client = pick("tools/call get_weather", "CLIENT")
    tool_server = None
    for s in spans:
        if tool_client and s["kind"].endswith("SERVER") and s["parent_id"] == tool_client["span_id"]:
            tool_server = {"trace_id": s["context"]["trace_id"], "operation": s["attributes"].get("gen_ai.operation.name"),
                           "status": s["status"]["status_code"]}
    agent = pick("invoke_agent travel-planner", "INTERNAL")
    trace_ids = {x["trace_id"] for x in (agent, tool_client) if x}
    in_trace = [s for s in spans if s["context"]["trace_id"] in trace_ids]
    print(json.dumps({
        "agent": agent, "tool_client": tool_client, "tool_server": tool_server,
        "a2a_client": pick("invoke_agent specialist", "CLIENT"),
        "specialist": pick("invoke_agent specialist", "SERVER"),
        "trace_in_file": any(s["context"]["trace_id"] == (agent or {}).get("trace_id") for s in spans),
        "statuses": sorted({s["status"]["status_code"] for s in in_trace
                            if "agent.interrupted" not in [e["name"] for e in s["events"]]}),
        "evaluations": [{"span_id": e.get("span_id"), "trace_id": e.get("trace_id"),
                         "event_name": e.get("event_name"), "attributes": e.get("attributes")}
                        for e in events if (e.get("attributes") or {}).get("anm.task.id") == task_id],
    }))


def list_spans(directory, task_id=None):
    """One line per exported span: name, kind, trace id, status, events. With a task id,
    only the traces that task's spans belong to, so the MCP server span, which carries no
    task id, stays in the picture."""
    spans = []
    for path in sorted(glob.glob(os.path.join(directory, "spans-*.jsonl"))):
        spans += [json.loads(line) for line in open(path) if line.strip()]
    if task_id:
        traces = {s["context"]["trace_id"] for s in spans if s["attributes"].get("anm.task.id") == task_id}
        spans = [s for s in spans if s["context"]["trace_id"] in traces]
    for s in spans:
        print(f"{s['name']:30} {s['kind'][9:]:8} {s['context']['trace_id']} "
              f"{s['status']['status_code']:6} task={s['attributes'].get('anm.task.id', '-'):10} "
              f"{[e['name'] for e in s['events']]}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "serve"
    if cmd == "spans":
        list_spans(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
    elif cmd == "task":
        task(sys.argv[2], float(sys.argv[3]), len(sys.argv) > 4 and sys.argv[4] == "detach")
    elif cmd == "evaluate":
        evaluate()
    elif cmd == "report":
        report(sys.argv[2], sys.argv[3])
    else:
        serve()
