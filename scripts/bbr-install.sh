#!/usr/bin/env bash
# Включение BBR + сетевая оптимизация ноды через штатные средства ядра
# (modprobe + sysctl). Никакого стороннего кода из интернета: раньше здесь был
# curl|bash чужого скрипта от root — он оказался причиной падения сервера
# (исчерпание таблицы процессов на чистой Ubuntu) и убран целиком.
#
# Скрипт идемпотентен: повторный запуск ничего не ломает и всегда приводит
# настройки к описанным ниже (раньше при уже включённом BBR он просто выходил).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW="${DORIK_RAW:-https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main}"
source "${SCRIPT_DIR}/lib.sh" 2>/dev/null || {
  t=$(mktemp); curl -fsSL --retry 3 "${RAW}/scripts/lib.sh" -o "$t" && source "$t"
} || { echo "Не удалось загрузить lib.sh" >&2; exit 1; }
require_root

step "Включение BBR"

modprobe tcp_bbr 2>/dev/null || true
if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
  info "Модуль tcp_bbr недоступен в текущем ядре, пробую поставить linux-modules-extra."
  apt_install "linux-modules-extra-$(uname -r)" || true
  modprobe tcp_bbr 2>/dev/null || true
fi

if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
  err "BBR недоступен на этом ядре ($(uname -r)). Проверьте: modprobe tcp_bbr; uname -r"
  exit 1
fi

# Модуль подгружается при каждой загрузке системы, чтобы sysctl с bbr
# применился гарантированно (на сервере с ежедневным ребутом это важно).
echo "tcp_bbr" > /etc/modules-load.d/dorik-bbr.conf

cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

step "Сетевая оптимизация (прокси-нода: много соединений, TCP+QUIC)"
cat > /etc/sysctl.d/99-dorik-net.conf <<'EOF'
# Очередь входящих соединений и backlog сетевой карты
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192

# Буферы сокетов. UDP-буферы особенно важны для Hysteria2/QUIC:
# при маленьких rmem_max/wmem_max скорость режется и появляются потери.
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432

# Быстрее установка соединений и без «просадки» скорости после простоя
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1

# Исходящие соединения: больше портов, быстрее освобождение
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30

# Раньше замечаем «мёртвых» клиентов
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

fs.file-max = 2097152
EOF

# Лимит открытых файлов для служб (nginx/haproxy/docker): по умолчанию soft
# лимит 1024 — на ноде с тысячами соединений его не хватает. Применится
# при следующей загрузке (или systemctl daemon-reexec).
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-dorik-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=65535:1048576
EOF

BAD=0
for f in /etc/sysctl.d/99-bbr.conf /etc/sysctl.d/99-dorik-net.conf; do
  # Ядро/контейнер может не знать отдельных ключей — это не повод падать,
  # но показываем, какие именно не применились.
  OUT=$(sysctl -p "$f" 2>&1 >/dev/null) || true
  if [ -n "$OUT" ]; then
    warn "$(basename "$f"): часть параметров не применилась:"
    echo "$OUT" | head -n 5 >&2
    BAD=1
  fi
done

FINAL=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)
if [[ "$FINAL" == bbr* ]]; then
  ok "BBR активен: congestion_control=${FINAL}, qdisc=${QDISC}"
else
  err "Не удалось включить BBR (сейчас: ${FINAL})."
  exit 1
fi
[ "$BAD" = "0" ] && ok "Сетевые параметры применены."
exit 0
