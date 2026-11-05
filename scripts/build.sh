#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
if [[ "$configuration" != release && "$configuration" != debug ]]; then
    echo "Usage: ./scripts/build.sh [release|debug]" >&2
    exit 1
fi
./scripts/swift.sh build --build-path .build/native --configuration "$configuration"
bin="$(./scripts/swift.sh build --build-path .build/native --configuration "$configuration" --show-bin-path)"
app="$PWD/dist/Tokeyy.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Tokeyy" "$app/Contents/MacOS/Tokeyy"
cp Resources/Info.plist "$app/Contents/Info.plist"
./scripts/swift.sh scripts/make-icon.swift "$PWD/dist/AppIcon.iconset"
iconutil -c icns dist/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
# Local signing only. Distribution requires a Developer ID and notarization.
codesign --force --sign - "$app"
codesign --verify --strict "$app"
echo "Built $app"
