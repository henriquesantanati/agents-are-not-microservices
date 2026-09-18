#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

require_tools kind kubectl python3
ensure_cluster
ensure_otel_mount
ensure_namespace "$NS"
load_image anm-observability:dev "$LAB_DIR/agent"
log "ready: namespace $NS on cluster $CLUSTER_NAME, spans land in $OTEL_HOST_DIR"
