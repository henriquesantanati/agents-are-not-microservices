# Observability

Assumption: a green trace means it worked.

## What breaks

The trace does cross into an MCP tool call. SEP-414 and the OpenTelemetry MCP conventions
say where the context travels, `params._meta`, and they are explicit that HTTP headers are
not enough on their own, since one connection can carry many MCP messages.

A2A carries nothing. The specification lists tracing under design goals and stops there,
the Python SDK's client transports inject no context, and issues
[#2103](https://github.com/a2aproject/A2A/issues/2103) and
[#2026](https://github.com/a2aproject/A2A/issues/2026) are still open proposals to fix
that. Per-request HTTP instrumentation would carry `traceparent` by header, because A2A is
JSON-RPC over one POST per message, and this stub deliberately has none. The header also
stops helping the moment a message outlives its request: streaming, a Task resumed later,
anything over gRPC. That is why both proposals put the context inside the message.

Then there is the part no propagation fixes. Every span can be OK and the answer can still
be wrong, and nothing in the GenAI conventions puts a quality signal on a span. A
`gen_ai.evaluation.result` event, emitted after the fact and parented to the span it
scores, is where that signal goes.

And a span only exists once it ends. The batching processor holds finished spans for up to
five seconds, and the Python SDK flushes them on `atexit`, which does not run when a signal
kills the process. Kill a pod mid-task and you lose the buffered spans plus the span of the
task it was running, because that one never ended.

## The stub

`agent/agent.py` runs as three Deployments with the OpenTelemetry SDK, writing spans as
JSON lines to a hostPath. On `kind` a hostPath lives inside the node container, so
`labs/kind-config.yaml` maps it to `.anm/otel` on your laptop and the scripts read it from
there.

A task is an `invoke_agent` span that thinks for a second, calls an MCP tool with trace
context in `params._meta`, delegates a step to the specialist over A2A, and answers
"The capital of France is Lyon."

| Setting | Broken | Fixed |
|---|---|---|
| `A2A_TRACE` | `off`, the message carries no context | `on`, `traceparent` goes into `message.metadata` under an extension URI and into the HTTP header, and the specialist reads it from the metadata |
| `SIGTERM_FLUSH` | `off` | `on`, the handler ends the open span with an `agent.interrupted` event and calls `force_flush` |
| evaluator | not run | `agent.py evaluate` scores finished runs and emits `gen_ai.evaluation.result` |

The metadata injection is our code following an open proposal. Nothing about it is
normative yet, and the extension URI is ours. The evaluator's rubric is a toy, a keyword
check; real evaluators are models or graders, and the event they emit is the same shape.

## Run it

```
./00-setup.sh      # cluster, namespace, image with the OpenTelemetry SDK
./10-break.sh      # green trace with a wrong answer, split A2A trace, trace lost on delete
./20-observe.sh    # one line per exported span, plus the evaluation events
./30-fix.sh        # one trace across the hop, the evaluation event, a flushed trace
./40-verify.sh     # asserts both states, exits non-zero on failure
./99-teardown.sh   # deletes the namespace and the span files
```

## What to look for

In both states the agent span, the MCP client span and the MCP server span share a trace
id, with `gen_ai.operation.name` set to `invoke_agent` and `execute_tool`.

Broken, the specialist's span sits under a second trace id, every span is OK or unset, and
the answer is wrong with nothing in the trace to say so. Delete the agent pod mid-task and
its trace id appears in no file at all.

Fixed, the specialist joins the agent's trace, the evaluation event carries the agent span's
id with `score.label` `fail`, and the deleted pod's span is in the file with status ERROR
and an `agent.interrupted` event.

One detail worth knowing when you watch the broken delete: it takes the full thirty second
grace period. Python as PID 1 with no handler installed does not get SIGTERM delivered at
all, so the pod waits for the SIGKILL. The spans are lost either way, but the pod does not
exit early.

SIGKILL still loses whatever the batch delay was holding, and the grace period has to leave
room for the flush.

## Sources

- [OpenTelemetry MCP conventions](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/mcp.md)
  and [SEP-414](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/414), for
  `params._meta` propagation and the span shape.
- [GenAI events](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/gen-ai-events.md),
  for `gen_ai.evaluation.result` and the line saying it should be parented to the span being
  evaluated. Note that these conventions are all still marked Development.
- [Batching span processor](https://opentelemetry.io/docs/specs/otel/trace/sdk/#batching-processor)
  and [atexit](https://docs.python.org/3/library/atexit.html), for what a killed pod loses.
