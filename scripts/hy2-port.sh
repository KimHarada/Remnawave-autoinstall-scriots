#!/usr/bin/env bash
# DORIK toolkit — смена UDP-порта Hysteria2 на уже настроенной ноде.
#
#   hy2-port.sh          — выбрать порт: 443, случайный, свой
#   hy2-port.sh show     — показать текущий порт
#
# Что делает: запоминает порт (/etc/dorik/hy2-port), переносит правило firewall (старое правило
# Hysteria2 убирается), а затем предлагает обновить inbound и хост Hysteria2 на панели по API.
# Без этого последнего шага клиенты и нода продолжат работать на ПРЕЖНЕМ порту — меняется он
# только вместе с профилем на панели. Без вопросов: ASSUME_YES=1 HY2_PORT=20152.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW="${DORIK_RAW:-https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh" 2>/dev/null || {
  t=$(mktemp); curl -fsSL --retry 3 "${RAW}/scripts/lib.sh" -o "$t" && source "$t"
} || { echo "Не удалось загрузить lib.sh" >&2; exit 1; }
_dorik_source state.sh

require_root

if [ "${1:-}" = "show" ]; then
  echo "UDP-порт Hysteria2: $(hy2_port)"
  exit 0
fi

ensure_tty
banner

cur="$(hy2_port)"
if ! grep -qs '/etc/hysteria' "${NODE_DIR}/docker-compose.yml" && [ ! -s /etc/dorik/profile.json ]; then
  warn "Hysteria2 на этом сервере не настраивался — порт запомню, он понадобится при настройке."
fi
info "Сейчас UDP-порт Hysteria2: ${cur}"

hy2_port_pick || { info "Отменено."; exit 0; }
new="$HY2_PORT"
if [ "$new" = "$cur" ]; then ok "Порт не изменился (${cur})."; exit 0; fi
hy2_port_save "$new"
ok "Новый порт Hysteria2: ${new} (UDP)"

# Firewall: прежнее правило Hysteria2 убираем, новый порт открываем.
if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw_delete_matching 'Hysteria2'
  ufw allow "${new}/udp" comment "Hysteria2" &>/dev/null || true
  if _ufw_open "${new}/udp"; then ok "firewall: ${new}/udp открыт, прежнее правило Hysteria2 убрано"
  else err "firewall: правило для ${new}/udp не появилось — проверьте: ufw status"; fi
else
  warn "ufw не активен — правило firewall не менял (откройте ${new}/udp сами, если используете другой firewall)."
fi

# Профиль на панели: inbound и хост Hysteria2 должны получить тот же порт.
if grep -qs '"hy2"' /etc/dorik/profile.json 2>/dev/null; then
  echo
  info "Профиль на панели создан этим тулкитом: порт нужно сменить и там, иначе нода останется на ${cur}."
  if ask_yes_no "Обновить inbound и хост Hysteria2 на панели сейчас (понадобятся адрес панели и API-токен)?" "1"; then
    have jq || apt_install jq || true
    PROFILE_PREFIX="$(jq -r '.prefix // empty' /etc/dorik/profile.json 2>/dev/null)"
    PROFILE_NAME="$(jq -r '.name // empty' /etc/dorik/profile.json 2>/dev/null)"
    export PROFILE_PREFIX PROFILE_NAME HY2_PORT="$new"
    PROFILE_CREATE_NODE=0 FINAL_MASK="${FINAL_MASK:-0}" bash "${SCRIPT_DIR}/profile-setup.sh"
  else
    warn "Порт на панели не менялся. Вручную: Профили → inbound Hysteria2 → port ${new}; Хосты → Hysteria2 → порт ${new}."
  fi
else
  warn "Профиль на панели этим тулкитом не создавался. Вручную: у inbound Hysteria2 порт ${new}; у хоста Hysteria2 порт ${new}."
fi

echo
box_top "Готово"
box_row "Порт Hysteria2: ${C_BOLD}${new}/udp${C_RESET}"
box_wrap "${C_DIM}→${C_RESET}" "Клиентам нужно обновить подписку: адрес хоста Hysteria2 теперь с портом ${new}."
box_bottom
