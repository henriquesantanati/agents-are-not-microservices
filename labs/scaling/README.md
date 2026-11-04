# Scaling

An agent takes one task and turns it into many downstream calls, and it decides how many
while it runs. The tier that saturates is therefore the dependency, and the autoscaler is
watching the agent's CPU. This lab shows an HPA that never fires while a queue grows
without limit, and a KEDA ScaledObject on the dependency's own queue that drains it.

![What breaks: the HPA scales on agent CPU](https://github.com/henriquesantanati/agents-are-not-microservices/releases/download/kubecon-na-2026/scaling-what-breaks.gif)

![The pattern: scale each tier on its own signal](https://github.com/henriquesantanati/agents-are-not-microservices/releases/download/kubecon-na-2026/scaling-the-pattern.gif)

## The problem

An agent waiting on a dependency burns almost no CPU, so a CPU autoscaler on the agent
never fires. Scaling the agents on any other signal does not help either. The load on the
dependency is the incoming rate times the fan-out, so more agents just spread the same
calls across more callers. Scale the tier with the growing queue, using that queue as
the signal.

## The stub

`agent/agent.py` runs as three Deployments from one image. The numbers are fixed so the
arithmetic is checkable.

| Mode | What it does | Values |
|---|---|---|
| `dependency` | serves 4 calls at once, 200 ms each, so one replica handles 20 calls per second | `CAPACITY=4`, `CALL_SECONDS=0.2` |
| `agent` | fans each task out into 20 concurrent calls | `FANOUT=20` |
| `load` | sends 2 tasks per second, which is 40 calls per second downstream | `RATE=2` |

Both servers publish JSON on `/metrics`, `agent_downstream_calls_inflight` from the agent
and `dependency_queue_depth` from the dependency. Nothing scrapes them. The scripts read
them, KEDA reads one of them, and the assertions read the same numbers the scripts print.

The servers run on asyncio, one thread each, so a waiting call costs a coroutine. The
first version used a thread per connection and stopped at the container's pid limit,
about 1060 on kind and Finch. Past that the dependency closed every new connection
unanswered, the queue could not grow beyond roughly 1050, and the metrics read failed
with a traceback. If a queue reading ever sits at that number, that is the ceiling and
not the load.

## Run it

The numbered scripts expect the cluster, namespace and image that `00-setup.sh` creates,
so run it first. `run.sh` runs it for you.

```
./00-setup.sh      # cluster, metrics-server, KEDA, image
./10-break.sh      # HPA on agent CPU, then three agents by hand
./20-observe.sh    # deployments, autoscalers, CPU, per replica queue
./30-fix.sh        # agent back to one, KEDA ScaledObject on the dependency
./40-verify.sh     # checks the fixed state as deployed, exits non-zero on failure
./99-teardown.sh   # deletes the scaling namespace, keeps KEDA and the cluster
./run.sh           # setup, then 10, 20, 30 and 40 in one go, stops at the first failure
```

`00-setup.sh` installs metrics-server with `--kubelet-insecure-tls`, since `kind` does not
ship it and an HPA reporting `<unknown>` would make the broken state a lie. It also
installs KEDA from its Helm chart at a pinned version, so you need `helm`. The whole run
takes eight minutes or so, most of it waiting on metrics-server and KEDA.

## What to look for

`10-break.sh` and `30-fix.sh` print the autoscaler, the Deployments and the dependency's
`/metrics`. Watch two numbers, the agent's CPU and `dependency_queue_depth`.

| | Broken, HPA on agent CPU | Fixed, KEDA on the dependency's queue |
|---|---|---|
| The autoscaler | `kubectl get hpa agent` shows CPU somewhere between 20 and 60 percent of the 150m request depending on the machine, target 70, `REPLICAS 1`. It never fires | A ScaledObject on the dependency, `targetValue` 10, `maxReplicaCount` 3, and the HPA KEDA made from it |
| `dependency_queue_depth` | Past 40 in the first half minute and climbing, because 40 calls a second arrive at a replica that serves 20 | 10 or below on every replica within about a minute and a half |
| Replicas | Agent 1, dependency 1. Then the script scales the agent to 3 by hand and the queue keeps growing, because 2 tasks a second times 20 calls is 40 calls a second whoever makes them | Agent 1, dependency 3 |

Three replicas, not two. Two would serve exactly the 40 calls per second being offered,
and a queue at full utilisation never drains.

Each script prints what it is doing on `==>` lines, what the output shows on `-->` lines,
and one PASS or FAIL per check. `10-break.sh` fails if the problem stops reproducing,
`30-fix.sh` and `40-verify.sh` fail if the fix stops working. `run.sh` runs setup and the
four in order, and is what CI runs.

## Caveats

KEDA reads the metric through the Service, so each poll sees one replica's queue rather
than the sum. That is tolerable here because the Service spreads calls evenly, and the
assertions read every replica directly so they do not depend on which pod KEDA happened to
hit. The scaler supports `aggregateFromKubeServiceEndpoints` with `aggregationType: sum`
for the case where it matters.

Leave the fixed state running for six minutes or so and the dependency scales back down and
then straight back up. An empty queue reads as no demand, and the HPA's scale-down
stabilisation window delays the flap without preventing it.

A per-agent cap on downstream calls is the backpressure that protects a dependency you
cannot scale. It moves the queue into the agent instead of removing it, and it is not what
this lab shows.

## Sources

[KEDA Metrics API scaler](https://keda.sh/docs/latest/scalers/metrics-api/). Read it
before copying the trigger. The field names are not the ones the Prometheus scaler uses,
and `valueLocation` takes a path into the JSON body.

[KEDA](https://keda.sh/) is CNCF graduated, which is why this lab reaches for it rather
than a custom controller.
