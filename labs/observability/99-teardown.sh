#!/usr/bin/env bash
# Deletes this lab's namespace and span files only. The cluster stays for the other labs.
source "$(dirname "$0")/lib.sh"

k delete namespace "$NS" --ignore-not-found --wait
rm -f "$OTEL_HOST_DIR"/*.jsonl
