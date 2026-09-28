#!/bin/bash
# Build a local ad-hoc signed beta; does not install, publish or change permissions.
set -euo pipefail
cd "$(dirname "$0")/.."
version=1.0.0-beta.1
output="$PWD/build/releases/$version"
if [[ -e "$output" ]]; then
  echo "Output already exists: $output. Preserve or move it before rebuilding." >&2
  exit 1
fi
mkdir -p "$output"
stage=$(mktemp -d "$PWD/build/quill-dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT
xcodebuild -project Quill.xcodeproj -scheme Quill -configuration Release \
  -derivedDataPath build/beta-derived ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION=1.0.0 CURRENT_PROJECT_VERSION=1001 build
app="$PWD/build/beta-derived/Build/Products/Release/Quill.app"
codesign --verify --deep --strict "$app"
architectures=$(lipo -archs "$app/Contents/MacOS/Quill")
[[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]] || { echo "Missing required architecture: $architectures" >&2; exit 1; }
ditto "$app" "$stage/Quill.app"
ln -s /Applications "$stage/Applications"
cp docs/BETA-SETUP.md "$output/Quill-Beta-Setup.txt"
cp docs/BETA-SETUP.md "$stage/Setup.txt"
cp LICENSE "$stage/LICENSE.txt"
cat > "$stage/Start Here.html" <<'HTML'
<!doctype html><html lang="en"><meta charset="utf-8"><title>Install Quill Beta</title>
<style>body{font:18px -apple-system,BlinkMacSystemFont,sans-serif;max-width:760px;margin:60px auto;padding:0 24px;line-height:1.6;color:#172033}h1{font-size:40px}li{margin:14px 0}aside{background:#fff3d7;padding:18px;border-radius:12px}a{color:#254dba}</style>
<h1>Welcome to Quill Beta</h1><p>Better writing, one shortcut away.</p>
<aside><strong>Before you start:</strong> macOS 14+ and a compatible separately installed Codex runtime are required. This beta is not notarized by Apple. Apple Silicon is tested; Intel is unverified.</aside>
<ol><li>Drag <strong>Quill.app</strong> onto <strong>Applications</strong> in this disk image.</li>
<li>Eject the disk image and open Quill from Applications. If blocked as an unidentified developer, follow <a href="https://support.apple.com/en-us/102445">Apple's Open Anyway instructions</a> only if you trust the download.</li>
<li>Click the feather in the menu bar and open <strong>Settings</strong>. Check the runtime and sign in with ChatGPT.</li>
<li>Choose <strong>Open permission settings</strong>, enable Quill's Accessibility access, then recheck access.</li>
<li>Select text in an unsent draft and press <strong>⌘⇧E</strong>. Keep the selection active while Quill corrects it.</li></ol>
<p>Read <a href="Setup.txt">the complete setup guide</a> for runtime installation, troubleshooting, privacy, and beta limitations.</p>
<p><a href="https://github.com/Nozibulla/Quill/issues">Report a problem</a> · <a href="https://github.com/Nozibulla/Quill">Source code</a></p></html>
HTML
hdiutil create -volname 'Quill Beta' -srcfolder "$stage" -format UDZO -ov "$output/Quill-$version-universal.dmg"
hdiutil verify "$output/Quill-$version-universal.dmg"
(cd "$output" && shasum -a 256 "Quill-$version-universal.dmg" > SHA256SUMS.txt)
printf '\nBeta artifacts: %s\n' "$output"
