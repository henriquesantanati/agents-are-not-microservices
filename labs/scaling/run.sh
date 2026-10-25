#!/usr/bin/env bash
# Run setup, break, observe, fix and verify in one go. Stops at the first failure.
# This is what CI runs, and it fails if the break stops reproducing as much as if the fix
# stops working. Setup is safe to repeat, it only creates what is missing.
set -euo pipefail
cd "$(dirname "$0")"

./00-setup.sh
./10-break.sh
./20-observe.sh
./30-fix.sh
./40-verify.sh
