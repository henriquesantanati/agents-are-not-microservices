#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

require_tools kind kubectl python3
ensure_cluster
ensure_namespace "$NS"
load_image anm-communication:dev "$LAB_DIR/agent"
log "ready: namespace $NS on cluster $CLUSTER_NAME"
