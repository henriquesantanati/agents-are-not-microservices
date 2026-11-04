# Probes

Kubernetes decides whether a pod is alive and whether it can take traffic by calling two
HTTP endpoints, the liveness probe and the readiness probe. Many manifests point both at
the same `/health`. For a web service that is fine. For an agent that works on one task
for minutes, `/health` gives the wrong answer about when it can take work and when it
needs a restart.

![What breaks: one /health for both probes](https://github.com/henriquesantanati/agents-are-not-microservices/releases/download/kubecon-na-2026/probes-what-breaks.gif)

![The pattern: one probe per question](https://github.com/henriquesantanati/agents-are-not-microservices/releases/download/kubecon-na-2026/probes-the-pattern.gif)

## The problem

An agent that is busy still answers `/health` with 200. Kubernetes reads that as alive and
ready, keeps the pod in the Service, and keeps sending it work it cannot take.

An agent that cannot answer while it works fails the liveness probe three times in a row
and gets restarted. The task it was running is gone.

The two probes answer different questions. Liveness asks whether the process should be
restarted. Readiness asks whether the pod can take another task. Only you know what "can
take another task" means for your agent, so `/ready` is yours to write. Here it returns
503 while a task is running and 200 otherwise.

## The stub

`agent/agent.py` runs in two modes. In `async` mode the task runs in a background thread
and both endpoints keep answering while it works. In `blocking` mode the task runs inside
the request and nothing answers until it finishes. Each pod is built for one task
(`MAX_TASKS=1`), and `/ready` uses that number. In `async` mode nothing else stops a second
task, so it runs alongside the first. In `blocking` mode the next task waits until the
first one finishes. The lab runs one pod of each.

## Run it

The numbered scripts expect the cluster, namespace and image that `00-setup.sh` creates,
so run it first. `run.sh` runs it for you.

```
./00-setup.sh      # creates the anm cluster if it is missing, builds and loads the image
./10-break.sh      # both probes on /health, then a 90 second task on each pod
./20-observe.sh    # run it while the task is in flight
./30-fix.sh        # readiness on /ready, then a 90 second task on each pod
./40-verify.sh     # checks the fixed state as deployed, exits non-zero on failure
./99-teardown.sh   # deletes the probes namespace, keeps the cluster
./run.sh           # setup, then 10, 20, 30 and 40 in one go, stops at the first failure
```

## What to look for

`10-break.sh` and `30-fix.sh` start a 90 second task on each pod and print
`kubectl get pod`. Watch two columns, READY and RESTARTS.

| | async pod | blocking pod |
|---|---|---|
| Broken, both probes on `/health` | `1/1` the whole time, `0` restarts. Kubernetes thinks it is free. It is not. | `0/1` after 40 seconds, then `1` restart. The task is lost. |
| Fixed, readiness on `/ready` | `0/1` while it works, `1/1` when done, `0` restarts. The Service stops sending it work until it can take it. | Still `1` restart. Readiness cannot help a server that cannot answer. |

The fix is the async column. The blocking pod restarts in both states, and that is why it
is in the lab. A server that blocks while it works has no probe setting that saves it. It
has to answer while it works.

`20-observe.sh` prints the probe config, what `/health` and `/ready` return mid-task, the
Service endpoints and the probe events, with one line under each saying what it shows.

Each script prints what it is doing on `==>` lines, what the output shows on `-->` lines,
and one PASS or FAIL per check. `10-break.sh` fails if the problem stops reproducing,
`30-fix.sh` and `40-verify.sh` fail if the fix stops working. `run.sh` runs setup and the
four in order, and is what CI runs.

## Source

[Liveness, readiness and startup probes](https://kubernetes.io/docs/concepts/workloads/pods/probes/).
Readiness failure removes the pod from the Service. Liveness failure restarts the
container.
