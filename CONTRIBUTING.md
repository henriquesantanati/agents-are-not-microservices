# Contributing

## Once per clone

```
git config core.hooksPath hooks
```

The hooks need [gitleaks](https://github.com/gitleaks/gitleaks) on your PATH.
`hooks/pre-commit` checks staged content, `hooks/pre-push` checks the whole tree, and both
call `hooks/checks.sh`. It runs gitleaks and then rejects em dashes, smart quotes, unicode
arrows, account IDs, ARNs with digits and internal hostnames. This repository will be
public, and a public repository ships its whole history, so the gate exists from the first
commit.

Commit with a personal identity, never an employer one.

## Pull requests

A lab lands whole, in one pull request of 400 to 700 lines: stub, manifests, scripts and
its README. Everything else is one reviewable unit per pull request, 100 to
300 lines, and prose that is not tied to one lab lands on its own.

The reviewer reads, so a lab pull request has to bring the evidence with it: paste the
output of `10-break.sh` and `30-fix.sh` into the body and link the CI run.

## Labs

Every lab under `labs/<pillar>/` has the same six scripts and its own namespace on the
shared `kind` cluster named `anm`. Scripts are idempotent and exit non-zero on failure.
Assertions read conditions, counts and API responses. Never wall clock seconds: probe
periods turn any timing assertion into a race.

`10-break.sh` asserts the broken state and `30-fix.sh` the fixed one, so a problem that
stops reproducing fails as loudly as a fix that stops working. `40-verify.sh` checks the
fixed state as deployed, without redeploying. `run.sh` runs `00-setup.sh` and then `10`,
`20`, `30` and `40`, and stops at the first failure. CI runs `run.sh`.

Scripts say what they do on `==>` lines and what the output shows on `-->` lines, one
short phrase per block of output. Someone who never saw the talk has to be able to follow.

`10-break.sh` and `30-fix.sh` write their captures to `artifacts/`, which git ignores. They
are local output for your own reading; the transcript in the PR body is what gets reviewed.

Docker, Podman and Finch all work. The scripts pick the first one that answers, Podman,
then Docker, then Finch, and `ANM_RUNTIME` overrides that. kind drives Finch through its
nerdctl provider, which kind still labels experimental; the five labs pass on it.
