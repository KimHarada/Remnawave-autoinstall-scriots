#!/usr/bin/env bash
# УСТАРЕЛ. Раньше здесь была отдельная настройка SSH/ufw/fail2ban без проверок.
# Всё это теперь делает full-setup.sh (с откатом смены порта, проверкой результата
# каждого этапа и итоговой перепроверкой). Файл оставлен, чтобы старые команды
# с этим адресом продолжали работать.
set -uo pipefail
RAW="${DORIK_RAW:-https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main}"
echo "▲ harden-ssh.sh устарел — запускаю актуальную «Полную настройку» (full-setup.sh)."
tmp="$(mktemp)"
curl -fsSL --retry 3 "${RAW}/menu.sh" -o "$tmp" || { echo "✖ Не удалось скачать menu.sh" >&2; exit 1; }
exec bash "$tmp" --full
