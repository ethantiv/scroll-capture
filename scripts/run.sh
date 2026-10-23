#!/usr/bin/env bash
# Build, replace the running Debug instance, launch. The app lives in the menu bar only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/build.sh"
pkill -f "Debug/ScrollCapture.app/Contents/MacOS/ScrollCapture" 2>/dev/null || true
sleep 1
open -n "$SCRIPT_DIR/../.build/dd/Build/Products/Debug/ScrollCapture.app"
echo "🚀 Uruchomiono. Ikona strzałki w dół w pasku menu, skrót ⌃⌥⌘S."
