#!/bin/bash
# Запустить утилиту Sparkle из тех, что приезжают вместе с зависимостью.
#
#   bash scripts/sparkle-tool.sh generate_keys            # разовое создание ключа
#   bash scripts/sparkle-tool.sh generate_keys -x key.txt # выгрузить приватный ключ в файл
#   bash scripts/sparkle-tool.sh sign_update -f key.txt dist/Transcriber-0.2.0.zip
#
# Утилиты лежат в артефактах SwiftPM, а их точный путь зависит от того, чем собирали
# (swift build или xcodebuild), — поэтому его ищут, а не пишут руками.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=sparkle.sh
source "scripts/sparkle.sh"

[ $# -ge 1 ] || { printf 'Использование: %s <утилита> [аргументы…]\n' "$0" >&2; exit 1; }

NAME="$1"
shift
TOOL=$(sparkle_tool "$NAME")
if [ -z "$TOOL" ] || [ ! -x "$TOOL" ]; then
  printf 'ОШИБКА: не нашёл утилиту Sparkle «%s».\n' "$NAME" >&2
  printf '        Сначала подтяните зависимости: swift package resolve\n' >&2
  printf '        Утилита лежит не там? Укажите папку: SPARKLE_BIN=/путь/к/bin\n' >&2
  exit 1
fi
exec "$TOOL" "$@"
