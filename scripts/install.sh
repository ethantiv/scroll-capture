#!/usr/bin/env bash
# Release build → /Applications/ScrollCapture.app, replacing and relaunching the running copy.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild build -project ScrollCapture.xcodeproj -scheme ScrollCapture \
  -destination 'platform=macOS,arch=arm64' -configuration Release -derivedDataPath .build/dd -quiet
pkill -x ScrollCapture 2>/dev/null && sleep 1 || true
rm -rf /Applications/ScrollCapture.app
cp -R .build/dd/Build/Products/Release/ScrollCapture.app /Applications/
open /Applications/ScrollCapture.app
echo "✅ Zainstalowano → /Applications/ScrollCapture.app"
