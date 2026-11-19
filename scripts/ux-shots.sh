#!/bin/bash
#
# End-to-end render of SyncBar's popover and Syncs screen in each sync state.
# Runs the UXStateRenderTests offscreen against the isolated test ledger, so it
# never touches the screen or real data. Writes PNGs to the given folder.
#
# Usage: scripts/ux-shots.sh <output-dir>

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
OUT="$(mkdir -p "${1:?usage: ux-shots.sh <output-dir>}" && cd "$1" && pwd)"
rm -f "$OUT"/*.png

[ -f Secrets.xcconfig ] || cp Secrets.xcconfig.example Secrets.xcconfig
xcodegen generate >/dev/null

TEST_RUNNER_UX_SHOTS_DIR="$OUT" xcodebuild \
  -project SyncBar.xcodeproj -scheme SyncBar -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:SyncBarTests/UXStateRenderTests test > "$OUT/xcodebuild.log" 2>&1
STATUS=$?
grep -E "Executed .* tests" "$OUT/xcodebuild.log" | tail -1
ls "$OUT"/*.png
exit $STATUS
