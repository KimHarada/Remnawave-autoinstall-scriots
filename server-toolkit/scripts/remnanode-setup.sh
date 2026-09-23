#!/usr/bin/env bash
# Устанавливает remnanode (Docker). Если NONINTERACTIVE=1 — берёт параметры
# из переменных окружения (NODE_PORT, USE_HY2) и не задаёт вопросов,
# т.к. это вызвано из full-setup.sh, где всё уже спрошено один раз.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh" 2>/dev/null || {
  RAW="https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main"
  t=$(mktemp); curl -fsSL "${RAW}/scripts/lib.sh" -o "$t"; source "$t"
}
require_root

NONINTERACTIVE="${NONINTERACTIVE:-0}"

if ! command -v docker &>/dev/null; then
  step "Установка Docker"
  curl -fsSL https://get.docker.com | sh
fi

INSTALL_DIR="/opt/remnanode"
if [ "$NONINTERACTIVE" != "1" ]; then
  INSTALL_DIR=$(ask_value "Директория установки" "/opt/remnanode")
  NODE_PORT=$(ask_value "NODE_PORT" "2222")
  SECRET_KEY_RAW=$(ask_value "SECRET_KEY (из панели)" "")
  if ask_yes_no "Будем использовать Hysteria2 на этой ноде?" "1"; then USE_HY2=1; else USE_HY2=0; fi
else
  SECRET_KEY_RAW="${SECRET_KEY:-}"
  NODE_PORT="${NODE_PORT:-2222}"
  USE_HY2="${USE_HY2:-0}"
  if [ -z "$SECRET_KEY_RAW" ]; then
    SECRET_KEY_RAW=$(ask_value "SECRET_KEY (из панели)" "")
  fi
fi

# Убираем случайные кавычки/переводы строк — частая причина "Invalid SECRET_KEY payload"
SECRET_KEY=$(echo -n "$SECRET_KEY_RAW" | sed -E 's/^"+//; s/"+$//' | tr -d '\r\n')

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

CERT_LINE=""
VOLUME_LINES=""
if [ "$USE_HY2" = "1" ]; then
  step "Поиск существующего сертификата Let's Encrypt для Hysteria2"
  mapfile -t CERTS < <(find /etc/letsencrypt/live -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
  CERT_DOMAIN=""
  if [ "${#CERTS[@]}" -eq 1 ]; then
    CERT_DOMAIN=$(basename "${CERTS[0]}")
  elif [ "${#CERTS[@]}" -gt 1 ]; then
    if [ "$NONINTERACTIVE" = "1" ]; then
      CERT_DOMAIN=$(basename "${CERTS[0]}")
    else
      echo "Найдено несколько сертификатов:"
      select d in "${CERTS[@]##*/}"; do CERT_DOMAIN="$d"; break; done
    fi
  fi
  if [ -z "$CERT_DOMAIN" ]; then
    warn "Сертификат не найден автоматически — Hysteria2 volume не будет добавлен, добавьте вручную позже."
    USE_HY2=0
  else
    ok "Использую сертификат: ${CERT_DOMAIN}"
    VOLUME_LINES="      - /etc/letsencrypt/live/${CERT_DOMAIN}/fullchain.pem:/etc/hysteria/fullchain.pem:ro
      - /etc/letsencrypt/live/${CERT_DOMAIN}/privkey.pem:/etc/hysteria/privkey.pem:ro"
  fi
fi

cat > docker-compose.yml <<EOF
services:
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    restart: always
    network_mode: host
    environment:
      - SECRET_KEY=${SECRET_KEY}
      - NODE_PORT=${NODE_PORT}
EOF

if [ -n "$VOLUME_LINES" ]; then
  cat >> docker-compose.yml <<EOF
    volumes:
${VOLUME_LINES}
EOF
fi

step "Проверка docker-compose.yml"
if ! docker compose config &>/dev/null; then
  err "docker-compose.yml не валиден, останавливаюсь."
  exit 1
fi
ok "Конфигурация валидна."

step "Запуск remnanode"
docker compose up -d

sleep 3
if docker compose ps | grep -q "Up"; then
  ok "Контейнер запущен."
else
  err "Контейнер не поднялся, смотрите: docker compose logs"
  exit 1
fi

if ss -tlnp 2>/dev/null | grep -q ":${NODE_PORT} "; then
  ok "Порт ноды ${NODE_PORT} слушает."
else
  warn "Порт ${NODE_PORT} не слушается — проверьте конфигурацию в панели."
fi

if [ "$USE_HY2" = "1" ]; then
  if docker exec remnanode test -f /etc/hysteria/fullchain.pem 2>/dev/null; then
    ok "Сертификат Hysteria2 виден внутри контейнера."
  else
    warn "Сертификат Hysteria2 не найден внутри контейнера — проверьте volumes."
  fi
fi

ok "Remnanode установлен."
