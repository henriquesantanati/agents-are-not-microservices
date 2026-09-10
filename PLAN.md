# Reproduction repo plan

Companion repository for "Agents Are Not Microservices: Operating Autonomous AI on
Kubernetes", Cloud Native AI + Inference Day, KubeCon NA 2026, Mon 9 Nov 2026.

Decided on 2026-09-09. Every item below is a decision, not an option, unless it sits
under Open risks. This file is the source of truth for the repository. Changes to it
are pull requests like anything else.

## Ownership and identity

Repository is `github.com/henriquesantanati/agents-are-not-microservices`. No organisation, since an
org for a two-speaker talk repo is administration for nothing.

Private while it is built, public before the event on a date to be chosen. The
slug stays readable from the stage, so the QR is regenerated once after the repo
exists and before the slide is touched again.

Licence is Apache-2.0, matching every CNCF project, which also gives readers the
explicit patent grant that MIT lacks.

## What the reader needs

CPU only. No GPU anywhere in the supported path.

Nothing in the probes pillar needs a model. What breaks is that an agent pod holding
a long task stays Ready because both probes ask `/health`, which only knows the
process is up, so the Service keeps routing new tasks to it. That reproduces with a
stub agent that sleeps for a configurable time per task and serves `/health` and
`/ready` on the same port. The stub is deliberate. kagent has no capacity-aware
readiness, so the lab would have nothing to fix, and the slide's `/ready` handler is
the reader's own code by design.

Real vLLM appears in one lab only, scaling, because the inference tier's signal
(`vllm:kv_cache_usage_perc`) cannot be stubbed honestly. The CPU backend runs it
with timings scaled down and the README stating plainly that the timings are scaled
while the ordering of the signals is what the lab shows.

`kind` is the target platform. No cloud account, no credentials, no cost. Karpenter
cannot run on `kind`, so the Karpenter manifests ship as reference with a note that
they need a cloud that runs it. The PDB behaviour, which is the substance of the
disruption pillar, reproduces on `kind`, and it takes both halves of the slide's
contrast to show it. A `kubectl drain` goes through the eviction API and the PDB
blocks it, then force-deleting the node bypasses the API entirely and takes the pod
mid-task. One step without the other demonstrates half a diagram.

Budget is 8GB of Docker memory with a single lab running, roughly 6GB per lab
including kagent and backing services. The per-lab figure is provisional until it is
measured on a CI runner rather than a laptop, and the CI section says what happens if
it does not hold. Never require two labs up at once. Each lab
creates its own cluster or namespace and tears it down. A lab that cannot fit gets
simplified rather than documented as needing more RAM.

The ceiling is machine checked. Every lab declares resource requests and limits,
and a CI step sums them and fails the build if a lab exceeds budget. Authoring on a
larger machine is fine and expected, and the check is what stops the labs quietly
growing to fit it.

`00-setup.sh` checks prerequisites and refuses, never installs. It verifies
`docker`, `kind`, `kubectl` and `helm`, checks the Docker memory allocation, and on
failure prints the number it found, the setting to change, and the one command to
install whatever is missing.

## Pinning

Everything the repo controls is pinned so a reader in November gets what CI tested.

The vLLM image is `vllm/vllm-openai-cpu`, which is the official vLLM organisation
image, multi-arch for `linux/amd64` and `linux/arm64`, pinned by digest. There is no
need to build an image and no third-party image in the supply chain.

The model is `Qwen/Qwen2.5-0.5B-Instruct` pinned to an exact revision, because a
model that changes underneath you turns a reproducible lab into a flaky one.
Weights download once into a host directory that `kind` mounts, so re-running does
not re-fetch. `00-setup.sh` pre-pulls and prints the size. CI caches the directory.

The `kind` node image, the kagent chart version and the KEDA chart version are
pinned too.

## The agent

kagent, CNCF Sandbox. It is the subject of the Lin Sun post that opens the talk, and
research confirmed it is the only one of the four candidate platforms that emits
`gen_ai.*` telemetry out of the box, which the observability lab needs. Using it
means the repo reinforces the talk's own sources.

The chart version is pinned, so there is no reproducibility drift. What can drift is
the claim. If kagent changes its telemetry after 2026-09-09, when it was verified to emit
`gen_ai.*` out of the box, the README ends up asserting something upstream no longer
does. Re-check that single claim in the week before the repo goes public. That is the
only drift being accepted.

## Labs

