#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --launch-at-login ) ]]; then
    echo "Usage: ./scripts/install.sh [--launch-at-login]" >&2
    exit 1
fi

./scripts/build.sh
app=/Applications/Tokeyy.app
if [[ -e "$app" ]]; then
    identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)
    if [[ "$identifier" != app.tokeyy.mac ]]; then
        echo "Refusing to replace a different application at $app." >&2
        exit 1
    fi
fi

# Stop running copies before replacing the installed bundle.
pkill -TERM -x Tokeyy || true
ditto dist/Tokeyy.app "$app"
codesign --verify --strict "$app"
# Refresh this app's registration so Finder picks up changed icon resources.
touch "$app"
registrar=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ -x "$registrar" ]]; then "$registrar" -f "$app"; fi

login_status=0
if [[ "${1:-}" == --launch-at-login ]]; then
    "$app/Contents/MacOS/Tokeyy" --enable-login || login_status=$?
fi
open "$app"
echo "Installed $app"
exit "$login_status"
