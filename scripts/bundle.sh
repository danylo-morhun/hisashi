#!/usr/bin/env bash
# Build the package and wrap the binary into build/Hisashi.app.
set -euo pipefail
cd "$(dirname "$0")/.."
config="${1:-release}"
# CLT ships no SwiftUI macro plugin; SDK 26.5 still declares @State as a plain property wrapper.
export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
swift build -c "$config"
app="build/Hisashi.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp ".build/$config/Hisashi" "$app/Contents/MacOS/Hisashi"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app" >/dev/null
echo "$app"
