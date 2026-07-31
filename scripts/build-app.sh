#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -scheme Transcriber -configuration Release \
  -derivedDataPath .ddata -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO build
APP=dist/Transcriber.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .ddata/Build/Products/Release/Transcriber "$APP/Contents/MacOS/"
cp -R .ddata/Build/Products/Release/*.bundle "$APP/Contents/Resources/" 2>/dev/null || true
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "Apple Development: Created via API (Q6WMXBUR99)" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "OK: $APP"
