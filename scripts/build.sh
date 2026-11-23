#!/bin/bash
# Build "SSD Monitor.app" into build/: release, Apple silicon, ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64
bin=$(swift build -c release --arch arm64 --show-bin-path)
app="build/SSD Monitor.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/SSDMonitor" "$app/Contents/MacOS/SSDMonitor"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$app"
echo "built $app"
