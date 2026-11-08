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
# Sign with the local dev identity when present (scripts/dev-cert.sh), else ad-hoc.
identity="-"
security find-certificate -c "Hisashi Dev" >/dev/null 2>&1 && identity="Hisashi Dev"
codesign --force --sign "$identity" "$app" >/dev/null
echo "$app"
