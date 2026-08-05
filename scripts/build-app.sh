#!/bin/bash
# Локальная сборка Transcriber.app.
#
# SIGN_IDENTITY — имя сертификата подписи; по умолчанию «-» (ad-hoc).
# Своё имя видно в `security find-identity -v -p codesigning`, например:
#   SIGN_IDENTITY="Apple Development: Jane Doe (ABCDE12345)" bash scripts/build-app.sh
# Ad-hoc подпись работает, но macOS будет заново спрашивать разрешения
# (микрофон, Accessibility) после каждой пересборки.
set -euo pipefail
cd "$(dirname "$0")/.."
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
xcodebuild -scheme Transcriber -configuration Release \
  -derivedDataPath .ddata -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO build
APP=dist/Transcriber.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .ddata/Build/Products/Release/Transcriber "$APP/Contents/MacOS/"
cp -R .ddata/Build/Products/Release/*.bundle "$APP/Contents/Resources/" 2>/dev/null || true
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "Подпись: ad-hoc (SIGN_IDENTITY не задан)"
else
  echo "Подпись: $SIGN_IDENTITY"
fi
echo "OK: $APP"
