#!/bin/bash
#
# Run unit tests for SyncNerds.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Regenerating Xcode project"
xcodegen generate >/dev/null

echo "==> Running tests"
xcodebuild \
  -project SyncNerds.xcodeproj \
  -scheme SyncNerds \
  -configuration Debug \
  -derivedDataPath build \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  test
