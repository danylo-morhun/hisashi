#!/usr/bin/env bash
# Rebuild, stop the running copy, start the new one.
set -euo pipefail
cd "$(dirname "$0")/.."
app="$(scripts/bundle.sh "${1:-debug}" | tail -1)"
pkill -x Hisashi || true
while pgrep -x Hisashi >/dev/null; do sleep 0.2; done
open "$app" --args "${@:2}"
