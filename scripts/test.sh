#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project Quill.xcodeproj -scheme Quill -configuration Debug -derivedDataPath build test
