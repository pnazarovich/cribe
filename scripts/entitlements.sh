#!/bin/bash
# Общая часть подписи для build-app.sh и release.sh.
#
# `keychain-access-groups` — restricted entitlement: он открывает современную (data protection)
# связку ключей, где доступ к секрету даёт подпись команды разработчика, а не ACL конкретного
# бинарника, — то есть пересборка перестаёт спрашивать пароль от связки. Но без встроенного
# provisioning profile система такое приложение просто не запускает: процесс убивается на старте
# (проверено на этой машине: exit 137, даже с валидным Developer ID).
#
# Поэтому группу оставляем в подписи, только если профиль есть. Профиля нет — группа вырезается,
# приложение спокойно запускается и само уходит на старую связку: SecretStore ловит
# errSecMissingEntitlement и переключается (диалоги пароля при этом остаются).
#
# ГДЕ ВЗЯТЬ ПРОФИЛЬ (разово, на developer.apple.com):
#   1. Certificates, Identifiers & Profiles → Identifiers → App ID
#      `online.nazarovych.transcriber`, включить Keychain Sharing с группой
#      `online.nazarovych.transcriber` (Team ID добавляется системой).
#   2. Profiles → «Developer ID» (macOS, distribution) для этого App ID → скачать.
#   3. Положить файл в корень репозитория как `Transcriber.provisionprofile`
#      (или указать путь в PROVISION_PROFILE) и пересобрать.
#
# Печатает в stdout путь к entitlements-файлу для codesign.
prepare_entitlements() {
  local source="$1" app="$2" identity="$3"
  local profile="${PROVISION_PROFILE:-Transcriber.provisionprofile}"

  if [ "$identity" != "-" ] && [ -f "$profile" ]; then
    # Профиль должен лежать внутри бандла до подписи: codesign запечатывает Contents/.
    cp "$profile" "$app/Contents/embedded.provisionprofile"
    printf '%s' "$source"
    return
  fi

  local trimmed
  trimmed="dist/$(basename "$source" .entitlements)-no-keychain.entitlements"
  cp "$source" "$trimmed"
  /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$trimmed" >/dev/null 2>&1 || true
  if [ "$identity" != "-" ]; then
    printf 'ВНИМАНИЕ: нет %s — подписываем без keychain-access-groups.\n' "$profile" >&2
    printf '         Секреты останутся в старой связке ключей (с диалогами пароля).\n' >&2
    printf '         Как получить профиль — см. scripts/entitlements.sh\n' >&2
  fi
  printf '%s' "$trimmed"
}
