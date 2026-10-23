#!/usr/bin/env bash
# Устанавливает remnanode (Docker). Если NONINTERACTIVE=1 — берёт параметры
# из переменных окружения (NODE_PORT, USE_HY2, SECRET_KEY) и не задаёт
# вопросов, т.к. это вызвано из full-setup.sh, где всё уже спрошено один раз.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW="${DORIK_RAW:-https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main}"
source "${SCRIPT_DIR}/lib.sh" 2>/dev/null || {
  t=$(mktemp); curl -fsSL --retry 3 "${RAW}/scripts/lib.sh" -o "$t" && source "$t"
} || { echo "Не удалось загрузить lib.sh" >&2; exit 1; }
require_root
require_apt_os

NONINTERACTIVE="${NONINTERACTIVE:-${ASSUME_YES:-0}}"
[ "$NONINTERACTIVE" != "1" ] && ensure_tty

# ---- Docker -----------------------------------------------------------------
if ! command -v docker &>/dev/null; then
  step "Установка Docker"
  apt_update || true
  apt_install curl ca-certificates || true
  for attempt in 1 2 3; do
    wait_for_apt_lock
    curl -fsSL --retry 3 https://get.docker.com | sh && break
    warn "Установка Docker не удалась (попытка ${attempt}/3), повторяю..."
    fix_dpkg_state
    sleep 10
  done
  if ! command -v docker &>/dev/null; then
    err "Docker не установился — дальше этот скрипт работать не будет."
    exit 1
  fi
fi
systemctl enable --now docker &>/dev/null || true
if ! docker compose version &>/dev/null; then
  step "Установка docker compose plugin"
  apt_install docker-compose-plugin || true
  if ! docker compose version &>/dev/null; then
    err "docker compose недоступен — установите docker-compose-plugin вручную."
    exit 1
  fi
fi

INSTALL_DIR="/opt/remnanode"
if [ "$NONINTERACTIVE" != "1" ]; then
  INSTALL_DIR=$(ask_value "Директория установки" "/opt/remnanode")
fi
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR" || exit 1

EXISTING_COMPOSE=0
[ -f docker-compose.yml ] && EXISTING_COMPOSE=1

# Достаём SECRET_KEY/NODE_PORT из уже существующего compose (если он есть),
# чтобы этот скрипт можно было безопасно перезапускать сам по себе —
# например, только чтобы дописать Hysteria2 volume, когда сертификат
# появился позже — без необходимости заново вставлять SECRET_KEY.
OLD_SECRET_KEY=""
OLD_NODE_PORT=""
OLD_HY2_DOMAIN=""
if [ "$EXISTING_COMPOSE" = "1" ]; then
  OLD_SECRET_KEY=$(grep -oE 'SECRET_KEY=.*' docker-compose.yml | head -1 | sed 's/SECRET_KEY=//; s/^"//; s/"$//')
  OLD_NODE_PORT=$(grep -oE 'NODE_PORT=.*' docker-compose.yml | head -1 | sed 's/NODE_PORT=//')
  OLD_HY2_DOMAIN=$(grep -oE '/etc/letsencrypt/live/[^/]+/fullchain.pem:/etc/hysteria' docker-compose.yml \
    | head -1 | sed -E 's#.*live/([^/]+)/fullchain.*#\1#')
fi

if [ "$NONINTERACTIVE" != "1" ]; then
  NODE_PORT=$(ask_valid "NODE_PORT" "${NODE_PORT:-${OLD_NODE_PORT:-$DEFAULT_NODE_PORT}}" is_valid_port) || exit 1
  if [ -n "$OLD_SECRET_KEY" ]; then
    ok "Найден существующий SECRET_KEY в docker-compose.yml — использую его (Enter, чтобы не менять)."
    SECRET_KEY_RAW=$(ask_value "SECRET_KEY (Enter — оставить текущий)" "$OLD_SECRET_KEY")
  else
    SECRET_KEY_RAW=$(ask_value "SECRET_KEY (из панели)" "${SECRET_KEY:-}")
  fi
  if ask_yes_no "Будем использовать Hysteria2 на этой ноде?" "1"; then USE_HY2=1; else USE_HY2=0; fi
