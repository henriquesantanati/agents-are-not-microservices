#!/usr/bin/env bash
# The commands that show why. Run it after 10-break.sh or 30-fix.sh. It asserts nothing.
source "$(dirname "$0")/lib.sh"

show() {
  printf '\n$ %s\n' "$*" | sed 's/^\$ k /$ kubectl /'
  "$@" || true
}

show k -n "$NS" get pod -o wide
show k -n "$NS" get service mcp a2a -o custom-columns=NAME:.metadata.name,AFFINITY:.spec.sessionAffinity
show k -n "$NS" get deployment mcp a2a -o custom-columns=NAME:.metadata.name,ENV:.spec.template.spec.containers[0].env[*].value
show k -n "$NS" get endpointslice -l 'kubernetes.io/service-name in (mcp,a2a)' \
  -o custom-columns=SERVICE:.metadata.labels.kubernetes\\.io/service-name,PODS:.endpoints[*].targetRef.name
