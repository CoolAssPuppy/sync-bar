#!/bin/bash
#
# Bootstrap the SyncBar dev environment.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

for tool in xcodegen xcodebuild; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: $tool is not installed. Install with: brew install $tool"
    exit 1
  fi
done

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Resolving Swift package dependencies"
xcodebuild \
  -project SyncBar.xcodeproj \
  -scheme SyncBar \
  -resolvePackageDependencies >/dev/null

echo "==> Done. Next steps:"
echo "    ./scripts/build.sh"
echo "    ./scripts/run.sh"
