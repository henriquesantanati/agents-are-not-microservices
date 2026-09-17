# Probes

Assumption: readiness means the process is up.

## What breaks

A busy pod answers its probe instantly. That is the whole problem. The probe asks the
process whether it is alive, the process says yes, and nothing in that exchange knows the
pod has been chewing on the same task for the last four minutes. Point both probes at
`/health` and ready ends up meaning alive, so the Service keeps handing work to a pod that
cannot take it.

Liveness and readiness answer different questions. Is the process alive, and can it take
another task. A failing readiness probe pulls the pod out of the Service and leaves it
running; a failing liveness probe kills it. Kubernetes has no idea what capacity means for
your agent, so `/ready` is yours to write. Here it returns 503 while `inflight >= max_tasks`
and 200 otherwise.

Longer timeouts, the usual first reaction, answer neither question.

## The stub

`agent/agent.py` runs in two modes, and the difference between them is the lab.

In `async` mode each request gets its own thread and the task runs in the background, so
both endpoints keep answering while the agent works. In `blocking` mode everything shares
one thread and the task runs inside the request, so nothing answers until it finishes.
Either way the agent holds one task at a time.

## Run it

```
./00-setup.sh      # creates the anm cluster if it is missing, builds and loads the image
./10-break.sh      # both probes on /health, then a 90 second task
./20-observe.sh    # run this while a task is in flight
./30-fix.sh        # readiness on /ready, then a 90 second task
./40-verify.sh     # asserts both states, exits non-zero on failure
./99-teardown.sh   # deletes the probes namespace and leaves the cluster alone
```

## What to look for

With both probes on `/health`, the async pod sits at `1/1 Running 0` with a task in
flight and its endpoint stays ready. Meanwhile the blocking pod goes `0/1` after about
forty seconds and restarts after about a minute, because three liveness probes in a row
timed out. The task it was running is gone.

After the fix, the async pod drops to `0/1 Running 0` about twenty five seconds into the
task, its endpoint turns not ready, and it comes back on its own when the task ends. Zero
restarts throughout.

The blocking pod still restarts in the fixed state, and that is not a bug in the lab.
Moving readiness to `/ready` only helps a server that can still answer while it works. If
`/health` is stuck behind the task, the kubelet kills the pod no matter what the readiness
probe says, and a longer timeout only postpones it until the task outlives that too.

`artifacts/` holds the exact output behind slides 7 and 8.

## Source

- [Liveness, readiness and startup probes](https://kubernetes.io/docs/concepts/workloads/pods/probes/)
  spells out the difference the fix depends on: readiness failure removes the pod from
  Service endpoints, liveness failure restarts the container.
