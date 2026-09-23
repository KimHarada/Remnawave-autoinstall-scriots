#!/usr/bin/env bash
# BBR3 (ivan-nginx/bbr3), с определением "скрипт сам перезагрузился" и
# fallback на обычный bbr, если bbr3-модуль недоступен на ядре.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh" 2>/dev/null || {
  RAW="https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main"
  t=$(mktemp); curl -fsSL "${RAW}/scripts/lib.sh" -o "$t"; source "$t"
}
require_root

CUR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
if [[ "$CUR" == bbr* ]]; then
  ok "BBR уже активен (${CUR})."
  if [ "${NONINTERACTIVE:-0}" != "1" ]; then
    ask_yes_no "Переустановить BBR3 всё равно?" "2" || exit 0
  else
    exit 0
  fi
fi

step "Установка BBR3 (ivan-nginx/bbr3)"
LOG=$(mktemp)
curl -fsSL https://raw.githubusercontent.com/ivan-nginx/bbr3/main/optimize_network.sh 2>/dev/null | tee "$LOG" | bash || true

if grep -qi "rebooting" "$LOG"; then
  warn "Установщик BBR3 сам инициировал перезагрузку сервера."
  warn "Подождите 30-60 секунд и переподключитесь — BBR3 будет активен после ребута."
  exit 0
fi

NEW=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
if [[ "$NEW" == bbr* ]]; then
  ok "BBR активирован: ${NEW}"
  exit 0
fi

warn "BBR всё ещё не активен (${NEW}), пробую диагностику..."
modprobe tcp_bbr 2>/dev/null || true
if [ ! -f "/lib/modules/$(uname -r)/kernel/net/ipv4/tcp_bbr.ko" ] && \
   [ ! -f "/lib/modules/$(uname -r)/kernel/net/ipv4/tcp_bbr.ko.zst" ]; then
  warn "Модуль tcp_bbr отсутствует в текущем ядре, пробую установить linux-modules-extra."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "linux-modules-extra-$(uname -r)" 2>&1 | tail -5 || true
  modprobe tcp_bbr 2>/dev/null || true
fi

NEW2=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
if [[ "$NEW2" == bbr* ]]; then
  ok "BBR активирован после modprobe: ${NEW2}"
else
  warn "BBR3 недоступен на этом ядре — включаю обычный BBR (fallback)."
  cat > /etc/sysctl.d/99-bbr-fallback.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system &>/dev/null || true
  FINAL=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
  if [[ "$FINAL" == bbr* ]]; then
    ok "Обычный BBR активирован: ${FINAL}"
  else
    err "Не удалось включить BBR даже в fallback-режиме."
    exit 1
  fi
fi
