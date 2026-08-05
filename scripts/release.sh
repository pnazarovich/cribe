#!/bin/bash
#
# Релизная сборка Transcriber: .app → подпись Developer ID → нотаризация → .dmg,
# а следом — то, что нужно автообновлению: .zip, его подпись EdDSA и новый <item>
# в appcast.xml.
#
# ЧТО ПОЛУЧАЕТСЯ
#   dist/Transcriber-<версия>.dmg  — для тех, кто ставит впервые (перетащить в Программы);
#   dist/Transcriber-<версия>.zip  — для Sparkle (по zip обновление ставится надёжнее);
#   appcast.xml                    — обновлён новым выпуском (коммит и пуш — за вами).
#   Оба файла нужно приложить к релизу на GitHub с тегом v<версия>: адрес zip в appcast
#   рассчитан именно на этот тег и на это имя файла.
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
#   SPARKLE_KEY_SOURCE          откуда брать приватный ключ EdDSA: "file" (по умолчанию)
#                               или "keychain". Связка ключей поднимает диалог пароля —
#                               файл этого не делает, поэтому он и по умолчанию.
#   SPARKLE_PRIVATE_KEY_FILE    путь к файлу ключа. Обязательна при SPARKLE_KEY_SOURCE=file.
#                               Файл с ключом в репозиторий не кладут (см. .gitignore).
#
# ЗАПУСК
#   DEVELOPER_ID="Developer ID Application: …" APPLE_ID=… TEAM_ID=… APP_PASSWORD=… \
#     SPARKLE_PRIVATE_KEY_FILE=~/.keys/transcriber-sparkle.key \
#     bash scripts/release.sh
#
#   # проверка упаковки без сертификата и без нотаризации (получится неподписанный DMG,
#   # appcast.xml при этом не трогается — печатается только то, что в него ушло бы):
#   DEVELOPER_ID="-" SPARKLE_PRIVATE_KEY_FILE=… bash scripts/release.sh --skip-notarize
#
# Скрипт идемпотентен: каждый запуск пересобирает dist/ с нуля и перезаписывает артефакты.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=entitlements.sh
source "scripts/entitlements.sh"
# shellcheck source=sparkle.sh
source "scripts/sparkle.sh"

fail() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

# --- Аргументы ---------------------------------------------------------------

SKIP_NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    -h|--help) sed -n '2,41p' "$0"; exit 0 ;;
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
# Sparkle сравнивает выпуски по CFBundleVersion, а не по «человеческой» версии: не поднять
# его — значит выпустить обновление, которого никто не увидит.
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)
PUBLIC_ED_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Info.plist)
NOTES="release-notes/$VERSION.md"
APPCAST="appcast.xml"
ANCHOR="NEW-ITEM-ANCHOR"
RELEASE_URL="https://github.com/pnazarovich/transcriber/releases/download/v$VERSION"

# Заглушка из репозитория: пока владелец не вставил свой публичный ключ, подписывать
# обновления нечем — и выпускать их нельзя, иначе установленные копии получат архив,
# который не пройдёт проверку подписи.
if [ "$PUBLIC_ED_KEY" = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ]; then
  fail "в Info.plist стоит заглушка SUPublicEDKey.

  Ключ подписи обновлений создаётся ОДИН раз (см. docs/releasing.md):
      bash scripts/sparkle-tool.sh generate_keys
  Публичный ключ из его вывода нужно вписать в Info.plist → SUPublicEDKey."
fi

[ -f "$NOTES" ] || fail "нет файла заметок к выпуску: $NOTES
  Опишите в нём, что изменилось, — этот текст увидят в окне обновления."

[ -f "$APPCAST" ] || fail "нет $APPCAST"
grep -q "$ANCHOR" "$APPCAST" || fail "в $APPCAST нет якоря $ANCHOR — вставлять выпуск некуда."

# Тот же CFBundleVersion уже выпущен: Sparkle такое обновление проигнорирует, а в ленте
# останутся два одинаковых выпуска.
if grep -q "<sparkle:version>$BUILD</sparkle:version>" "$APPCAST"; then
  fail "в $APPCAST уже есть выпуск с CFBundleVersion=$BUILD.
  Поднимите CFBundleVersion в Info.plist."
fi

