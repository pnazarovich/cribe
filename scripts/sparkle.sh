#!/bin/bash
# Sparkle внутри бандла: общая часть для build-app.sh и release.sh.
#
# Зачем это отдельным файлом. У Sparkle install name — `@rpath/Sparkle.framework/Versions/B/Sparkle`,
# то есть фреймворк ОБЯЗАН лежать в `Contents/Frameworks` самого приложения, а бандл мы
# собираем руками: xcodebuild кладёт продукты в свою папку и про наш `dist/Cribe.app`
# ничего не знает. Само оно туда не попадёт — значит, кладём и прописываем rpath здесь.
#
# Второе: внутри Sparkle.framework лежит своя вложенная программа — `Autoupdate`,
# `Updater.app` и два XPC-сервиса. Подпись приложения запечатывает фреймворк как ресурс,
# поэтому подписывать надо ИЗНУТРИ НАРУЖУ: сервисы → Autoupdate → Updater.app → сам
# фреймворк → и только потом .app. Обратный порядок ломает и Gatekeeper, и нотаризацию.
#
# XPC-сервисы Sparkle мы не включаем (`SUEnableInstallerLauncherService` и соседи в
# Info.plist отсутствуют) — они нужны приложениям в песочнице, а это приложение не в ней.
# Но внутри фреймворка они лежат всё равно, и подписать их надо: неподписанный вложенный
# код заворачивает нотаризация.

# Путь к утилите Sparkle (sign_update, generate_keys, …). Они приезжают вместе с
# xcframework и лежат в артефактах SwiftPM. SPARKLE_BIN перебивает поиск.
# Из выдачи исключается bin/old_dsa_scripts — там одноимённые утилиты для старых DSA-ключей.
sparkle_tool() {
  local name="$1"
  if [ -n "${SPARKLE_BIN:-}" ]; then
    printf '%s' "$SPARKLE_BIN/$name"
    return
  fi
  # `|| true`: одной из папок может не быть, а под `set -e` ненулевой код find уронил бы
  # весь скрипт молча — прямо на присваивании результата.
  find .ddata/SourcePackages/artifacts .build/artifacts \
    -maxdepth 5 -type f -path "*/bin/$name" -print -quit 2>/dev/null || true
}

# Путь к Sparkle.framework, который собрал xcodebuild. Сначала — папка продуктов,
# потом — срез xcframework из артефактов SwiftPM (там фреймворк лежит всегда).
sparkle_framework_path() {
  local found
  found=$(find .ddata/Build/Products -maxdepth 3 -name Sparkle.framework -print -quit 2>/dev/null || true)
  if [ -n "$found" ]; then
    printf '%s' "$found"
    return
  fi
  # Срез выбираем по имени папки: сборка идёт под arm64.
  found=$(find .ddata/SourcePackages/artifacts .build/artifacts \
    -maxdepth 6 -path '*Sparkle.xcframework/*arm64*/Sparkle.framework' -print -quit 2>/dev/null || true)
  printf '%s' "$found"
}

# Положить фреймворк в бандл и прописать до него путь поиска.
embed_sparkle() {
  local app="$1" framework
  framework=$(sparkle_framework_path)
  if [ -z "$framework" ]; then
    printf 'ОШИБКА: не нашёл Sparkle.framework после сборки.\n' >&2
    printf '        Проверьте, что зависимость Sparkle разрешилась: swift package resolve\n' >&2
    return 1
  fi
  mkdir -p "$app/Contents/Frameworks"
  rm -rf "$app/Contents/Frameworks/Sparkle.framework"
  # ditto, а не cp: бандл с симлинками версий и подписью копируется как есть.
  ditto "$framework" "$app/Contents/Frameworks/Sparkle.framework"

  # Свой rpath xcodebuild исполняемому файлу SwiftPM-цели не обещает, а второй такой же
  # записи dyld не прощает — поэтому сначала смотрим, нет ли её уже.
  local binary="$app/Contents/MacOS/Cribe"
  if ! otool -l "$binary" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath @executable_path/../Frameworks "$binary"
  fi
  printf 'Sparkle: %s → Contents/Frameworks\n' "$framework"
}

# Подписать вложенный код Sparkle. Зовётся ДО подписи .app.
#   $1 — бандл приложения, $2 — личность подписи, $3 — флаг метки времени.
sign_sparkle() {
  local app="$1" identity="$2" timestamp_flag="$3"
  local sparkle="$app/Contents/Frameworks/Sparkle.framework"
  [ -d "$sparkle" ] || { printf 'ОШИБКА: в бандле нет Sparkle.framework\n' >&2; return 1; }

  # Версия у фреймворка — B (не A): так его собирает Sparkle 2.
  local versions="$sparkle/Versions/B"
  local nested=(
    "$versions/XPCServices/Downloader.xpc"
    "$versions/XPCServices/Installer.xpc"
    "$versions/Autoupdate"
    "$versions/Updater.app"
    "$versions"
  )
  # Свои entitlements вложенному коду не даём: keychain-access-groups нужен приложению,
  # а не обновлятору, и лишнее право в подписи — лишний повод для отказа при нотаризации.
  local target
  for target in "${nested[@]}"; do
    [ -e "$target" ] || { printf 'ОШИБКА: не найдено %s\n' "$target" >&2; return 1; }
    codesign --force --options runtime "$timestamp_flag" --sign "$identity" "$target"
  done
}
