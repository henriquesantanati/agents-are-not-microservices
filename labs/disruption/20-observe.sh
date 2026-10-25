#!/usr/bin/env bash
# The commands that show why. Run it after 10-break.sh or 30-fix.sh. It asserts nothing.
source "$(dirname "$0")/lib.sh"

run() {
  echo
  cmdline "$@"
  "$@" 2>&1 || true
}

run k -n "$NS" get pdb agent
echo
show "ALLOWED DISRUPTIONS 0. The budget counts evictions and nothing else. A delete, an OOM kill or a lost node never asks it."

run k -n "$NS" get pod "$POD" -o jsonpath='{"grace:   "}{.spec.terminationGracePeriodSeconds}{"s\n"}{"preStop: "}{.spec.containers[0].lifecycle.preStop.exec.command}{"\n"}'
echo
show "The grace period and the preStop hook, if there is one. Both only matter on the voluntary path, and a grace period alone saves nothing."

run k -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].lastState}{"\n"}'
echo
show "Empty until something killed the container in place. After the OOM kill in 30-fix.sh it shows exit code 137."

run k -n "$NS" logs "$POD" -c agent --tail=5
echo
show "The agent's own account. With CHECKPOINT=all every step ends with a checkpoint line, and that is what the next process resumes from."

run k -n "$NS" logs "$POD" -c agent --previous --tail=3
echo
show "The dead container's last lines, if this container is a restart. If it is not, there is no previous container and kubectl says so."

run k -n "$NS" get events --field-selector involvedObject.name="$POD" --sort-by=.lastTimestamp
echo
show "Every Killing is the kubelet on the voluntary path, preStop then SIGTERM. Created and Started after it are the replacement."
