#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
# A stable application path avoids granting access to an obsolete build-directory copy.
# Keep the old bundle recoverable if it exists; never overwrite an unrelated application.
if [[ -d /Applications/Quill.app ]]; then
  identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' /Applications/Quill.app/Contents/Info.plist)
  [[ "$identifier" == com.bashar.Quill ]] || { echo 'A different Quill app already exists in Applications.' >&2; exit 1; }
  echo 'Quit Quill before installing an updated build.'
  ditto /Applications/Quill.app build/Quill-previous.app
fi
ditto build/Build/Products/Release/Quill.app /Applications/Quill.app
codesign --verify --deep --strict /Applications/Quill.app
open /Applications/Quill.app
