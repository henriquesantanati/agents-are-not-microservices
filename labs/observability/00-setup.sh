#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

require_tools kind kubectl python3
ensure_cluster
[[ -d "$OTEL_HOST_DIR" ]] || die "$OTEL_HOST_DIR is missing; the cluster was created without its extraMounts entry"
ensure_namespace "$NS"
load_image anm-observability:dev "$LAB_DIR/agent"
log "ready: namespace $NS on cluster $CLUSTER_NAME, spans land in $OTEL_HOST_DIR"