else
  SECRET_KEY_RAW="${SECRET_KEY:-$OLD_SECRET_KEY}"
  NODE_PORT="${NODE_PORT:-${OLD_NODE_PORT:-$DEFAULT_NODE_PORT}}"
  USE_HY2="${USE_HY2:-0}"
fi

# Убираем случайные кавычки/переводы строк — частая причина "Invalid SECRET_KEY payload"
SECRET_KEY=$(echo -n "$SECRET_KEY_RAW" | sed -E 's/^"+//; s/"+$//' | tr -d '\r\n')
if [ -z "$SECRET_KEY" ]; then
  err "SECRET_KEY пуст — возьмите его в панели Remnawave (Nodes -> Add node) и запустите снова."
  exit 1
fi
if ! is_valid_port "$NODE_PORT"; then
  err "NODE_PORT '${NODE_PORT}' некорректен."
  exit 1
fi

# ---- поиск сертификата для Hysteria2 --------------------------------------
# Если сертификат для нужного домена уже есть — не трогаем/не перевыпускаем,
# просто используем; если нет вообще ни одного валидного — Hysteria2
# отключаем и явно говорим почему; если он появился после первого запуска —
# подхватываем и дописываем volume при повторном запуске.
VOLUME_LINES=""
if [ "$USE_HY2" = "1" ]; then
  step "Поиск сертификата для Hysteria2"
  CERT_DOMAIN=""
  if [ -n "${DOMAIN_HY2:-}" ] && cert_is_valid "$DOMAIN_HY2"; then
    CERT_DOMAIN="$DOMAIN_HY2"
  elif [ -n "$OLD_HY2_DOMAIN" ] && cert_is_valid "$OLD_HY2_DOMAIN"; then
    # то, что уже было настроено и продолжает быть валидным — не трогаем
    CERT_DOMAIN="$OLD_HY2_DOMAIN"
  else
    mapfile -t CERTS < <(find /etc/letsencrypt/live -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
    for c in "${CERTS[@]}"; do
      d="$(basename "$c")"
      if cert_is_valid "$d"; then CERT_DOMAIN="$d"; break; fi
    done
    if [ -z "$CERT_DOMAIN" ] && [ "$NONINTERACTIVE" != "1" ] && [ "${#CERTS[@]}" -gt 0 ]; then
      echo "Валидных сертификатов не нашлось, но есть эти каталоги — выбрать вручную?"
      select d in "${CERTS[@]##*/}" "Пропустить"; do CERT_DOMAIN="$d"; break; done
      [ "$CERT_DOMAIN" = "Пропустить" ] && CERT_DOMAIN=""
    fi
  fi

  if [ -z "$CERT_DOMAIN" ]; then
    warn "Валидный сертификат не найден — Hysteria2 volume не добавляю. Выпустите сертификат (certbot) и перезапустите этот скрипт — он подхватит его сам, без повторного ввода SECRET_KEY."
    USE_HY2=0
  else
    ok "Сертификат для Hysteria2: ${CERT_DOMAIN} (валиден)."
    VOLUME_LINES="      - /etc/letsencrypt/live/${CERT_DOMAIN}/fullchain.pem:/etc/hysteria/fullchain.pem:ro
      - /etc/letsencrypt/live/${CERT_DOMAIN}/privkey.pem:/etc/hysteria/privkey.pem:ro"
  fi
fi

# ---- сборка нового compose и сравнение со старым ---------------------------
# cap_add NET_ADMIN и ulimits — как в официальном compose Remnawave Node;
# logging ограничивает размер логов (иначе json-лог контейнера растёт без
# предела и со временем забивает диск маленького VPS).
NEW_COMPOSE_CONTENT="services:
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    restart: always
    network_mode: host
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    logging:
      driver: json-file
      options:
        max-size: \"20m\"
        max-file: \"3\"
    environment:
      - SECRET_KEY=${SECRET_KEY}
      - NODE_PORT=${NODE_PORT}"

if [ -n "$VOLUME_LINES" ]; then
  NEW_COMPOSE_CONTENT="${NEW_COMPOSE_CONTENT}
    volumes:
${VOLUME_LINES}"
fi

COMPOSE_CHANGED=1
if [ "$EXISTING_COMPOSE" = "1" ] && diff -q <(echo "$NEW_COMPOSE_CONTENT") docker-compose.yml &>/dev/null; then
  COMPOSE_CHANGED=0
fi

# В compose лежит SECRET_KEY — файл только для root.
umask 077
echo "$NEW_COMPOSE_CONTENT" > docker-compose.yml
chmod 600 docker-compose.yml

step "Проверка docker-compose.yml"
if ! docker compose config &>/dev/null; then
  err "docker-compose.yml не валиден, останавливаюсь."
  exit 1
fi
ok "Конфигурация валидна."

CONTAINER_RUNNING=0
docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null | grep -q true && CONTAINER_RUNNING=1

if [ "$COMPOSE_CHANGED" = "0" ] && [ "$CONTAINER_RUNNING" = "1" ]; then
  ok "Конфигурация не изменилась и контейнер уже работает — не трогаю (без лишнего рестарта)."
else
  if [ "$COMPOSE_CHANGED" = "1" ] && [ "$EXISTING_COMPOSE" = "1" ]; then
    ok "Конфигурация изменилась (например, добавился/пропал Hysteria2 volume) — пересоздаю контейнер."
  fi
  step "Запуск remnanode"
  docker compose pull -q || warn "docker compose pull не удался — пробую запустить с тем, что есть."
  docker compose up -d --force-recreate || { err "docker compose up не удался, смотрите: docker compose logs"; exit 1; }
fi

sleep 3
if docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null | grep -q true; then
  ok "Контейнер запущен."
else
  err "Контейнер не поднялся, смотрите: docker compose logs"
  exit 1
fi

step "Итоговая проверка"
CHECK_FAIL=0

# Нода слушает порт не мгновенно — даём ей до 20 секунд.
LISTEN_OK=0
for _ in $(seq 1 10); do
  if ss -tln 2>/dev/null | grep -qE "[:.]${NODE_PORT}[[:space:]]"; then LISTEN_OK=1; break; fi
  sleep 2
done
if [ "$LISTEN_OK" = "1" ]; then
  ok "Порт ноды ${NODE_PORT}: слушает"
else
  err "Порт ноды ${NODE_PORT}: НЕ слушает — панель не сможет подключиться"
  CHECK_FAIL=1
fi

if [ "$USE_HY2" = "1" ]; then
  if docker exec remnanode test -f /etc/hysteria/fullchain.pem 2>/dev/null; then
    ok "Сертификат Hysteria2 внутри контейнера: на месте"
  else
    err "Сертификат Hysteria2 внутри контейнера: ОТСУТСТВУЕТ"
    CHECK_FAIL=1
  fi
fi

# Явная ошибка конфигурации ("NODE_PORT: Invalid input...") видна в первые
# секунды после старта — если контейнер уже перезапускается по кругу
# (restart: always), логи покажут её прямо тут.
if docker logs remnanode --tail 10 2>&1 | grep -qi "Environment Configuration Errors"; then
  err "В логах remnanode есть ошибка конфигурации окружения — смотрите: docker logs remnanode --tail 30"
  CHECK_FAIL=1
fi

if [ "$CHECK_FAIL" = "1" ]; then
  warn "remnanode-setup.sh завершён С ПРЕДУПРЕЖДЕНИЯМИ — см. [✗] выше."
  exit 1
else
  ok "Remnanode установлен, все проверки пройдены."
fi
