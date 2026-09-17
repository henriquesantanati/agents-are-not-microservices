#!/usr/bin/env bash
# The commands that show why. Run it after 10-break.sh or 30-fix.sh. It asserts nothing.
source "$(dirname "$0")/lib.sh"

show() {
  printf '\n$ %s\n' "$*" | sed 's/^\$ k /$ kubectl /'
  "$@" || true
}

show k -n "$NS" get deployment -o custom-columns=NAME:.metadata.name,ENV:.spec.template.spec.containers[0].env[*].value
show ls -l "$OTEL_HOST_DIR"
# One line per span: name, kind, trace id, status, events.
show python3 -c '
import glob, json, sys
for path in sorted(glob.glob(sys.argv[1] + "/spans-*.jsonl")):
    for line in open(path):
        s = json.loads(line)
        print(f"{s[\"name\"]:32} {s[\"kind\"][9:]:9} {s[\"context\"][\"trace_id\"]} {s[\"status\"][\"status_code\"]:6} {[e[\"name\"] for e in s[\"events\"]]}")
' "$OTEL_HOST_DIR"
show sh -c "cat '$OTEL_HOST_DIR'/events-*.jsonl 2>/dev/null"
