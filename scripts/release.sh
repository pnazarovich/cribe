#!/bin/bash
#
# Релизная сборка Transcriber: .app → подпись Developer ID → нотаризация → .dmg
#
# ПЕРЕМЕННЫЕ ОКРУЖЕНИЯ
#   DEVELOPER_ID  обязательна. Имя сертификата «Developer ID Application» целиком,
#                 например "Developer ID Application: Jane Doe (ABCDE12345)".
#                 Список установленных: security find-identity -v -p codesigning
#                 Особое значение "-" — ad-hoc подпись; годится ТОЛЬКО с --skip-notarize,
#                 чтобы проверить упаковку без сертификата.
#   APPLE_ID      обязательна без --skip-notarize. Apple ID аккаунта разработчика.
#   TEAM_ID       обязательна без --skip-notarize. Team ID (10 символов), виден
#                 на https://developer.apple.com/account → Membership details.
#   APP_PASSWORD  обязательна без --skip-notarize. App-specific password, создаётся на
#                 https://account.apple.com → Sign-In and Security → App-Specific Passwords.
#                 Это НЕ пароль от Apple ID.
#
# ЗАПУСК
#   DEVELOPER_ID="Developer ID Application: …" APPLE_ID=… TEAM_ID=… APP_PASSWORD=… \
#     bash scripts/release.sh
#
#   # проверка упаковки без сертификата и без нотаризации (получится неподписанный DMG):
#   DEVELOPER_ID="-" bash scripts/release.sh --skip-notarize
#
# Скрипт идемпотентен: каждый запуск пересобирает dist/ с нуля и перезаписывает артефакты.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

# --- Аргументы ---------------------------------------------------------------

SKIP_NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *) fail "неизвестный аргумент: $arg (см. $0 --help)" ;;
  esac
done

# --- Проверка окружения ------------------------------------------------------

if [ -z "${DEVELOPER_ID:-}" ]; then
  fail "не задана DEVELOPER_ID.

  Посмотрите доступные сертификаты:
      security find-identity -v -p codesigning
  и запустите с нужным именем целиком:
      DEVELOPER_ID=\"Developer ID Application: Jane Doe (ABCDE12345)\" bash scripts/release.sh

  Сертификата нет? Проверить упаковку можно ad-hoc, без нотаризации:
      DEVELOPER_ID=\"-\" bash scripts/release.sh --skip-notarize"
fi

if [ "$DEVELOPER_ID" = "-" ] && [ "$SKIP_NOTARIZE" -eq 0 ]; then
  fail "ad-hoc подпись (DEVELOPER_ID=\"-\") нотаризацию не проходит.
  Либо укажите настоящий сертификат Developer ID, либо добавьте --skip-notarize."
fi

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
  for name in APPLE_ID TEAM_ID APP_PASSWORD; do
    if [ -z "${!name:-}" ]; then
      fail "не задана $name — она нужна для нотаризации.
  Задайте APPLE_ID, TEAM_ID и APP_PASSWORD (см. шапку $0)
  или запустите с --skip-notarize, чтобы собрать только DMG."
    fi
  done
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
APP="dist/Transcriber.app"
ZIP="dist/Transcriber-$VERSION.zip"
DMG="dist/Transcriber-$VERSION.dmg"
STAGE="dist/dmg-stage"
VOLNAME="Transcriber $VERSION"

# --- Сборка ------------------------------------------------------------------

# build-app.sh чистит dist/ и подписывает ad-hoc; настоящую подпись накладываем ниже.
step "Сборка .app"
SIGN_IDENTITY="-" bash scripts/build-app.sh

# --- Подпись -----------------------------------------------------------------

step "Подпись ($DEVELOPER_ID)"
# У ad-hoc подписи нет сертификата, а значит и доверенной метки времени: для сухого
# прогона её приходится выключать, в настоящем релизе --timestamp обязателен.
TIMESTAMP_FLAG="--timestamp"
[ "$DEVELOPER_ID" = "-" ] && TIMESTAMP_FLAG="--timestamp=none"

# Вложенные бандлы подписываем первыми: подпись .app запечатывает их как ресурсы.
while IFS= read -r nested; do
  codesign --force --options runtime "$TIMESTAMP_FLAG" --sign "$DEVELOPER_ID" "$nested"
done < <(find "$APP/Contents" -maxdepth 2 -name '*.bundle')

codesign --force --options runtime "$TIMESTAMP_FLAG" \
  --entitlements Release.entitlements --sign "$DEVELOPER_ID" "$APP"

step "Проверка подписи"
codesign --verify --strict --verbose=2 "$APP"
# До нотаризации Gatekeeper приложение отвергает — это ожидаемо, поэтому здесь мягко.
spctl -a -vvv -t install "$APP" || echo "(ожидаемо: Gatekeeper пропустит только после нотаризации)"

# --- Архив и нотаризация -----------------------------------------------------

step "Архив для нотаризации"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ "$SKIP_NOTARIZE" -eq 1 ]; then
  step "Нотаризация пропущена (--skip-notarize)"
else
  step "Нотаризация .app"
  xcrun notarytool submit "$ZIP" \
    --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" --wait

  step "Степлер .app"
  xcrun stapler staple "$APP"
  # Пересобираем архив уже со степлером внутри.
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"

  step "Проверка Gatekeeper"
  spctl -a -vvv -t install "$APP"
fi

# --- DMG ---------------------------------------------------------------------

step "Сборка DMG"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# Том с прошлого запуска держит образ занятым — отцепляем, иначе hdiutil не пересоздаст.
if [ -d "/Volumes/$VOLNAME" ]; then hdiutil detach "/Volumes/$VOLNAME" -quiet || true; fi
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
  step "Подпись, нотаризация и степлер DMG"
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
  xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi

# --- Итог --------------------------------------------------------------------

step "Готово"
ls -lh "$ZIP" "$DMG" | awk '{ print "  " $9 "  " $5 }'
shasum -a 256 "$ZIP" "$DMG"
if [ "$SKIP_NOTARIZE" -eq 1 ]; then
  echo
  echo "ВНИМАНИЕ: сборка не нотаризована — для раздачи пользователям она не годится."
fi
