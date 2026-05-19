#!/bin/bash
# Lint SyncNerds via SwiftLint. No-op if SwiftLint isn't installed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "SwiftLint not installed. Install with: brew install swiftlint"
  exit 0
fi

swiftlint --config .swiftlint.yml --quiet
