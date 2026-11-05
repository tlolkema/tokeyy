#!/bin/bash
set -euo pipefail
# Prefer full Xcode. Some CLT SDKs omit the SwiftUI macro plugin.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
exec xcrun swift "$@"
