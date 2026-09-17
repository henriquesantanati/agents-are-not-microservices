# Scaling

Assumption: load means CPU.

## What breaks

One task turns into many downstream calls, and the agent decides how many while it runs.
The tier that saturates is therefore never the tier the autoscaler is watching.

An agent waiting on a dependency burns almost no CPU, so a CPU autoscaler on the agent
never fires. Scaling the agents on any other signal does not help either: the load on the
dependency is the incoming rate times the fan-out, so more agents just spread the same
calls across more callers. What you want to scale is whatever queue is growing, on that
queue.

## The stub

`agent/agent.py` runs as three Deployments from one image. The numbers are fixed so the
arithmetic is checkable.

| Mode | What it does | Values |
|---|---|---|
| `dependency` | serves 4 calls at once, 200 ms each, so one replica handles 20 calls per second | `CAPACITY=4`, `CALL_SECONDS=0.2` |
| `agent` | fans each task out into 20 concurrent calls | `FANOUT=20` |
| `load` | sends 2 tasks per second, which is 40 calls per second downstream | `RATE=2` |

Both servers publish JSON on `/metrics`: `agent_downstream_calls_inflight` from the agent,
`dependency_queue_depth` from the dependency. Nothing scrapes them. The scripts read them,
KEDA reads one of them, and the assertions read the same numbers the scripts print.

## Run it

```
./00-setup.sh      # cluster, metrics-server, KEDA, image
./10-break.sh      # HPA on agent CPU, then three agents by hand
./20-observe.sh    # deployments, autoscalers, CPU, per replica queue
./30-fix.sh        # agent back to one, KEDA ScaledObject on the dependency
./40-verify.sh     # asserts both states, exits non-zero on failure
./99-teardown.sh   # deletes the scaling namespace, keeps KEDA and the cluster
```

`00-setup.sh` installs metrics-server with `--kubelet-insecure-tls`, since `kind` does not
ship it and an HPA reporting `<unknown>` would make the broken state a lie. It also
installs KEDA from its Helm chart at a pinned version, so you need `helm`.

## What to look for

The HPA on the agent reads real CPU, somewhere between 25 and 55 percent of the 100m
request depending on the machine, decides one replica is enough, and never fires. The
dependency queue climbs past 600 in the first half minute and keeps going.

Then scale the agent to three by hand. All three replicas take tasks, and the queue grows
faster than before rather than draining, because 2 tasks per second times 20 calls is 40
calls per second whether one agent or three is making them.

The fix puts the agent back to one replica and a KEDA ScaledObject on the dependency,
reading `dependency_queue_depth` from the dependency's own `/metrics` through its Service,
`targetValue` 10, `maxReplicaCount` 3. The dependency scales out and every replica's queue
falls to 10 or below within about a minute and a half.

Three replicas, not two. Two would serve exactly the 40 calls per second being offered,
and a queue at full utilisation never drains.

## Caveats

KEDA reads the metric through the Service, so each poll sees one replica's queue rather
than the sum. That is tolerable here because the Service spreads calls evenly, and the
assertions read every replica directly so they do not depend on which pod KEDA happened to
hit. The scaler does have `aggregateFromKubeServiceEndpoints` with `aggregationType: sum`
for the case where it matters.

Leave the fixed state running for six minutes or so and the dependency scales back down and
then straight back up. An empty queue reads as no demand, and the HPA's scale-down
stabilisation window is what delays the flap, not prevent it.

A per-agent cap on downstream calls is the backpressure that protects a dependency you
cannot scale. It moves the queue into the agent instead of removing it, and it is not what
this lab shows.

## Sources

- [KEDA Metrics API scaler](https://keda.sh/docs/latest/scalers/metrics-api/). Read it
  before copying the trigger. The field names are not the ones the Prometheus scaler uses,
  and `valueLocation` takes a path into the JSON body.
- [KEDA](https://keda.sh/) is CNCF graduated, which is the reason the talk reaches for it
  rather than a custom controller.