Four labs. Communication gets a diagram plus one small runnable proof rather than a
full lab, because stateless MCP behind a plain Deployment is not worth reproducing,
while replaying the same tool call twice with and without an idempotency key shows
the actual failure the slide claims and takes minutes to write.

Build order is probes, observability, scaling, disruption. Probes first because it
is the smallest and the most certain, a stub and two manifests, and it is the reader's
entry point. Observability second because it is the
newest material and the thing people most want to copy. Disruption last because
Karpenter behaviour is the fiddliest to make deterministic.

Labs produce the slide artifacts. The scaling lab generates the agent CPU flat
against climbing queue depth capture, and a second one for the line slide 10 now
carries, that scaling the agents alone lengthens the inference queue. The break step
raises agent replicas with vLLM held at one and records `vllm:num_requests_waiting`
climbing, the fix step lets the inference tier scale on `vllm:kv_cache_usage_perc`
and records it falling. The observability lab generates the connected trace across
the MCP boundary. Each lab writes to
`labs/<pillar>/artifacts/` and the slide uses that file, so the screenshot is
provably from a run anyone can repeat.

Every lab follows the same shape, so someone who ran one can run any of them
without reading again.

```
labs/probes/
  README.md          the story, the commands, what to look for
  00-setup.sh        cluster, namespace, dependencies
  10-break.sh        apply the broken manifest, wait, print the symptom
  20-observe.sh      the kubectl commands that show why
  30-fix.sh          apply the fixed manifest, wait, print ready
  40-verify.sh       assert the fix, exit non-zero if not
  99-teardown.sh
  manifests/broken.yaml
  manifests/fixed.yaml
  artifacts/
```

Numbered prefixes so `ls` shows the order. Scripts idempotent so any step can be
re-run. Every script exits non-zero on failure so CI calls the same files a human
does. No CI-only path, because a CI-only path is how labs rot unnoticed.

## CI

GitHub Actions on `kind`, so no cloud credentials and none of the secrets problem
that came with the Terraform idea.

Both states are asserted. For probes the broken manifest must produce the actual
symptom, which is the absence of one: with a task in flight the Pod's Ready condition
stays True, RESTARTS stays 0, and the Pod IP remains in the Service's EndpointSlice,
so a second request lands on the busy pod. The fixed manifest must show Ready flip to
False while the task runs, the Pod IP leave the EndpointSlice, RESTARTS still 0, and
Ready return to True when the task ends. A workflow that only proves the fix says
nothing about whether the failure still reproduces, and a lab whose broken state
quietly starts working is worse than no lab, because someone in the room can disprove
it in ten minutes.

Assertions read conditions and EndpointSlice membership, never wall clock seconds,
because probe periods make any timing assertion a race.

The runner is smaller than the authoring machine, so the labs are sized against the
runner. Standard GitHub-hosted Linux runners give a private repository 2 vCPU and 8GB
in total, covering the operating system, the runner agent, the `kind` control plane
and the lab itself, where the 8GB measured locally was a Docker allocation sitting on
a host with its own memory. Going public raises the runner to 4 vCPU and 16GB, which
means the constraint loosens exactly when the repository stops being private, the
wrong way round for a build phase. Every lab has to fit the private-repo runner and
the budget check reads that ceiling rather than the laptop's.

Roughly 6GB per lab leaves almost nothing for the runner's own overhead. The probes
lab is now a stub agent on `kind` and proves nothing about that ceiling, so the first
CI integration no longer surfaces it. The first lab that does is observability, with
kagent, the collector and a trace backend, and the heaviest is scaling, with vLLM.
So the ceiling gets measured on purpose rather than discovered: `scripts/smoke-kvcache.sh`
gets a CI job on the private-repo runner as soon as the probes lab lands, before
observability is authored. If it cannot fit there, the per-lab ceiling drops before any
lab is authored against the old number. Authoring three labs against a figure a smoke
test could have disproved in an hour is the expensive version of this mistake.

Per pull request for the lab that changed, nightly for all four.

## Leak and slop gates

Local, before anything is pushed. Scripts live in `hooks/` in the repository and
`git config core.hooksPath hooks` is set once per clone. Git deliberately refuses to
let a clone configure its own hooks, since that would be remote code execution on
`git clone`, so the manual step is unavoidable. It goes in `CONTRIBUTING.md`, not
the README.

`pre-commit` scans staged content only, so it stays fast. `pre-push` scans the full
tree and the commits being pushed, which is the real gate because it catches
anything committed with `--no-verify`. One script behind both.

