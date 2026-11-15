#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo 'This build requires macOS + Xcode. Use the provided standard macOS Actions workflow.' >&2
  exit 1
fi
python3 scripts/prepare.py
xcodegen generate
xcodebuild -project UTubeMusic.xcodeproj -scheme UTubeMusic -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/device \
  CODE_SIGNING_ALLOWED=NO build >build/device-build.log 2>&1 || { tail -120 build/device-build.log; exit 1; }
python3 scripts/package_ipa.py
