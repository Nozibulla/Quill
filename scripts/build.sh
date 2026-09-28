#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project Quill.xcodeproj -scheme Quill -configuration Release -derivedDataPath build build
printf '\nLaunch with: open "%s/build/Build/Products/Release/Quill.app"\n' "$PWD"
