#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/swift.sh test --build-path .build/native
bin="$(./scripts/swift.sh build --build-path .build/native --show-bin-path)"
"$bin/Tokeyy" --render-previews "$PWD/dist/previews"
# Opens actual native windows briefly. Demo mode never reads account credentials.
"$bin/Tokeyy" --demo --smoke-test-ui
