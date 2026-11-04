# Communication

An agent calls tools over MCP and other agents over A2A, and both run as Deployments
behind a Service. Two replicas, no session affinity, and every call lands wherever
kube-proxy sends it. Whether that works depends on what the server kept from the last
call, and on what a retry costs.

![What breaks: a retry repeats the action](https://github.com/henriquesantanati/agents-are-not-microservices/releases/download/kubecon-na-2026/communication-what-breaks.gif)

![The pattern: every action has a key](https://github.com/henriquesantanati/agents-are-not-microservices/releases/download/kubecon-na-2026/communication-the-pattern.gif)

## The problem

MCP dropped sessions in the `2026-07-28` revision. A server that keeps no state of its
own needs no affinity, because any replica answers anything. A server that mints a handle and
keeps the matching state in its own memory is a different story. The next call lands on
the other replica and the handle means nothing there.

A2A Tasks are stateful by design. They outlive the request that created them, so the
replica that did not create one cannot serve it unless the Task lives somewhere both can
reach.

Neither protocol makes a retry safe. A2A says Send Message may be idempotent through
`messageId`, which leaves it to the server. MCP says nothing, and the same revision that
removed sessions also removed stream resumability, so a client whose response stream
breaks has to reissue the request. The retry is not an edge case, it is in the spec.

Then there is the client. One connection kept open for the life of the process pins you
to one replica, because kube-proxy balances per connection, and so does any L4 proxy in
front of it. New replicas never see your traffic and a rollout kills your connection
mid-task. An L7 proxy that balances per request, a service mesh sidecar for one, changes
that picture. A connection per call avoids both problems. Without sessions, the only
extra cost is a handshake.

## The stub

`agent/agent.py` runs as four Deployments from one image. `mcp` and `a2a` have two
replicas each, `store` is the shared key-value store and the side effect log, and
`client` is where the client commands run. Every response names the replica that served
it, which is the only way to see any of this from outside.

Requests carry `io.modelcontextprotocol/protocolVersion` in `_meta` and results carry
`resultType`, both required since MCP removed the handshake. A2A calls use the v1.0
names, `SendMessage` and `GetTask`.

The idempotency key and its deduplication are our code. MCP defines nothing here, so a
server that wants retries to be safe has to build it, and has to put the key where every
replica can see it.

## Run it

The numbered scripts expect the cluster, namespace and image that `00-setup.sh` creates,
so run it first. `run.sh` runs it for you.

```
./00-setup.sh      # creates the anm cluster if it is missing, builds and loads the image
./10-break.sh      # local handles, Tasks in memory, a key that is ignored
./20-observe.sh    # replicas, affinity, the settings that differ, a call hitting both
./30-fix.sh        # stateless MCP, Tasks in the store, a key that is honoured
./40-verify.sh     # checks the fixed state as deployed, exits non-zero on failure
./99-teardown.sh   # deletes the communication namespace, keeps the cluster
./run.sh           # setup, then 10, 20, 30 and 40 in one go, stops at the first failure
```

## What to look for

`10-break.sh` and `30-fix.sh` run the same three calls and print the JSON each one
answers, with the replica names in it.

| | Broken | Fixed |
|---|---|---|
| Open a cart, then add to it | `-32602 unknown handle ... on replica mcp-...`, naming the replica that never saw it | A result. The handle carries the cart, so it does not matter who answers |
| `GetTask` on the other replica | `-32001`, Task not found | The Task, with `served_by` naming the replica that did not create it |
| The same charge, sent twice | Two lines in the side effect log | One |

The fixed state adds the client. Twenty calls over one persistent connection all name the
same replica. Twenty calls with a connection per request name both. Both client modes
use the same server config; only the connection pattern changes.

Each script prints what it is doing on `==>` lines, what the output shows on `-->` lines,
and one PASS or FAIL per check. `10-break.sh` fails if the problem stops reproducing,
`30-fix.sh` and `40-verify.sh` fail if the fix stops working. `run.sh` runs setup and the
four in order, and is what CI runs.

## Going further

`50-explore.sh` runs against the fixed state and shows what the fix leaves open. It is not
part of `run.sh`.

- The same `messageId` sent twice creates two Tasks. This stub does not deduplicate A2A.
- A key claimed by a worker that dies before charging makes the retry a duplicate, and
  nothing is charged. Claim and charge are two writes, so this is not exactly-once.
- A charge whose response is lost and is reissued with a new request id, as MCP requires,
  runs twice without a key and once with one.
- A worker that checkpoints, charges and loses its pod: the new pod resumes the step and
  charges again if the key was only in memory, and is told duplicate if the key was saved
  with the checkpoint.
- Restarting the store loses every Task in it. Shared is not durable.

## Sources

[MCP 2026-07-28 changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog).
Sessions are gone, the handshake is gone, and a broken stream has to be reissued as a new
request. [SEP-2567](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2567)
is the server-minted handle this lab models.

[Life of a Task](https://a2a-protocol.org/latest/topics/life-of-a-task/) and the
[A2A specification](https://a2a-protocol.org/latest/specification/). Tasks outlive the
request, and Send Message may be idempotent through `messageId`. The server decides
whether to deduplicate.