The gates catch secrets via `gitleaks`, then em dashes, smart quotes, unicode
arrows, account IDs, ARNs containing digits and internal hostnames.

Server side, enable GitHub push protection when the repo goes public. GitHub's own
documentation describes it as stopping you pushing secrets to public repositories, and
it blocks the push before the secret lands rather than alerting afterwards. Secret scanning in CI is standard practice and OpenSSF Scorecard
checks for it. Linting prose in CI is not standard, so the em dash checks stay local.

The hook has to exist from the first commit, because making a repository public
exposes the entire history at once and nothing can be un-leaked afterwards.

A regex cannot see the rest. Check by hand for wording, unpublished roadmap, and screenshots containing a
cluster name or an account number.

## Collaboration

One pull request per reviewable unit, roughly 100 to 300 changed lines, never
mixing prose and code in the same PR. Scaffold, then README links, then one lab at a
time, splitting a lab into setup and break followed by fix and verify if it runs
long. Short-lived branches, squash merge, draft PRs opened early so direction is
visible before the work is finished.

Lanay cannot run any of it, so her review is reading only. Every lab PR body carries
the evidence, a link to the CI run plus a pasted transcript of the break and the
fix. Descriptions stay short. No walls of text.

## README

Links inline, not in a separate file. Someone scanning the QR during Q&A should not
have to click twice to reach a source. Links sit under pillar headings, never slide
numbers, because pillars are stable and slide numbers are not.

Shape is link first, one sentence after, no bullets and no bold openers. The
sentence says what the link establishes, not what it is.

```
### Probes

[Kubernetes probes](url). Readiness runs for the container's whole life, a failed readiness probe removes the Pod from the Service without restarting it, and the docs caution that load-sensitive liveness probes cause restarts under load.
```

After the links, a short table of the four labs pointing at
`labs/<pillar>/README.md`, and a plain statement of which labs are ready.

## Links

Fifteen, down from 27. Each one backs a specific claim made on a slide.

Thesis and opener. Lin Sun's CNCF post on whether a Pod is the right deployment unit.
The Kubernetes blog on agent-sandbox, which is Kubernetes saying its own primitives do
not align. AWS AgentCore Runtime instances and Microsoft kars, the other two of the
three platforms.

Probes. The Kubernetes liveness, readiness and startup probes page, for three claims
the slides make: readiness is evaluated for the whole container lifetime, a failed
readiness probe removes the Pod from Service endpoints without a restart, and the
documented caution that liveness probes which react to load restart containers under
load. It is the only source the pillar needs and it is vendor neutral.

Scaling. The KEDA project page for CNCF graduation, which slide 11 states outright and
is the one scaling claim a reader is most likely to check. The two-tier split itself is
argued from the pillar's own diagram and capture rather than a citation, and the KEDA
scaler reference and the vLLM metrics document stay in the scaling lab README because
their job is to stop a reader copying a deprecated field name.

Disruption. The Kubernetes PodDisruptionBudget docs, because voluntary evictions only
is the central claim of the pillar and the most widely misread thing in the talk.
Karpenter disruption concepts, which is where the `do-not-disrupt` duration form and
the `terminationGracePeriod` warning actually live.

Communication. MCP SEP-2575 for stateless. The A2A task lifecycle for stateful Tasks.

Observability. MCP SEP-414 for trace context crossing the boundary. The semantic
conventions CHANGELOG for the `gen_ai.system` to `gen_ai.provider.name` rename. The
OTel GenAI events document for `gen_ai.evaluation.result`, which is normative. AWS
AgentCore Evaluations, the only production example found of an evaluator running
outside the request path. The CNCF StackGen post for green trace, wrong answer.

Further reading, real but not load bearing. The CNCF post on CPU and GPU as a
heterogeneous infrastructure problem. llm-d architecture. Dapr Agents core concepts.
Shopify Engineering on Sidekick's continual learning loop.

Cut, with reasons. The EKS financial services counter-example, the Well-Architected
Agentic AI Lens, both DynamoDB checkpoint links and the Karpenter design doc are each
covered by a better link. OTel graduation and llm-d prefill and
decode disaggregation both lost the slide lines they supported, and so did llm-d
readiness probes and vLLM issue #36960 when the probes pillar moved off the model
server and onto the agent pod. Adobe predictive
autoscaling was validated in shadow mode only and the talk never claims predictive
scaling. The Dapr GA announcement duplicates the core concepts page. The Kubernetes
pod lifecycle page is basic documentation the audience already knows.

