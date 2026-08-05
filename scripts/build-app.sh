#!/bin/bash
# Локальная сборка Transcriber.app.
#
# SIGN_IDENTITY — имя сертификата подписи; по умолчанию «-» (ad-hoc).
# Своё имя видно в `security find-identity -v -p codesigning`, например:
#   SIGN_IDENTITY="Apple Development: Jane Doe (ABCDE12345)" bash scripts/build-app.sh
# Ad-hoc подпись работает, но macOS будет заново спрашивать разрешения
# (микрофон, Accessibility) после каждой пересборки.
#
# PROVISION_PROFILE — путь к provisioning profile (по умолчанию Transcriber.provisionprofile
# в корне). Есть профиль — подпись получает keychain-access-groups и секреты уезжают в
# современную связку ключей без диалогов; нет — группа вырезается (см. scripts/entitlements.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=entitlements.sh
source "scripts/entitlements.sh"
# shellcheck source=sparkle.sh
source "scripts/sparkle.sh"
# Локальная личность: файл .signing-identity (в git не попадает) избавляет от запросов
# связки ключей — при ad-hoc подписи каждая пересборка выглядит для macOS новой программой.
if [ -z "${SIGN_IDENTITY:-}" ] && [ -f .signing-identity ]; then
  SIGN_IDENTITY="$(cat .signing-identity)"
fi
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
embed_sparkle "$APP"
ENTITLEMENTS=$(prepare_entitlements Dev.entitlements "$APP" "$SIGN_IDENTITY")
codesign --force --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"
# --deep: внутри бандла теперь живёт Sparkle со своей вложенной программой, и проверять
# надо её тоже — иначе ошибка вложенной подписи всплыла бы только на нотаризации.
codesign --verify --deep --strict --verbose=2 "$APP"
if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "Подпись: ad-hoc (SIGN_IDENTITY не задан)"
else
  echo "Подпись: $SIGN_IDENTITY"
fi
echo "OK: $APP"
