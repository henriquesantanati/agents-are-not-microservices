# Disruption

An agent that works through a chain of steps for minutes is going to lose a pod partway
through. Kubernetes offers three things that look like protection, a PodDisruptionBudget,
a long grace period and a preStop hook, and none of them keeps the work. Only a checkpoint
does, and only the periodic one covers every way a pod can die.

![What breaks: the PDB never protects the work](https://github.com/henriquesantanati/agents-are-not-microservices/releases/download/kubecon-na-2026/disruption-what-breaks.gif)

![The pattern: state outlives the pod](https://github.com/henriquesantanati/agents-are-not-microservices/releases/download/kubecon-na-2026/disruption-the-pattern.gif)

## The problem

A PodDisruptionBudget gates one thing, the eviction API. `kubectl drain`, the cluster
autoscaler and Karpenter all go through that API, so the budget can refuse them. A plain
delete does not ask. Neither does a node crash, an OOM kill or a spot reclaim. The budget
notices those afterwards, which is no help to the agent that was halfway through a task.

A grace period cannot cover a chain longer than itself. Set it to two minutes and a node
drain waits two minutes. The chain still dies at the end of them.

Checkpointing is what saves the work. After that, losing a pod costs whatever happened
since the last checkpoint. preStop and a SIGTERM handler write one on the voluntary path.
On the involuntary path there is no preStop and no SIGTERM, so only a checkpoint the agent
wrote on its own, after every step, bounds the loss.

## The stub

`agent/agent.py` runs a 90 step chain, two seconds a step, and serves HTTP on the side.
The first line it logs says where the chain starts, and that line is what the lab asserts
on.

With `CHECKPOINT=none` the chain lives in memory. On SIGTERM the agent announces it will
try to finish inside the grace period, which is exactly the hope a long grace period rests
on.

With `CHECKPOINT=all` progress goes to a PersistentVolumeClaim by three routes. The
preStop hook runs `checkpoint.sh`, which calls `POST /checkpoint`, because a shell script
cannot reach into the process's memory. A SIGTERM handler writes the same checkpoint, for
the case where nobody configured a hook. And the agent checkpoints after every step.

It is a StatefulSet, so the replacement keeps the pod name and the claim, and only starts
once the old pod is gone.

## Run it

The numbered scripts expect the cluster, namespace and image that `00-setup.sh` creates,
so run it first. `run.sh` runs it for you.

```
./00-setup.sh      # creates the anm cluster if it is missing, builds and loads the image
./10-break.sh      # eviction refused, delete accepted, chain lost at grace 30 and 120
./20-observe.sh    # PDB, grace period, hook, last state, logs, events
./30-fix.sh        # the same delete, then an OOM kill, then kill -9 from inside
./40-verify.sh     # checks the fixed state as deployed, exits non-zero on failure
./99-teardown.sh   # deletes the disruption namespace, keeps the cluster
./run.sh           # setup, then 10, 20, 30 and 40 in one go, stops at the first failure
```

`10-break.sh` takes about three minutes, most of it waiting out the 120 second grace
period. The wait shows what happens when the grace period expires.

## What to look for

Every kill prints the old pod's last log lines and the replacement's first ones. The first
line of the replacement says whether the chain started over.

| | Broken, chain in memory | Fixed, checkpoint on a claim |
|---|---|---|
| Eviction API | `429 Too Many Requests`, `Cannot evict pod as it would violate the pod's disruption budget` | Same. The budget is not what changed |
| `kubectl delete pod`, grace 30 | Old pod: `SIGTERM received at step 5, finishing the chain (85 steps left)`. Killed 30 seconds later. Replacement: `start chain at step 0 of 90, checkpointing disabled` | Old pod: `preStop hook called at step 14`, then `SIGTERM received, checkpointed at step 14, exiting`. Replacement, three seconds later: `resume chain at step 14 of 90 from checkpoint` |
| `kubectl delete pod`, grace 120 | Two minutes in Terminating, then the same `start chain at step 0` | Not run. The fixed agent leaves on SIGTERM, so the grace period is never used |
| OOM kill | Not run | `lastState.terminated` shows exit code 137, which is SIGKILL. The dead container's log ends in periodic checkpoints, no preStop, no SIGTERM. The restart resumes from the last of them |
| `kill -9 1` from inside | Not run | `kill exit=0`, and the chain keeps going. Same container, same restart count |

The broken agent uses the whole grace period because its handler keeps working. Take the
handler away and it still would. Python runs as PID 1, and PID 1 is never sent a signal it
has no handler for, so nothing happens until the SIGKILL. The observability lab shows that
case.

On the voluntary path, preStop asks the agent to checkpoint, and the SIGTERM handler
checkpoints as it exits. SIGKILL skips both, so only the periodic checkpoint bounds what
you lose when it does.

That same kill also drops the trace that would have explained it. The observability lab is
where the OpenTelemetry SDK lives, and it demonstrates both the loss and the fix.

Each script prints what it is doing on `==>` lines, what the output shows on `-->` lines,
and one PASS or FAIL per check. `10-break.sh` fails if the problem stops reproducing,
`30-fix.sh` and `40-verify.sh` fail if the fix stops working. `run.sh` runs setup and the
four in order, and is what CI runs.

## Killing a pod without a graceful stop

The lab sets a memory limit and asks the stub to allocate past it. Do not reach for
`kubectl exec -- kill -9 1` instead. The command reports success and nothing happens.
[pid_namespaces(7)](https://man7.org/linux/man-pages/man7/pid_namespaces.7.html) drops any
signal sent to a namespace init from inside the namespace unless init has a handler for it,
and SIGKILL reaches it only from an ancestor namespace, which is where the kubelet lives. `30-fix.sh` runs it once,
after the OOM kill, and asserts that the chain keeps going and the restart count stays put.

## Karpenter

Karpenter provisions cloud nodes and cannot run on `kind`, so its manifests sit in
`reference/` and no script applies them. The fixed manifest carries the
`karpenter.sh/do-not-disrupt` annotation, which on a real cluster delays a node's
disruption for the time it names. The NodePool's `terminationGracePeriod` in `reference/`
is what stops that delay from being forever.

## Sources

[PodDisruptionBudget](https://kubernetes.io/docs/tasks/run-application/configure-pdb/).
A budget limits voluntary disruptions and nothing else.

[Karpenter disruption](https://karpenter.sh/docs/concepts/disruption/). `do-not-disrupt`
and the NodePool `terminationGracePeriod`, and how the two interact.
