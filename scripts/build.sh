#!/bin/bash
#
# Local debug build for SyncBar.
#
#   ./scripts/build.sh                  - debug build
#   ./scripts/build.sh release          - release build
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# OAuth credentials are baked in from Secrets.xcconfig (gitignored). Seed an
# empty one from the example so the build works before Doppler is wired up;
# run scripts/pull-secrets.sh to populate it.
[ -f Secrets.xcconfig ] || cp Secrets.xcconfig.example Secrets.xcconfig

CONFIG="Debug"
if [ "${1:-}" = "release" ]; then
  CONFIG="Release"
fi

echo "==> Regenerating Xcode project"
xcodegen generate >/dev/null

echo "==> Building SyncBar ($CONFIG)"
# Plain automatic signing (CODE_SIGN_STYLE/DEVELOPMENT_TEAM come from
# project.yml), mirroring the sibling apps. Xcode signs with Apple Development
# and a managed profile, which gives the app an application-identifier (so
# keychain writes succeed) and get-task-allow (so the Debug build launches).
# Do NOT pass CODE_SIGNING_ALLOWED=NO — an unsigned build has no keychain
# entitlement and silently loses every OAuth + reMarkable token.
xcodebuild \
  -project SyncBar.xcodeproj \
  -scheme SyncBar \
  -configuration "$CONFIG" \
  -derivedDataPath build \
  -destination 'platform=macOS' \
  build | xcbeautify --quiet 2>/dev/null || xcodebuild \
    -project SyncBar.xcodeproj \
    -scheme SyncBar \
    -configuration "$CONFIG" \
    -derivedDataPath build \
    -destination 'platform=macOS' \
    build

APP_PATH="$REPO_ROOT/build/Build/Products/$CONFIG/SyncBar.app"
if [ -d "$APP_PATH" ]; then
  echo "==> Built: $APP_PATH"
fi