# Ключ подписи: файл по умолчанию, связка ключей — по явной просьбе.
SPARKLE_KEY_SOURCE="${SPARKLE_KEY_SOURCE:-file}"
case "$SPARKLE_KEY_SOURCE" in
  file)
    [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ] || fail "не задана SPARKLE_PRIVATE_KEY_FILE.
  Это путь к файлу с приватным ключом EdDSA (см. docs/releasing.md).
  Ключ лежит в связке ключей? Тогда: SPARKLE_KEY_SOURCE=keychain"
    [ -f "$SPARKLE_PRIVATE_KEY_FILE" ] || fail "файла ключа нет: $SPARKLE_PRIVATE_KEY_FILE"
    ;;
  keychain) ;;
  *) fail "SPARKLE_KEY_SOURCE должна быть file или keychain, а не «$SPARKLE_KEY_SOURCE»" ;;
esac

# Ключ передаётся не массивом аргументов: в bash 3.2 (а он и стоит на macOS) под `set -u`
# разворачивание ПУСТОГО массива — «unbound variable», и вариант со связкой ключей падал бы.
sign_update_run() {
  if [ "$SPARKLE_KEY_SOURCE" = "file" ]; then
    "$SIGN_UPDATE" -f "$SPARKLE_PRIVATE_KEY_FILE" "$@"
  else
    # Без -f sign_update идёт в связку ключей — она спросит пароль.
    "$SIGN_UPDATE" "$@"
  fi
}

APP="dist/Transcriber.app"
ZIP="dist/Transcriber-$VERSION.zip"
DMG="dist/Transcriber-$VERSION.dmg"
STAGE="dist/dmg-stage"
# Имя тома видно в Finder и в /Volumes — версия там только мешает: пользователю нужно
# «Transcriber», а номер сборки и так стоит в имени файла DMG.
VOLNAME="Transcriber"
RWDMG="dist/Transcriber-rw.dmg"

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

# Sparkle приезжает подписанной своей командой, а под hardened runtime библиотеки обязаны
# быть подписаны нашей: без этого приложение не запустится. Внутри фреймворка своя
# вложенная программа — подписывается изнутри наружу (см. scripts/sparkle.sh).
sign_sparkle "$APP" "$DEVELOPER_ID" "$TIMESTAMP_FLAG"

ENTITLEMENTS=$(prepare_entitlements Release.entitlements "$APP" "$DEVELOPER_ID")
codesign --force --options runtime "$TIMESTAMP_FLAG" \
  --entitlements "$ENTITLEMENTS" --sign "$DEVELOPER_ID" "$APP"

step "Проверка подписи"
codesign --verify --deep --strict --verbose=2 "$APP"
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
rm -rf "$STAGE" "$DMG" "$RWDMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# Том с прошлого запуска держит образ занятым — отцепляем, иначе hdiutil не пересоздаст.
if [ -d "/Volumes/$VOLNAME" ]; then hdiutil detach "/Volumes/$VOLNAME" -quiet || true; fi

# Раскладку окна хранит .DS_Store внутри тома, а пишет его только Finder — поэтому
# образ сначала собирается доступным на запись, монтируется, обставляется и лишь потом
# сжимается. Место в 200 МБ сверх содержимого — под служебные структуры HFS.
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDRW \
  -megabytes $(( $(du -sm "$STAGE" | cut -f1) + 200 )) "$RWDMG"
rm -rf "$STAGE"
MOUNT=$(hdiutil attach "$RWDMG" -readwrite -noverify -noautoopen | grep '/Volumes/' | tail -1 \
  | sed 's|.*\(/Volumes/.*\)|\1|')

step "Раскладка окна DMG"
cat > dist/dmg-layout.applescript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- 640×400 в точках: две иконки по 128 стоят просторно и целиком видны без прокрутки.
    set the bounds of container window to {240, 160, 880, 560}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    set text size of theViewOptions to 13
    -- Приложение слева, папка «Программы» справа: перетаскивание читается само собой.
    set position of item "Transcriber.app" of container window to {160, 170}
    set position of item "Applications" of container window to {480, 170}
    close
    open
    update without registering applications
    delay 2
  end tell
end tell
APPLESCRIPT
# Finder водится Apple-событиями, а на них нужно разрешение «Автоматизация». Нет его
# (сборка по ssh, на CI, на свежей машине) — DMG всё равно соберётся, просто без раскладки:
# ронять релиз из-за косметики нельзя.
if osascript dist/dmg-layout.applescript >/dev/null; then
  echo "  раскладка записана"
else
  echo "  ВНИМАНИЕ: Finder не отозвался (нет разрешения «Автоматизация»?) — DMG без раскладки"
fi
rm -f dist/dmg-layout.applescript

