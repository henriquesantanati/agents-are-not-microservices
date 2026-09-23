# Observability

An agent answers by calling a tool and delegating a step to another agent. Tracing that
means the context has to survive two hops, MCP and A2A, and the trace has to survive the
pod. Neither is free, and even when both work the trace can be green and the answer wrong.

## The problem

The MCP hop is specified. SEP-414 and the OpenTelemetry MCP conventions put the context in
`params._meta`, and they are explicit that HTTP headers are not enough, because one
connection carries many messages.

The A2A hop is not. The specification lists tracing under design goals and stops there,
the Python SDK's client transports inject nothing, and issues #2103 and #2026 are open
proposals to fix it. Per-request HTTP instrumentation on both sides would carry
`traceparent` in the header, and this stub has none, so what you see is what the protocol
gives you. The delegated step starts a trace of its own, and the picture of the request
has a hole in it exactly where the agent asked another agent for help.

Then the part no propagation fixes. Every span can be OK and the answer can still be
wrong, and nothing in the GenAI conventions puts a quality signal on a span. A
`gen_ai.evaluation.result` event, emitted after the fact and parented to the span it
scores, is where that signal goes.

And a span only exists once it ends. The batching processor holds finished spans for up
to five seconds, and the Python SDK flushes them on `atexit`, which a signal skips. Kill
a pod mid-task and you lose the buffered spans and the span of the task it was running,
because that one never ended. On `kind` the delete takes the whole grace period too:
Python is PID 1, and PID 1 is not sent a signal it has no handler for, so nothing happens
until the SIGKILL.

## The stub

Three Deployments with the OpenTelemetry SDK, writing spans as JSON lines to a hostPath.
On `kind` a hostPath lives inside the node container, so `labs/kind-config.yaml` maps it
to `.anm/otel` on the laptop and the scripts read it from there.

A task is an `invoke_agent` span that thinks for a second, calls an MCP tool with the
context in `params._meta`, delegates a step to the specialist over A2A, and answers
"The capital of France is Lyon."

Two environment values are the whole difference. `A2A_TRACE` puts `traceparent` into
`message.metadata` under an extension URI, which is what #2103 proposes, and has the
specialist read it from there. `SIGTERM_FLUSH` installs a handler that ends the open span
with an `agent.interrupted` event and calls `force_flush`.

The metadata injection is our code following an open proposal. Nothing about it is
normative yet, and the extension URI is ours. The evaluator's rubric is a keyword check;
real evaluators are models or graders, and the event they emit is the same shape.

## Run it

The numbered scripts expect the cluster, namespace and image that `00-setup.sh` creates,
so run it first. `run.sh` runs it for you.

```
./00-setup.sh      # cluster, namespace, image with the OpenTelemetry SDK
./10-break.sh      # a green trace with the wrong answer, a split trace, a trace that never arrives
./20-observe.sh    # the settings, the span files, one line per span, the evaluation events
./30-fix.sh        # one trace across both hops, a score on the span, a flushed interruption
./40-verify.sh     # checks the fixed state as deployed, exits non-zero on failure
./99-teardown.sh   # deletes the observability namespace and the span files
./run.sh           # setup, then 10, 20, 30 and 40 in one go, stops at the first failure
```

## What to look for

`10-break.sh` and `30-fix.sh` run the same two tasks, one that finishes and one that is
killed halfway, and print every exported span.

| | Broken | Fixed |
|---|---|---|
| Agent span and MCP tool spans | One trace id, `invoke_agent` and `execute_tool` | Same. The MCP hop was never the problem |
| The delegated step | A second trace id. Nothing carried the context across the A2A hop | The agent's trace id, carried in `message.metadata` |
| The answer | Wrong, with every span OK and nothing saying so | Wrong, and a `gen_ai.evaluation.result` event on the agent span says `fail` |
| Agent pod deleted mid-task | The trace id is in no file. The delete also waits out the full grace period | The span is in the file, `ERROR`, with an `agent.interrupted` event |

SIGKILL still loses whatever the batch delay was holding, and the grace period has to
leave room for the flush.

Each script prints what it is doing on `==>` lines, what the output shows on `-->` lines,
and one PASS or FAIL per check. `10-break.sh` fails if the problem stops reproducing,
`30-fix.sh` and `40-verify.sh` fail if the fix stops working. `run.sh` runs setup and the
four in order, and is what CI runs.

## Sources

[SEP-414](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/414) and the
[OpenTelemetry MCP conventions](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/mcp.md).
Context travels in `params._meta`. Headers cover the request, not the messages inside it.

[GenAI events](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/gen-ai-events.md).
`gen_ai.evaluation.result`, parented to the span being evaluated. Every GenAI convention
is still marked Development.

[A2A #2103](https://github.com/a2aproject/A2A/issues/2103) and
[#2026](https://github.com/a2aproject/A2A/issues/2026). The open proposals this lab
follows. The [a2a-python client transports](https://github.com/a2aproject/a2a-python/tree/main/src/a2a/client/transports)
inject nothing today.

[Batching span processor](https://opentelemetry.io/docs/specs/otel/trace/sdk/#batching-processor)
and [atexit](https://docs.python.org/3/library/atexit.html). Five seconds of finished
spans, and a signal that skips the flush.
