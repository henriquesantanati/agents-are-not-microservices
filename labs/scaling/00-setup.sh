#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

require_tools kind kubectl helm python3
ensure_cluster

# kind does not ship metrics-server. Without it the HPA reports unknown and the broken
# state would be a lie. The kubelet certificates on kind are self-signed.
log "installing metrics-server chart $METRICS_SERVER_CHART_VERSION"
helm upgrade --install metrics-server metrics-server \
  --kube-context "$KUBE_CONTEXT" \
  --repo https://kubernetes-sigs.github.io/metrics-server/ \
  --version "$METRICS_SERVER_CHART_VERSION" \
  --namespace kube-system \
  --set 'args={--kubelet-insecure-tls}' \
  --wait >/dev/null

log "installing KEDA chart $KEDA_CHART_VERSION"
helm upgrade --install keda keda \
  --kube-context "$KUBE_CONTEXT" \
  --repo https://kedacore.github.io/charts \
  --version "$KEDA_CHART_VERSION" \
  --namespace keda --create-namespace \
  --wait >/dev/null

ensure_namespace "$NS"
load_image anm-scaling:dev "$LAB_DIR/agent"
log "ready: namespace $NS on cluster $CLUSTER_NAME"
