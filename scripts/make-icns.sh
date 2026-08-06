#!/bin/bash
#
# Собирает Resources/AppIcon.icns из исходного рисунка Resources/AppIcon-source.png.
# Запускается вручную, когда рисунок меняется, — сборка приложения готовый .icns просто копирует.
#
#   bash scripts/make-icns.sh
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="Resources/AppIcon-source.png"
OUT="Resources/AppIcon.icns"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$SOURCE" ] || { printf 'ОШИБКА: нет исходника %s\n' "$SOURCE" >&2; exit 1; }

# Скруглённый квадрат с полями — из исходника 1:1, без правки самого рисунка.
swift scripts/make-icon.swift "$SOURCE" "$WORK/icon-1024.png" >/dev/null

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

# Набор, который ждёт iconutil: каждый размер в обычном и удвоенном разрешении.
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$WORK/icon-1024.png" \
    --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" "$WORK/icon-1024.png" \
    --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil --convert icns "$ICONSET" --output "$OUT"
printf 'OK: %s (%s)\n' "$OUT" "$(du -h "$OUT" | cut -f1)"