sync
hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet
hdiutil convert "$RWDMG" -format UDZO -o "$DMG" -quiet
rm -f "$RWDMG"

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
  step "Подпись, нотаризация и степлер DMG"
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
  xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi

# --- Обновление: подпись архива и запись в appcast ---------------------------

# Архив к этому моменту уже пересобран со степлером внутри (см. блок нотаризации):
# подписывать надо именно его, иначе длина и подпись разойдутся с тем, что уедет в релиз.
step "Подпись архива для Sparkle"
SIGN_UPDATE=$(sparkle_tool sign_update)
[ -n "$SIGN_UPDATE" ] && [ -x "$SIGN_UPDATE" ] || fail "не нашёл утилиту sign_update.
  Подтяните зависимости (swift package resolve) или укажите папку: SPARKLE_BIN=/путь/к/bin"

# sign_update печатает готовую пару атрибутов: sparkle:edSignature="…" length="…".
# Её и вставляем в <enclosure> целиком — разбирать и собирать обратно незачем.
ENCLOSURE_ATTRS=$(sign_update_run "$ZIP")
printf '  %s\n' "$ENCLOSURE_ATTRS"

# Заметки к выпуску → HTML для <description>: Sparkle показывает его как разметку.
# Понимаем ровно то, чем пишут заметки: заголовки, списки и абзацы.
NOTES_HTML=$(awk '
  /\]\]>/ { print "ОШИБКА: в заметках есть ]]> — CDATA такое не переживёт" > "/dev/stderr"; exit 1 }
  /^[[:space:]]*$/ { if (list) { print "</ul>"; list = 0 } ; next }
  /^#+[[:space:]]/ {
    if (list) { print "</ul>"; list = 0 }
    sub(/^#+[[:space:]]*/, "")
    print "<h3>" $0 "</h3>"; next
  }
  /^[-*][[:space:]]/ {
    if (!list) { print "<ul>"; list = 1 }
    sub(/^[-*][[:space:]]*/, "")
    print "<li>" $0 "</li>"; next
  }
  { if (list) { print "</ul>"; list = 0 } ; print "<p>" $0 "</p>" }
  END { if (list) print "</ul>" }
' "$NOTES")

# Дата в формате RFC 822 — его ждёт RSS. Локаль сбрасываем: месяц и день должны быть
# английскими независимо от системных настроек.
PUB_DATE=$(LC_ALL=C date "+%a, %d %b %Y %H:%M:%S %z")

ITEM=$(cat <<XML
    <item>
      <title>$VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
$NOTES_HTML
      ]]></description>
      <enclosure url="$RELEASE_URL/$(basename "$ZIP")"
                 type="application/octet-stream"
                 $ENCLOSURE_ATTRS />
    </item>
XML
)

if [ "$SKIP_NOTARIZE" -eq 1 ]; then
  step "Сухой прогон: appcast.xml не трогаем"
  printf '%s\n' "$ITEM"
else
  step "Запись выпуска в $APPCAST"
  # Вставляем перед якорем: свежий выпуск оказывается первым в ленте.
  # Через файл, а не через -v: awk на macOS многострочное значение переменной не принимает.
  printf '%s\n' "$ITEM" > dist/appcast-item.xml
  awk -v itemfile=dist/appcast-item.xml -v anchor="$ANCHOR" '
    index($0, anchor) {
      while ((getline line < itemfile) > 0) print line
      close(itemfile)
    }
    { print }
  ' "$APPCAST" > "$APPCAST.new"
  mv "$APPCAST.new" "$APPCAST"
  rm -f dist/appcast-item.xml
  echo "  добавлен выпуск $VERSION (сборка $BUILD)"
fi

# --- Итог --------------------------------------------------------------------

step "Готово"
ls -lh "$ZIP" "$DMG" | awk '{ print "  " $9 "  " $5 }'
shasum -a 256 "$ZIP" "$DMG"
if [ "$SKIP_NOTARIZE" -eq 1 ]; then
  echo
  echo "ВНИМАНИЕ: сборка не нотаризована — для раздачи пользователям она не годится."
else
  cat <<NEXT

Дальше — руками (см. docs/releasing.md):
  1. Создать на GitHub релиз с тегом v$VERSION и приложить ОБА файла:
       $DMG
       $ZIP
     Имя zip менять нельзя: на него уже ссылается appcast.xml.
  2. Закоммитить и запушить appcast.xml в main — только после того, как файлы
     в релизе доступны по ссылке. Пуш appcast'а и есть выкладка обновления.
NEXT
fi
