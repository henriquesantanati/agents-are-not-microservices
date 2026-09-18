#!/bin/sh
# preStop hook. A script cannot read the agent's memory, so it asks the agent to write
# its own checkpoint and waits for the answer.
exec python3 -c '
import urllib.request as u
u.urlopen(u.Request("http://127.0.0.1:8080/checkpoint", method="POST"), timeout=60).read()
'
