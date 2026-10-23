#!/usr/bin/env bash
# УСТАРЕЛ. Раньше здесь была защита сервера панели (ufw: SSH+80+443, fail2ban) без
# проверок. Теперь это роль «Только сервер панели» в full-setup.sh (с откатом смены
# порта, проверкой каждого этапа и итоговой перепроверкой). Файл оставлен, чтобы
# старые команды с этим адресом продолжали работать.
set -uo pipefail
RAW="${DORIK_RAW:-https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main}"
echo "▲ panel-protect.sh устарел — запускаю «Полную настройку» в роли «сервер панели»."
tmp="$(mktemp)"
curl -fsSL --retry 3 "${RAW}/menu.sh" -o "$tmp" || { echo "✖ Не удалось скачать menu.sh" >&2; exit 1; }
ROLE=2 exec bash "$tmp" --full
