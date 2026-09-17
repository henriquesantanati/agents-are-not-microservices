#!/usr/bin/env bash
# Deletes this lab's namespace only. The cluster, metrics-server and KEDA stay.
source "$(dirname "$0")/lib.sh"

k delete namespace "$NS" --ignore-not-found --wait
