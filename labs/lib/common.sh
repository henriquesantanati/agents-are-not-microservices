#!/usr/bin/env bash
# Shared helpers for every lab. Source it, do not run it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_NAME="anm"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
# The observability lab exports spans to a hostPath. On kind that path lives inside the
# node container, so the cluster maps it to this directory on the laptop.
OTEL_HOST_DIR="${REPO_ROOT}/.anm/otel"
FAILURES=0

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# check <description> <expected> <actual>
check() {
  if [[ "$2" == "$3" ]]; then
    pass "$1"
  else
    printf 'FAIL: %s (expected %s, got %s)\n' "$1" "$2" "$3" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# expect <description> <actual> <operator> <expected>
# Numeric comparison, operator is one of -gt -ge -lt -le -eq. An empty or non-numeric
# actual value fails.
expect() {
  if [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" "$3" "$4" ]; then
    pass "$1 ($2 $3 $4)"
  else
    printf 'FAIL: %s (got %s, wanted %s %s)\n' "$1" "${2:-nothing}" "$3" "$4" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

finish() {
  if (( FAILURES > 0 )); then
    printf '%d assertion(s) failed\n' "$FAILURES" >&2
    exit 1
  fi
}

k() { kubectl --context "$KUBE_CONTEXT" "$@"; }

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
  done
}

# Docker or Podman, whichever is running. ANM_RUNTIME overrides.
container_runtime() {
  if [[ -n "${ANM_RUNTIME:-}" ]]; then echo "$ANM_RUNTIME"; return; fi
  if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then echo podman; return; fi
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then echo docker; return; fi
  die "no running container runtime, start Docker or Podman"
}
RUNTIME="${RUNTIME:-$(container_runtime)}"

kind_() {
  if [[ "$RUNTIME" == podman ]]; then
    KIND_EXPERIMENTAL_PROVIDER=podman kind "$@"
  else
    kind "$@"
  fi
}

# Creates the shared cluster if it is missing. Never deletes it.
ensure_cluster() {
  if kind_ get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    log "cluster $CLUSTER_NAME exists"
    k get nodes >/dev/null 2>&1 \
      || die "cluster $CLUSTER_NAME exists but does not answer; if its node container is stopped, run: kind delete cluster --name $CLUSTER_NAME"
    return
  fi
  mkdir -p "$OTEL_HOST_DIR"
  log "creating cluster $CLUSTER_NAME with $RUNTIME"
  # kind resolves the relative hostPath in the config against the working directory,
  # so run it from the repository root.
  (cd "$REPO_ROOT" && kind_ create cluster --name "$CLUSTER_NAME" --wait 180s \
    --config labs/kind-config.yaml)
}

ensure_namespace() {
  k create namespace "$1" --dry-run=client -o yaml | k apply -f - >/dev/null
}

# load_image <name:tag> <build-context>
# The full docker.io/library name keeps Podman from storing it under localhost/,
# which the kind node would not match against the short name in the manifests.
load_image() {
  local image="docker.io/library/$1" context="$2" archive
  log "building $1"
  "$RUNTIME" build -q -t "$image" "$context" >/dev/null
  archive="$(mktemp)"
  "$RUNTIME" save -o "$archive" "$image" >/dev/null
  kind_ load image-archive "$archive" --name "$CLUSTER_NAME" >/dev/null 2>&1
  rm -f "$archive"
}

# wait_for <timeout-seconds> <command...>
# Polls until the command succeeds. Returns 1 on timeout; the caller asserts.
wait_for() {
  local deadline=$((SECONDS + $1))
  shift
  until "$@"; do
    (( SECONDS >= deadline )) && return 1
    sleep 2
  done
}

# capture <lab-dir> <name> <command...>
# Prints the command's output with a header line naming the command and the date. Saves
# it to artifacts/<name>.txt unless ANM_CAPTURE=0, which 40-verify.sh sets, because only
# 10-break.sh and 30-fix.sh write artifacts.
capture() {
  local dir="$1" name="$2" cmd out
  shift 2
  cmd="$*"
  [[ "$cmd" == "k "* ]] && cmd="kubectl ${cmd#k }"
  out="$("$@" 2>&1)" || true
  save_artifact "$dir" "$name" "$cmd" "$out"
}

# save_artifact <lab-dir> <name> <command-as-shown> <output>
# For output a script already holds because it also asserts on it.
save_artifact() {
  local dir="$1" name="$2" cmd="$3" out="$4" dest=/dev/null
  if [[ "${ANM_CAPTURE:-1}" != 0 ]]; then
    mkdir -p "$dir/artifacts"
    dest="$dir/artifacts/$name.txt"
  fi
  {
    printf '$ %s    # %s\n' "$cmd" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' "$out"
  } | tee "$dest"
}
