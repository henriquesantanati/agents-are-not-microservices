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

A lab lands whole, in one pull request of 400 to 700 lines: stub, manifests, scripts,
artifacts and its README. Everything else is one reviewable unit per pull request, 100 to
300 lines, and prose that is not tied to one lab lands on its own.

The reviewer reads, so a lab pull request has to bring the evidence with it: paste the
output of `10-break.sh` and `30-fix.sh` into the body and link the CI run.

## Labs

Every lab under `labs/<pillar>/` has the same six scripts and its own namespace on the
shared `kind` cluster named `anm`. Scripts are idempotent and exit non-zero on failure.
Assertions read conditions, counts and API responses. Never wall clock seconds: probe
periods turn any timing assertion into a race.

`40-verify.sh` asserts the broken state as well as the fixed one. A lab that only proves
the fix says nothing about whether the problem still reproduces.

`artifacts/` is written by `10-break.sh` and `30-fix.sh` only, which is why `40-verify.sh`
sets `ANM_CAPTURE=0`.

Docker, Podman and Finch all work. The scripts pick the first one that answers, Podman,
then Docker, then Finch, and `ANM_RUNTIME` overrides that. kind drives Finch through its
nerdctl provider, which kind still labels experimental; the five labs pass on it.
