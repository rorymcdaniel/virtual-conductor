#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product VirtualConductor
BIN="$(swift build -c release --show-bin-path)"
APP="$PWD/.build/virtual-conductor/Virtual Conductor.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/VirtualConductor" "$APP/Contents/MacOS/VirtualConductor"
cp AppResources/VirtualConductor/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
