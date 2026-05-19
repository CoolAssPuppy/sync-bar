#!/bin/bash
#
# Build (Debug) and launch SyncNerds.app.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

"$REPO_ROOT/scripts/build.sh"

APP_PATH="$REPO_ROOT/build/Build/Products/Debug/SyncNerds.app"
if [ ! -d "$APP_PATH" ]; then
  echo "Error: build artifact not found at $APP_PATH"
  exit 1
fi

# Stop any running copies first.
pkill -x SyncNerds 2>/dev/null || true
sleep 0.2

open "$APP_PATH"
