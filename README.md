# Agents Are Not Microservices

The labs behind "Agents Are Not Microservices: Operating Autonomous AI on Kubernetes",
a talk by [Lanay Marques](https://www.linkedin.com/in/lanaymarques/) and
[Henrique Santana](https://www.linkedin.com/in/henriquessantana/) at KubeCon NA 2026,
Cloud Native AI + Inference Day.

Kubernetes was built for services that answer in milliseconds and hold no state between
requests. An agent runs for minutes, keeps a task in memory, fans out to tools and other
agents, and can finish with every span green and the wrong answer. Five defaults that work
for a microservice break for an agent. This repository has one lab per default.

Each lab has a broken manifest and a fixed one. The scripts apply the broken one, show the
symptom, apply the fixed one, and assert both states. A break that stops reproducing fails
the build.

## Running it

You need Docker, Podman or Finch, `kind`, `kubectl`, `helm` and Python 3.12. Everything runs on a
laptop. No GPU, no model, no cloud account.

```
labs/probes/00-setup.sh     # creates the cluster if it is missing
labs/probes/10-break.sh     # applies the broken manifest, shows the symptom
labs/probes/20-observe.sh   # the kubectl commands that show why
labs/probes/30-fix.sh       # applies the fixed manifest
labs/probes/40-verify.sh    # asserts both states, exits non-zero on failure
labs/probes/99-teardown.sh  # deletes the lab's namespace, keeps the cluster
```

Every lab has the same six scripts and its own namespace, and any lab runs on its own. One
`kind` cluster named `anm` serves all of them. If you read the code, start with
`labs/probes`. The other four are the same scripts with different manifests.

## The labs

| Lab | The default | What breaks |
|---|---|---|
| [probes](labs/probes) | Liveness and readiness on the same endpoint | A thinking agent looks healthy, or gets restarted mid-task |
| [scaling](labs/scaling) | HPA on CPU | The agent's CPU stays under target while its dependency queue grows |
| [disruption](labs/disruption) | PodDisruptionBudget and a grace period | A 90 step chain is lost on every delete, and the PDB never sees it |
| [communication](labs/communication) | Retry the call | Two replicas, one handle, and a charge that lands twice |
| [observability](labs/observability) | A green trace means it worked | The A2A hop starts a new trace, and the killed pod exports nothing |

## Sources

Each link backs one claim in the talk.

### The opener

[Is a Pod the right deployment unit for an AI agent?](https://www.cncf.io/blog/2026/07/14/is-a-pod-the-right-deployment-unit-for-an-ai-agent/)
Lin Sun's question, which the talk opens with.
[Running agents on Kubernetes with Agent Sandbox](https://kubernetes.io/blog/2026/03/20/running-agents-on-kubernetes-with-agent-sandbox),
[AWS AgentCore Runtime](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime.html)
and [kars](https://github.com/Azure/kars), Microsoft's agent reference stack for Kubernetes.
Three runtimes for agents in five months, from SIG Apps and two vendors.
[kagent](https://kagent.dev/docs). A controller owning the agent pod spec, which is where
the talk lands. It stays out of the labs because with a controller there is no broken
manifest left to apply.

### Probes

[Liveness, readiness and startup probes](https://kubernetes.io/docs/concepts/workloads/pods/probes/).
Liveness restarts the container. Readiness only removes the pod from the Service.

### Scaling

[KEDA](https://keda.sh/) and its
[Metrics API scaler](https://keda.sh/docs/latest/scalers/metrics-api/). The fix scales the
dependency on its own queue depth. The scaler's field names differ from the Prometheus
scaler's, so read it before copying the trigger.

### Disruption

[PodDisruptionBudget](https://kubernetes.io/docs/tasks/run-application/configure-pdb/). A
budget gates the eviction API and nothing else.
[Karpenter disruption](https://karpenter.sh/docs/concepts/disruption/). `do-not-disrupt`,
its duration form, and the NodePool `terminationGracePeriod`.

### Communication

[MCP 2026-07-28 changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog).
Sessions are gone. [SEP-2567](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2567)
replaces them with server-minted handles passed as tool arguments.
[SEP-2575](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2575) removes
the handshake, so every request carries its protocol version in `_meta`.
[Life of a Task](https://a2a-protocol.org/latest/topics/life-of-a-task/). A2A Tasks outlive
the request and need a shared store. The
[A2A specification](https://a2a-protocol.org/latest/specification/) says Send Message may
be idempotent through `messageId`. The server decides.

### Observability

[SEP-414](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/414) and the
[OpenTelemetry MCP conventions](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/mcp.md).
Trace context travels in `params._meta`. HTTP headers cover the request and not the
messages inside it.
[GenAI events](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/gen-ai-events.md).
`gen_ai.evaluation.result`, parented to the span it scores. Every GenAI convention is still
marked Development.
[A2A #2103](https://github.com/a2aproject/A2A/issues/2103) and
[#2026](https://github.com/a2aproject/A2A/issues/2026). Open proposals to carry trace
context in message metadata. The
[a2a-python client transports](https://github.com/a2aproject/a2a-python/tree/main/src/a2a/client/transports)
inject none today.
[Batching span processor](https://opentelemetry.io/docs/specs/otel/trace/sdk/#batching-processor).
Finished spans wait up to five seconds. [atexit](https://docs.python.org/3/library/atexit.html)
does not run when a signal kills the process, so a killed pod loses them.

## License

Apache-2.0.
