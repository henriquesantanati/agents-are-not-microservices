# Disruption

Assumption: pods are cattle.

## What breaks

A PodDisruptionBudget gates one thing: the eviction API. `kubectl drain`, the cluster
autoscaler and Karpenter all go through that API, so the budget can refuse them. A plain
delete does not ask. Neither does a node crash, an OOM kill or a spot reclaim. The budget
notices those afterwards, which is no help to the agent that was halfway through a task.

A grace period cannot cover a chain longer than itself either. Set it to two minutes and a
node drain waits two minutes; the chain still dies at the end of them.

Checkpointing is what actually saves the work. After that, losing a pod costs whatever
happened since the last checkpoint.

## The stub

`agent/agent.py` runs a 90 step chain, two seconds a step, and serves HTTP on the side.
The first line it logs says where the chain starts, and that line is what the lab asserts
on.

With `CHECKPOINT=none` the chain lives in memory. On SIGTERM the agent announces it will
try to finish inside the grace period, which is exactly the hope a long grace period rests
on.

With `CHECKPOINT=all` progress goes to a PersistentVolumeClaim by three routes:

- the preStop hook runs `checkpoint.sh`, which calls `POST /checkpoint`, because a shell
  script cannot reach into the process's memory;
- a SIGTERM handler writes the same checkpoint, for the case where nobody configured a
  hook;
- and the agent checkpoints after every step.

It is a StatefulSet, so the replacement keeps the pod name and the claim, and only starts
once the old pod is gone.

## Run it

```
./00-setup.sh      # cluster, namespace, image
./10-break.sh      # eviction refused, delete accepted, chain lost at grace 30 and 120
./20-observe.sh    # PDB, grace period, hook, last state, logs
./30-fix.sh        # the same delete, then an OOM kill
./40-verify.sh     # asserts both states, exits non-zero on failure
./99-teardown.sh   # deletes the disruption namespace
```

## What to look for

The eviction API answers 429, `Cannot evict pod as it would violate the pod's disruption
budget`. Then `kubectl delete pod` goes through without a word. At grace 30 the agent
spends thirty seconds saying it is finishing the chain and gets killed; the replacement
logs `start chain at step 0`. At grace 120 the pod sits in Terminating for two full
minutes and the replacement logs the same thing.

The broken agent uses the whole grace period because its handler keeps working. Take the
handler away and it still would: Python runs as PID 1, and PID 1 is never sent a signal it
has no handler for, so nothing happens until the SIGKILL. The observability lab shows that
case.

In the fixed state the old pod logs `preStop hook called at step 6` and then
`SIGTERM received, checkpointed at step 6, exiting`, and the replacement is up about four
seconds later with `resume chain at step 6 of 90 from checkpoint`.

Then the OOM kill, which is the interesting one. `lastState.terminated` reads
`OOMKilled` with exit code 137, the dead container's log has nothing but periodic
checkpoints in it, and the restarted container resumes from the last of them. No preStop,
no SIGTERM: the kernel does not ask.

So preStop and SIGTERM are two spellings of the same voluntary path. SIGKILL skips both,
and only the periodic checkpoint bounds what you lose when it does.

That same kill also drops the trace that would have explained it. The observability lab is
where the OpenTelemetry SDK lives, and it demonstrates both the loss and the fix.

## Killing a pod without a graceful stop

The lab sets a memory limit and asks the stub to allocate past it. Do not reach for
`kubectl exec -- kill -9 1` instead: the command reports success and nothing happens, since
[pid_namespaces(7)](https://man7.org/linux/man-pages/man7/pid_namespaces.7.html) only
delivers SIGKILL to a namespace init from an ancestor namespace. `30-fix.sh` runs it once,
after the OOM kill, and asserts that the chain keeps going and the restart count stays put.

## Karpenter

Karpenter provisions cloud nodes and cannot run on `kind`, so its manifests sit in
`reference/` and no script applies them.

## Sources

- [PodDisruptionBudget](https://kubernetes.io/docs/tasks/run-application/configure-pdb/),
  for the sentence that a budget limits voluntary disruptions and nothing else.
- [Karpenter disruption](https://karpenter.sh/docs/concepts/disruption/), for
  `do-not-disrupt` and the NodePool `terminationGracePeriod` on slide 14.
