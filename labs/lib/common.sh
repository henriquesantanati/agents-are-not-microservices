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
PASSES=0

# Colour, only when the output is a terminal and NO_COLOR is unset. The words carry the
# meaning on their own, so a log file or CI reads the same. The palette keeps meaning off
# red versus green: PASS is blue, FAIL and ERROR are bold red, the --> phrase is orange,
# the ==> step is bold, and the $ command line is dim so the output under it stands out.
if [[ -z "${NO_COLOR:-}" && -t 1 ]]; then
  C_STEP=$'\e[1m'        C_SHOW=$'\e[38;5;208m' C_PASS=$'\e[34m'
  C_CMD=$'\e[2m'         C_RESET=$'\e[0m'
else
  C_STEP='' C_SHOW='' C_PASS='' C_CMD='' C_RESET=''
fi
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then C_FAIL=$'\e[1;31m' C_RESET2=$'\e[0m'; else C_FAIL='' C_RESET2=''; fi

log() { printf '%s==> %s%s\n' "$C_STEP" "$*" "$C_RESET"; }
die() { printf '%sERROR: %s%s\n' "$C_FAIL" "$*" "$C_RESET2" >&2; exit 1; }
pass() { PASSES=$((PASSES + 1)); printf '%sPASS: %s%s\n' "$C_PASS" "$*" "$C_RESET"; }
fail() { printf '%sFAIL: %s%s\n' "$C_FAIL" "$*" "$C_RESET2" >&2; FAILURES=$((FAILURES + 1)); }
# One phrase under a block of output, saying what it shows.
show() { printf -- '%s--> %s%s\n\n' "$C_SHOW" "$*" "$C_RESET"; }
# The command a block of output came from. k is shown as kubectl.
cmdline() { local c="$*"; printf '%s$ %s%s\n' "$C_CMD" "${c/#k /kubectl }" "$C_RESET"; }

# check <description> <expected> <actual>
check() {
  if [[ "$2" == "$3" ]]; then
    pass "$1"
  else
    fail "$1 (expected $2, got $3)"
  fi
}

# expect <description> <actual> <operator> <expected>
# Numeric comparison, operator is one of -gt -ge -lt -le -eq. An empty or non-numeric
# actual value fails.
expect() {
  if [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" "$3" "$4" ]; then
    pass "$1 ($2 $3 $4)"
  else
    fail "$1 (got ${2:-nothing}, wanted $3 $4)"
  fi
}

finish() {
  if (( FAILURES > 0 )); then
    printf '%s%d assertion(s) failed%s\n' "$C_FAIL" "$FAILURES" "$C_RESET2" >&2
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

# Docker, Podman or Finch, whichever is running. ANM_RUNTIME overrides.
container_runtime() {
  if [[ -n "${ANM_RUNTIME:-}" ]]; then echo "$ANM_RUNTIME"; return; fi
  if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then echo podman; return; fi
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then echo docker; return; fi
  if command -v finch >/dev/null 2>&1 && finch info >/dev/null 2>&1; then echo finch; return; fi
  die "no running container runtime, start Docker, Podman or Finch"
}
RUNTIME="${RUNTIME:-$(container_runtime)}"

# kind picks Docker on its own and needs to be told about the other two. It accepts finch
# as a provider name and drives it through its nerdctl provider.
kind_() {
  case "$RUNTIME" in
    podman|finch) KIND_EXPERIMENTAL_PROVIDER="$RUNTIME" kind "$@" ;;
    *) kind "$@" ;;
  esac
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

# Proves the node's /var/anm/otel is the laptop's .anm/otel, by writing a file on one side
# and reading it on the other. A cluster created without labs/kind-config.yaml has no
# such mount, and the observability lab would otherwise fail later on an empty directory.
ensure_otel_mount() {
  local probe="mount-check-$$"
  mkdir -p "$OTEL_HOST_DIR"
  "$RUNTIME" exec "${CLUSTER_NAME}-control-plane" touch "/var/anm/otel/$probe" 2>/dev/null
  if [[ ! -f "$OTEL_HOST_DIR/$probe" ]]; then
    die "cluster $CLUSTER_NAME has no /var/anm/otel mount; recreate it from the repository root: kind delete cluster --name $CLUSTER_NAME, then rerun this script"
  fi
  rm -f "$OTEL_HOST_DIR/$probe"
  # The stubs run as nobody, and the directory is whoever created it on the laptop.
  chmod 0777 "$OTEL_HOST_DIR"
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

# retry <tries> <seconds> <command...>: reruns a read that can miss once under load.
retry() {
  local tries="$1" pause="$2" i
  shift 2
  for ((i = 1; i <= tries; i++)); do
    "$@" && return
    (( i < tries )) && sleep "$pause"
  done
  return 1
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
  local header
  header="$cmd    # $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '$ %s\n%s\n' "$header" "$out" > "$dest"
  cmdline "$header"
  printf '%s\n' "$out"
}
