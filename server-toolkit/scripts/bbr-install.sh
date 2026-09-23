#!/usr/bin/env bash
# Включение BBR через штатные средства ядра (modprobe + sysctl).
# ВАЖНО: раньше здесь было curl|bash стороннего скрипта
# (ivan-nginx/bbr3/optimize_network.sh) — от рута, без какого-либо контроля
# над тем, что он делает. Это убрано целиком: слепое исполнение чужого кода
# из интернета от root — неприемлемый риск само по себе, а на практике это
# и оказалось причиной падения сервера (истощение таблицы процессов,
# "fork: Resource temporarily unavailable" на чистом Ubuntu, ровно на этом
# шаге пайплайна). Обычный BBR даёт почти весь прирост по сравнению с BBR3
# для типичного VPS-трафика и не требует стороннего кода вообще.
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
    ask_yes_no "Переустановить BBR всё равно?" "2" || exit 0
  else
    exit 0
  fi
fi

step "Включение BBR"

modprobe tcp_bbr 2>/dev/null || true
if [ ! -f "/lib/modules/$(uname -r)/kernel/net/ipv4/tcp_bbr.ko" ] && \
   [ ! -f "/lib/modules/$(uname -r)/kernel/net/ipv4/tcp_bbr.ko.zst" ]; then
  info "Модуль tcp_bbr не найден в текущем ядре, пробую поставить linux-modules-extra."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "linux-modules-extra-$(uname -r)" 2>&1 | tail -5 || true
  modprobe tcp_bbr 2>/dev/null || true
fi

cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system &>/dev/null || true

FINAL=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
if [[ "$FINAL" == bbr* ]]; then
  ok "BBR активирован: ${FINAL}"
else
  err "Не удалось включить BBR — модуль tcp_bbr недоступен на этом ядре. Проверьте: modprobe tcp_bbr; uname -r"
  exit 1
fi
