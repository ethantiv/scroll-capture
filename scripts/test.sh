#!/usr/bin/env bash
# Offline unit tests. --adhoc signs ad hoc (no "Local Self-Signed" certificate needed).
set -euo pipefail
cd "$(dirname "$0")/.."
EXTRA=()
[[ "${1:-}" == "--adhoc" ]] && EXTRA+=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)
xcodegen generate
xcodebuild test -project ScrollCapture.xcodeproj -scheme ScrollCapture \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/dd ${EXTRA[@]+"${EXTRA[@]}"} -quiet
echo "✅ Testy OK"