Two links belong in lab READMEs rather than the main list, because their job is to
stop a reader copying something wrong. The KEDA RabbitMQ scaler reference, since
`queueLength` is deprecated in favour of `mode` and `value`. The vLLM metrics
document, since `gpu_cache_usage_perc` became `kv_cache_usage_perc`.

## Scaling lab, gate cleared 2026-09-09

`scripts/smoke-kvcache.sh` ran twice against Colima on Apple Silicon with four CPUs
and 8GB, the second time with the finished version of the script so that every check it
performs has a reported result from the same run. It states its decision criteria before
it applies load and exits the moment it has an answer, so it cannot be read into a
preferred shape.

The conclusion replicated and the numbers moved, which is the more useful outcome.
Queueing led both times, at 0.082 cache in the first run and 0.097 in the second, with
peak cache at 0.838 and 0.809 and peak waiting at 60 in both. Treat the figures below as
one run's values rather than constants, and quote the ordering rather than the decimals.

The second run's full output is saved at `evidence/smoke-kvcache-run2-20260909.log` so
the numbers are checkable by someone other than the person who ran them. The first run
has no saved log, so where the two disagree the second run's figure is the citable one
and the first run's is indicative only.

`vllm:kv_cache_usage_perc` is emitted by the CPU backend and moves under load,
reaching 0.838. On the old name, the script checks explicitly and printed
`gpu_cache_usage_perc ABSENT, only the kv_cache_usage_perc name exists here`. The
current vLLM metrics document does not list it either. Measured and documented agree,
so the metrics link in the lab README earns its place.

The script exits 0 only when both signals were observed, 2 on a partial result and 3
when nothing was proven. An inconclusive re-run before the talk cannot read as a pass.

`VLLM_CPU_KVCACHE_SPACE` is honoured and observable. Setting it to 1 produced
`kv_cache_memory_bytes=1073741824`, `kv_cache_size_tokens=43648` and
`kv_cache_max_concurrency=21.3125` inside `vllm:cache_config_info`. The lab sizes its
load from those published values rather than from a number picked by hand.

This changes nothing about the two-tier design, which was decided earlier. The
script touches neither RabbitMQ nor KEDA, so the agent tier half stays asserted rather
than measured. What the run adds is that the inference tier's signal is observable
without a GPU, so CI will need to assert it and now has a way to.

`vllm:num_requests_waiting_by_reason` is documented and carries `capacity` for
waiting on scheduling capacity and `deferred` for transient constraints, and the two
sum to `vllm:num_requests_waiting`. It belongs in `20-observe.sh`, because it answers
why a request is waiting rather than only that it is.

### The caveat that goes in the lab README

On the CPU backend, requests queue long before the cache fills. In the logged run 60
requests were waiting while `kv_cache_usage_perc` read 0.097, and the earlier run showed
0.082 at the same point. Every waiting request was labelled `reason="capacity"` and none
`deferred`. The decimals move between runs and the ordering does not, so the ordering is
the claim. Compute binds first when prefill is
slow. A GPU inverts that, which is why an autoscaling threshold tuned on a laptop
does not transfer to a cluster. The lab shows the wiring and the reader tunes the
number against their own binding constraint. This changes nothing on the slides.

### Container flags the CPU install doc actually prescribes

`--shm-size` is required, not optional. Docker's 64MB default kills the engine with
`Insufficient space in /dev/shm: 160 MiB required, 64 MiB free`. In Kubernetes that
is an `emptyDir` with `medium: Memory` mounted at `/dev/shm`, and the lab manifests
have to carry it or the fixed state never comes up.

`--cap-add SYS_NICE` with `--security-opt seccomp=unconfined` is what the CPU FAQ
prescribes for the `get_mempolicy: Operation not permitted` warning. Performance
only, so the lab can note it without depending on it.

`--dtype float32`. bfloat16 sent this build into a torch.compile pass that had not
finished after fifteen minutes on aarch64. The FAQ recommends bfloat16 only when
float16 causes trouble, and float32 is a listed supported dtype, so the conditional
advice does not apply here. Mount a volume at `/root/.cache/vllm` so compilation is
paid once rather than every run.

Readiness took 77 seconds warm, from the logged run, once the model and compile caches
were populated, and roughly 225 seconds cold on the first run including a 54 second
weight download. The cold figure has no saved log, so it sets an expectation for the
setup script rather than carrying weight as evidence. Both timings stay in the scaling lab README
and off the slide, because they are scaled laptop measurements and no slide quotes a
start time.

