#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep build hosts and SDKs aligned with the supported runtime baseline.
version_at_least() {
    awk -v actual="$1" -v minimum="$2" 'BEGIN {
        split(actual, a, "."); split(minimum, m, ".");
        for (i = 1; i <= 3; i++) {
            if (a[i]+0 > m[i]+0) exit 0;
            if (a[i]+0 < m[i]+0) exit 1;
        }
        exit 0;
    }'
}
version_at_least "$(sw_vers -productVersion)" 27.2 || { echo "macOS 27.2 or later is required." >&2; exit 1; }
version_at_least "$(xcrun --sdk macosx --show-sdk-version)" 27.0 || { echo "macOS SDK 27.0 or later is required." >&2; exit 1; }
swift build -c release --product VirtualConductor
BIN="$(swift build -c release --show-bin-path)"
APP="$PWD/.build/virtual-conductor/Virtual Conductor.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/VirtualConductor" "$APP/Contents/MacOS/VirtualConductor"
for bundle in "$BIN"/*.bundle; do
    if [ -d "$bundle" ]; then cp -R "$bundle" "$APP/Contents/Resources/"; fi
done
cp AppResources/VirtualConductor/Info.plist "$APP/Contents/Info.plist"
# Use a consistent identity so local updates retain microphone permission.
# An explicit override also resolves machines with multiple developers.
identity="${VC_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning | awk '/"Apple Development:/ { hash=$2; count++ } END { if (count==1) print hash }')"
fi
codesign --force --sign "${identity:--}" "$APP"
printf '%s\n' "$APP"
