# Communication

Assumption: retries are cheap.

## What breaks

MCP dropped sessions in the `2026-07-28` revision, so a server that keeps no local state
needs no session affinity at all. Any replica can answer any request. A server that mints a
handle and keeps the matching state in its own memory is a different story: the next call
lands on another replica and the handle means nothing there.

A2A Tasks are stateful by design. They outlive the request that created them, so they need
a shared store if any replica is going to serve them.

Neither protocol makes a retry safe on its own. A2A says Send Message *may* be idempotent
through `messageId`, which puts it on the server. MCP says nothing at all, and the same
revision that removed sessions also removed stream resumability, so a client whose response
stream breaks has to reissue the request with a new id. Retries are not an edge case here,
they are in the spec.

Then there is the client. Open one connection to the MCP Service and keep it for the life
of the process and you are pinned to one replica, because kube-proxy balances per
connection. New replicas never see your traffic, and a rollout of the server kills your
connection mid-task. Open a connection per request and neither happens. Without sessions
there is nothing to lose by reconnecting, so the per-request client costs a round trip and
that is all.

## The stub

`agent/agent.py` runs as four Deployments from one image, all behind plain Services with no
session affinity.

| Deployment | Replicas | Broken | Fixed |
|---|---|---|---|
| `mcp` | 2 | `MCP_STATE=local-handle`, the cart lives in the pod's memory | `MCP_STATE=stateless`, the handle carries the cart |
| `mcp` | | `IDEMPOTENCY=off`, `charge` ignores the key | `IDEMPOTENCY=on`, `charge` claims the key in the store first |
| `a2a` | 2 | `TASK_STORE=local` | `TASK_STORE=shared` |
| `store` | 1 | the shared key-value store and the side effect log | same |
| `client` | 1 | where the client commands run | same |

Every response names the replica that served it, which is the only way to see any of this
from outside. Requests carry `io.modelcontextprotocol/protocolVersion` in `_meta` and
results carry `resultType`, both of which the `2026-07-28` revision requires now that there
is no handshake. A2A calls use the v1.0 names, `SendMessage` and `GetTask`.

The idempotency key and its deduplication are our code. MCP defines nothing here, so a
server that wants retries to be safe has to build it, and it has to put the key somewhere
every replica can see.

## Run it

```
./00-setup.sh      # cluster, namespace, image
./10-break.sh      # local handle, A2A not found, replay without a key
./20-observe.sh    # pods, affinity, modes, endpoints
./30-fix.sh        # stateless MCP, shared Task store, replay with a key, both clients
./40-verify.sh     # asserts both states, exits non-zero on failure
./99-teardown.sh   # deletes the communication namespace
```

## What to look for

Open a cart on one replica and add to it on the other and you get
`-32602 unknown handle ... on replica mcp-...`, naming the replica that never saw it. Ask
for a Task from the replica that did not create it and A2A answers `-32001`, Task not
found. Send the same `charge` twice and the side effect log has two lines.

After the fix the same three sequences return a result, a Task with a `served_by` field
pointing at the second replica, and a single line in the log.

The client makes its own point. Twenty calls over one persistent connection all name the
same replica. Twenty calls with a connection per request name both.

## Sources

- [MCP 2026-07-28 changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog),
  for the removal of sessions, the removal of the handshake, and the line that says a broken
  stream must be reissued as a new request.
- [SEP-2567](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2567), the
  server-minted handles this lab models.
- [Life of a Task](https://a2a-protocol.org/latest/topics/life-of-a-task/) and the A2A
  [specification](https://a2a-protocol.org/latest/specification/), for Task state and for
  the Idempotency section that leaves deduplication to the server.
