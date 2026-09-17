# Agents Are Not Microservices

Companion repository for "Agents Are Not Microservices: Operating Autonomous AI on
Kubernetes", Cloud Native AI + Inference Day, KubeCon NA 2026.
Lanay Marques and Henrique Santana.

Five Kubernetes assumptions that hold for a microservice and break for an agent. Each one
gets a lab with two manifests: the configuration most people write, and the one that
works. You apply the first, watch it fail, apply the second, watch the failure go away.

Everything runs on `kind` on a laptop. No GPU, no model, no cloud account, no cost. The
agents are stub Python files we wrote, because the talk is about how you operate an agent,
not about serving a model.

## What you need

Docker or Podman, `kind`, `kubectl`, `helm` (the scaling lab installs KEDA from its chart)
and Python 3.12 for the scripts that read spans on your laptop.

```
labs/probes/00-setup.sh     # creates the cluster if it is missing
labs/probes/10-break.sh     # apply the broken manifest, watch the symptom
labs/probes/20-observe.sh   # the kubectl commands that show why
labs/probes/30-fix.sh       # apply the fixed manifest
labs/probes/40-verify.sh    # asserts both states, exits non-zero on failure
labs/probes/99-teardown.sh  # deletes this lab's namespace, keeps the cluster
```

Every lab has the same six scripts and its own namespace. One cluster named `anm` serves
all of them.

## The labs

| Lab | Assumption it breaks | Ready |
|---|---|---|
| [probes](labs/probes) | Readiness means the process is up | yes |
| [scaling](labs/scaling) | Load means CPU | yes |
| [disruption](labs/disruption) | Pods are cattle | yes |
| [communication](labs/communication) | Retries are cheap | yes |
| [observability](labs/observability) | A green trace means it worked | yes |

## Sources

### The opener

- [Is a Pod the right deployment unit for an AI agent?](https://www.cncf.io/blog/2026/07/14/is-a-pod-the-right-deployment-unit-for-an-ai-agent/)
  is Lin Sun's CNCF post, where the sentence the talk opens with comes from.
- [Bringing Agentic AI to Kubernetes](https://www.solo.io/blog/bringing-agentic-ai-to-kubernetes-contributing-kagent-to-cncf)
  is Solo.io donating kagent to the CNCF, and it credits Lin Sun.
- [Running agents on Kubernetes with Agent Sandbox](https://kubernetes.io/blog/2026/03/20/running-agents-on-kubernetes-with-agent-sandbox)
  and [kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) are
  SIG Apps building a primitive for what runs an agent.
- [AWS AgentCore Runtime](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime.html)
  and [Microsoft kars](https://github.com/microsoft/kars) are the other two, from other
  companies, within five months of each other.
- [kagent docs](https://kagent.dev/docs) show what it looks like when a controller owns the
  agent pod spec. That is the thesis of the talk, and the reason kagent stays out of the
  labs: with a controller there is no broken manifest left to apply.

### Probes

- [Liveness, readiness and startup probes](https://kubernetes.io/docs/concepts/workloads/pods/probes/)
  defines what each failure does: liveness restarts the container, readiness only removes
  the pod from Service endpoints.

### Scaling

- [KEDA](https://keda.sh/) is the CNCF autoscaler the fix uses.
- [Metrics API scaler](https://keda.sh/docs/latest/scalers/metrics-api/) is worth reading
  before copying the trigger, because its field names differ from the Prometheus scaler's.

### Disruption

- [PodDisruptionBudget](https://kubernetes.io/docs/tasks/run-application/configure-pdb/)
  says a budget limits voluntary disruptions, which is the eviction API and nothing else.
- [Karpenter disruption](https://karpenter.sh/docs/concepts/disruption/) defines
  `do-not-disrupt`, the duration form of it, and the NodePool `terminationGracePeriod`
  that stops a pod blocking a node forever.

### Communication

- [MCP 2026-07-28 changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog)
  records the removal of sessions.
- [SEP-2567](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2567)
  replaces them with server-minted handles passed as ordinary tool arguments.
- [SEP-2575](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2575)
  removes the handshake, so every request carries its protocol version in `_meta`.
- [Life of a Task](https://a2a-protocol.org/latest/topics/life-of-a-task/) shows why A2A
  Tasks outlive a request and need a shared store.
- The A2A specification's [Idempotency section](https://a2a-protocol.org/latest/specification/)
  says Send Message *may* be idempotent through `messageId`, which leaves it to the server.

### Observability

- [SEP-414](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/414) puts
  trace context in `params._meta`.
- [OpenTelemetry MCP conventions](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/mcp.md)
  define the span shape and say HTTP headers alone do not cover individual MCP messages.
- [semantic-conventions-genai](https://github.com/open-telemetry/semantic-conventions-genai)
  is where the GenAI conventions moved, and every one of them is still marked Development.
- [GenAI events](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/gen-ai-events.md)
  defines `gen_ai.evaluation.result` and says it should be parented to the span it scores.
- The A2A specification's [design goals](https://a2a-protocol.org/latest/specification/)
  name tracing without specifying it.
- [A2A #2103](https://github.com/a2aproject/A2A/issues/2103) and
  [#2026](https://github.com/a2aproject/A2A/issues/2026) are the open proposals to carry
  trace context in message metadata. Both are still open.
- [a2a-python client transports](https://github.com/a2aproject/a2a-python/tree/main/src/a2a/client/transports)
  inject no trace context today.
- [Batching span processor](https://opentelemetry.io/docs/specs/otel/trace/sdk/#batching-processor)
  sets the five second delay that a killed pod loses.
- [atexit](https://docs.python.org/3/library/atexit.html) does not run when a signal kills
  the process.

## License

Apache-2.0.
