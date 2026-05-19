#!/bin/bash
#
# Local debug build for SyncNerds.
#
#   ./scripts/build.sh                  - debug build
#   ./scripts/build.sh release          - release build
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONFIG="Debug"
if [ "${1:-}" = "release" ]; then
  CONFIG="Release"
fi

echo "==> Regenerating Xcode project"
xcodegen generate >/dev/null

echo "==> Building SyncNerds ($CONFIG)"
xcodebuild \
  -project SyncNerds.xcodeproj \
  -scheme SyncNerds \
  -configuration "$CONFIG" \
  -derivedDataPath build \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build | xcbeautify --quiet 2>/dev/null || xcodebuild \
    -project SyncNerds.xcodeproj \
    -scheme SyncNerds \
    -configuration "$CONFIG" \
    -derivedDataPath build \
    -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build

APP_PATH="$REPO_ROOT/build/Build/Products/$CONFIG/SyncNerds.app"
if [ -d "$APP_PATH" ]; then
  echo "==> Built: $APP_PATH"
fi
