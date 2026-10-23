#!/usr/bin/env bash
# УСТАРЕЛ. Раньше этот файл по очереди запускал haproxy/bbr/remnanode без общей
# проверки окружения и итоговой перепроверки. Теперь это делает full-setup.sh
# (роль «Полноценная нода»). Файл оставлен, чтобы старые команды с этим адресом
# продолжали работать.
set -uo pipefail
RAW="${DORIK_RAW:-https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main}"
echo "▲ full-node-install.sh устарел — запускаю актуальную «Полную настройку» (нода)."
tmp="$(mktemp)"
curl -fsSL --retry 3 "${RAW}/menu.sh" -o "$tmp" || { echo "✖ Не удалось скачать menu.sh" >&2; exit 1; }
ROLE=1 exec bash "$tmp" --full
