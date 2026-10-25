# Agents Are Not Microservices

The labs behind "Agents Are Not Microservices: Operating Autonomous AI on Kubernetes",
a talk by [Lanay Marques](https://www.linkedin.com/in/lanaymarques/) and
[Henrique Santana](https://www.linkedin.com/in/henriquessantana/) at KubeCon NA 2026,
Cloud Native AI + Inference Day.

Kubernetes was built for services that answer in milliseconds and hold no state between
requests. An agent runs for minutes, keeps a task in memory, fans out to tools and other
agents, and can finish with no error anywhere and the wrong answer. Five defaults that work
for a microservice break for an agent, and this repository has one lab for each.

Each lab has a broken manifest and a fixed one. The scripts apply the broken one, show the
symptom, apply the fixed one, and assert both states. A break that stops reproducing fails
the build.

## Running it

You need Docker, Podman or Finch, `kind`, `kubectl`, `helm` and Python 3.12. Everything runs on a
laptop, with no GPU, no model and no cloud account.

```
labs/probes/00-setup.sh     # creates the cluster if it is missing
labs/probes/10-break.sh     # applies the broken manifest, shows the symptom
labs/probes/20-observe.sh   # the kubectl commands that show why
labs/probes/30-fix.sh       # applies the fixed manifest
labs/probes/40-verify.sh    # checks the fixed state as deployed, exits non-zero on failure
labs/probes/99-teardown.sh  # deletes the lab's namespace, keeps the cluster
labs/probes/run.sh          # setup, then 10, 20, 30 and 40 in one go, stops at the first failure
```

Every lab has these six numbered scripts and its own namespace, and any lab runs on its own.
The communication and observability labs add scripts numbered 50 and up, which go further
than the fix. `run.sh` leaves them out, and CI runs them after it. Run `00-setup.sh` before
the numbered scripts, or run `run.sh`, which does. One `kind` cluster named `anm` serves all
of them.

The scripts say what they are doing on `==>` lines and what the output shows on `-->` lines,
so you can follow without having seen the talk. On a terminal the step is bold, the `-->`
phrase is orange, PASS is blue and FAIL is red. No meaning depends on telling red from
green, so the colours work for colour blind readers. Set `NO_COLOR=1` to turn them off.
Logs and CI get plain text anyway.

If you read the code, start with `labs/probes`. The other four follow the same script
layout, each with its own stub agent, helpers and manifests.

When you are done with all of them, delete the shared cluster. That removes every lab
namespace, metrics-server and KEDA in one go.

```
kind delete cluster --name anm                                  # Docker
KIND_EXPERIMENTAL_PROVIDER=finch kind delete cluster --name anm  # Finch
KIND_EXPERIMENTAL_PROVIDER=podman kind delete cluster --name anm # Podman
```

Three things stay on the laptop after that. The setup scripts build the `anm-*:dev` images
in your container runtime before loading them into the cluster, so a copy stays there. The
observability lab writes its spans to `.anm/otel` in the repository, and every lab writes
its captures to its own `artifacts/` directory. From the repository root:

```
docker rmi docker.io/library/anm-{probes,scaling,disruption,communication,observability}:dev   # or podman, or finch
rm -rf .anm labs/*/artifacts
```

## The labs

| Lab | The default | What breaks |
|---|---|---|
| [probes](labs/probes) | Liveness and readiness on the same endpoint | A thinking agent looks healthy, or gets restarted mid-task |
| [scaling](labs/scaling) | HPA on CPU | The agent's CPU stays under target while its dependency queue grows |
| [disruption](labs/disruption) | PodDisruptionBudget and a grace period | A 90 step chain is lost on every delete, and the PDB never sees it |
| [communication](labs/communication) | Retry the call | Two replicas, one handle, and a charge that lands twice |
| [observability](labs/observability) | No errors means it worked | The A2A hop starts a new trace, and the killed pod exports nothing |

## Sources

Each link backs one claim in the talk or the labs.

### Probes

[Liveness, readiness and startup probes](https://kubernetes.io/docs/concepts/workloads/pods/probes/).
Liveness restarts the container. Readiness only removes the pod from the Service.

[LangGraph Agent Server](https://docs.langchain.com/langgraph-platform/langgraph-server).
It runs separate tasks at the same time by default, up to 10 per worker, and only one at a
time within a single conversation thread. A pod that looks free keeps taking tasks and runs
them all at once.

### Scaling

[KEDA](https://keda.sh/) and its
[Metrics API scaler](https://keda.sh/docs/latest/scalers/metrics-api/). The fix scales the
dependency on its own queue depth. The scaler's field names differ from the Prometheus
scaler's, so read it before copying the trigger.

### Disruption

[PodDisruptionBudget](https://kubernetes.io/docs/tasks/run-application/configure-pdb/). A
budget applies to the eviction API and to nothing else.

[Karpenter disruption](https://karpenter.sh/docs/concepts/disruption/). It covers
`do-not-disrupt`, its duration form, and the NodePool `terminationGracePeriod`.

[AX design](https://github.com/google/ax/blob/main/DESIGN.md). `SuspendTask` checkpoints the
agent's state and `ResumeTask` continues from it, so the platform has the checkpoint pattern
built in. Task state lives in Redis, because millions of short tasks in CRDs would overload
etcd.

### Communication

[MCP transports](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports).
Over Streamable HTTP every message is an HTTP POST to one endpoint, so a retried tool call
is a second POST.

[MCP tools](https://modelcontextprotocol.io/specification/2026-07-28/server/tools). Tools are
model-controlled, so the model decides which tool to call.

[MCP 2026-07-28 changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog).
Sessions are gone.

[SEP-2567](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2567). It replaces
sessions with server-minted handles passed as tool arguments.

[SEP-2575](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2575). It removes
the handshake, so every request carries its protocol version in `_meta`.

[Making retries safe with idempotent APIs](https://aws.amazon.com/builders-library/making-retries-safe-with-idempotent-APIs/).
The caller sends a unique request identifier and reuses it on every retry, so the service
can answer a retry with the first result instead of acting twice. The lab's action key does
the same job.

[Life of a Task](https://a2a-protocol.org/latest/topics/life-of-a-task/). A2A Tasks outlive
the request and need a shared store.

[A2A specification](https://a2a-protocol.org/latest/specification/). Send Message may be
idempotent through `messageId`, and the server decides whether it is.

### Observability

[Observability patterns for AI agents on Amazon EKS](https://aws.amazon.com/blogs/containers/observability-patterns-for-ai-agents-on-amazon-eks/).
The AWS Containers blog says that "an HTTP 200 response from an agent's endpoint says
nothing about whether the agent reasoned correctly, chose the right tools, or stayed within
budget."

[AI Agent Observability - Evolving Standards and Best Practices](https://opentelemetry.io/blog/2025/ai-agent-observability/).
The OpenTelemetry blog says that for an AI agent, "given its non-deterministic nature,
telemetry is also used as a feedback loop" for evaluation tools.

[SEP-414](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/414) and the
[OpenTelemetry MCP conventions](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/mcp.md).
Trace context travels in `params._meta`. HTTP headers cover the request and not the
messages inside it.

[GenAI events](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/gen-ai-events.md).
`gen_ai.evaluation.result` is parented to the span it scores. Every GenAI convention is
still marked Development.

[A2A #2103](https://github.com/a2aproject/A2A/issues/2103) and
[#2026](https://github.com/a2aproject/A2A/issues/2026). Both are open proposals to carry
trace context in message metadata. The
[a2a-python client transports](https://github.com/a2aproject/a2a-python/tree/main/src/a2a/client/transports)
inject none today.

[Batching span processor](https://opentelemetry.io/docs/specs/otel/trace/sdk/#batching-processor).
Finished spans wait up to five seconds before export.

[atexit](https://docs.python.org/3/library/atexit.html). It does not run when a signal kills
the process, so a killed pod loses the spans still waiting.

## Where agents run

The labs run agents as plain pods with standard Kubernetes objects. These projects build a
runtime for agents instead, and each one is worth reading next to the labs.

[Is a Pod the right deployment unit for an AI agent?](https://www.cncf.io/blog/2026/07/14/is-a-pod-the-right-deployment-unit-for-an-ai-agent/)
Lin Sun describes how kagent went from one runtime hosting many agents, to a Pod per
agent, to Agent Substrate, where an agent runs as an actor scheduled onto long-running
worker pods.

[Agent Substrate](https://github.com/agent-substrate/substrate). It is the control plane
above Kubernetes that places those actors. Google's [AX](https://github.com/google/ax), an
orchestrator for agent tasks, is built on it, and its README says agents are neither
stateless microservices nor run-to-completion batch jobs.

[kagent](https://kagent.dev/docs). You declare an agent as a Kubernetes custom resource,
and its controller runs it.

[Running agents on Kubernetes with Agent Sandbox](https://kubernetes.io/blog/2026/03/20/running-agents-on-kubernetes-with-agent-sandbox).
A new abstraction from SIG Apps, still in development, for agents that run for a long
time and keep their context.

[Amazon Bedrock AgentCore Runtime](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agents-tools-runtime.html).
A managed runtime that gives each agent session its own isolated environment.

[kars](https://github.com/Azure/kars). An agent reference stack for Kubernetes from
Microsoft, with one hardened sandbox per agent.

## License

Apache-2.0.