Neither timing says anything about probes. This script runs `docker run` and polls
`/v1/models` with curl, so there is no Pod and no probe anywhere in it, and the probes
lab no longer involves vLLM at all. What the 77 seconds does is set the scaling lab's
setup expectation: its `00-setup.sh` has to wait for a first `/v1/models` answer that
takes over a minute warm, and CI has to budget for that before load is applied.

Three cores rather than four, because vLLM's automatic thread binding reserves one CPU
for the serving framework. The engine printed `reserve_cpu_num=1`, `core ids=[0, 1, 2]`
and `reserved_cpus=[3]` on its own startup path, and the script now surfaces those lines
on success so the number is evidenced rather than asserted.

### Digest

Pin `vllm/vllm-openai-cpu@sha256:c2414ae3dfe4fbcd1fb5d1430f032618aca92dcfb0d8e5179165d512a0336f91`,
the v0.29.0 manifest list resolved on 2026-09-09 and resolved again to the same value on
the second run. The tag was hours old when it was first pulled, so re-resolve it once
before the repository goes public. A digest an audience member can check in a minute is
worth checking twice.

## Scope triggers

Two months, one person who can run anything, four labs, CI that has to prove a break
as well as a fix, and a deck to finish. The scaling lab consumed an afternoon to
answer one question about which metric fires first, before a single lab script,
manifest pair or workflow existed for it. That rate does not fit four labs, so the cut
gets named now rather than discovered in the last fortnight.

If disruption has not started once probes, observability and scaling are done, it drops
to a diagram plus a manual transcript with no CI, which is the treatment Communication
already has. The trigger is the state of the other three labs, not a date, because a
date invented now would only be a guess wearing a deadline's clothes.

Protected means the lab ships and a reader can run it. It does not mean its CI job
ships with it, and separating those two is what makes a second lever possible.

So here is the second lever. If disruption has already dropped and the schedule is still
short, one protected lab ships complete, scripts and both manifests, with a dated break
and fix transcript in its README and its CI job landing afterwards. Scaling goes first if
that is needed, then observability. Probes never, because it is the first lab authored and
the reader's entry point, so it has the most runway and the least excuse.

Two things do not get traded. The broken state still ships, because a lab that only
demonstrates the fix is the failure mode the CI section refuses. And any lab whose CI is
still pending gets re-run by hand in the week before the talk, with the transcript
refreshed, because the gap this lever opens is exactly the weeks in which nothing
automated is checking that the break still reproduces.

Scaling is protected, and not because its gate is cleared. The gate answered one
metric question. Its scripts, manifests, CI job and README do not exist yet, so its
authoring effort carries exactly the risk that argument above describes. It is protected
because slide 9 depends on the capture it produces, so cutting it leaves a hole on a
slide rather than an absent lab in a repository. That is the whole basis.

Probes and observability are protected on the same footing. They carry the newest
material and the other artifact the slides use. Disruption is the one lab whose absence
costs the talk nothing, which is why it holds the first trigger.

## Open risks

The KV cache metric question is closed. See the scaling lab section below.

Whether the disruption lab reproduces deterministically on `kind` is untested. It is
the last lab in the build order, so the risk sits furthest from the deadline, but
nothing has been run against it.

The QR and the repository URL on slide 23 are wrong until the repo exists.

## Facts verified on 2026-09-09

`karpenter.sh/do-not-disrupt` accepts either a boolean for permanent protection or a
Go duration string for time-based protection measured from when the pod starts
running. The docs use `"30m"` as their own example, so `"2h"` is valid but arbitrary,
and the honest framing on stage is that it should match the longest task. Karpenter
advises against combining the annotation with `expireAfter` unless
`terminationGracePeriod` is also configured, which the slide already does. The
annotation does not protect against Expiration, Interruption, Node Repair or manual
node deletion, so a spot reclaim still takes the pod, which supports the pillar's
closing line.

The pod's `terminationGracePeriodSeconds` and the NodePool's `terminationGracePeriod`
are different fields. The slide shows the first and the prose names the second, so
the distinction needs stating on stage.

vLLM supports CPU inference on x86 with `avx512f` recommended, ARM AArch64, Apple
Silicon and s390x, and sizes its KV cache in RAM through `VLLM_CPU_KVCACHE_SPACE`.
