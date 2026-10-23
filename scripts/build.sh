#!/usr/bin/env bash
# Debug build. Regenerates the project first so new files are picked up.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild build -project ScrollCapture.xcodeproj -scheme ScrollCapture \
  -destination 'platform=macOS,arch=arm64' -configuration Debug -derivedDataPath .build/dd -quiet
echo "✅ Build OK → .build/dd/Build/Products/Debug/ScrollCapture.app"
