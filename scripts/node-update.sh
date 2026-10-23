#!/usr/bin/env bash
# DORIK toolkit — обновление ноды Remnawave (образ remnawave/node: Xray + агент).
# Скачивает свежий образ; если он изменился — пересоздаёт контейнер и проверяет
# результат. Если образ тот же — ничего не трогает (FORCE=1 — пересоздать всё равно).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW="${DORIK_RAW:-https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main}"
source "${SCRIPT_DIR}/lib.sh" 2>/dev/null || {
  t=$(mktemp); curl -fsSL --retry 3 "${RAW}/scripts/lib.sh" -o "$t" && source "$t"
} || { echo "Не удалось загрузить lib.sh" >&2; exit 1; }
_dorik_source state.sh
require_root

step "Обновление ноды Remnawave"

if ! command -v docker &>/dev/null || [ ! -f "$NODE_DIR/docker-compose.yml" ]; then
  err "Нода не найдена в ${NODE_DIR}. Сначала установите её («Полная настройка» или «Только Remnanode»)."
  exit 1
fi

node_port() { grep -oE 'NODE_PORT=[0-9]+' "$NODE_DIR/docker-compose.yml" | head -1 | cut -d= -f2; }
xray_ver()  { timeout 3 docker exec remnanode xray version 2>/dev/null | head -1 | awk '{print $1" "$2}'; }
img_id()    { docker inspect -f '{{.Image}}' remnanode 2>/dev/null | cut -c8-19; }

cd "$NODE_DIR" || exit 1

OLD_ID="$(img_id)"
OLD_XRAY="$(xray_ver)"
if [ -n "$OLD_ID" ]; then
  info "Сейчас: образ ${OLD_ID}${OLD_XRAY:+, ${OLD_XRAY}}"
else
  warn "Контейнер remnanode не запущен — будет запущен после загрузки образа."
fi

# Образ, на который ссылается compose, и его id до/после pull.
IMAGE="$(grep -E '^[[:space:]]*image:' docker-compose.yml | head -1 | awk '{print $2}')"
BEFORE_IMG="$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null)"
spin_run "Загрузка образа ${IMAGE}" docker compose pull || { err "Не удалось загрузить образ."; exit 1; }
AFTER_IMG="$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null)"

RUNNING_ID="$(docker inspect -f '{{.Image}}' remnanode 2>/dev/null)"
if [ -n "$RUNNING_ID" ] && [ "$RUNNING_ID" = "$AFTER_IMG" ] && [ "${FORCE:-0}" != "1" ]; then
  ok "Нода уже на последней версии — пересоздание не требуется."
  docker image prune -f &>/dev/null || true
  exit 0
fi

cp -f docker-compose.yml "docker-compose.yml.bak.$(date +%s)"
[ "$BEFORE_IMG" != "$AFTER_IMG" ] && info "Вышел новый образ — обновляю."
spin_run "Пересоздание контейнера remnanode" docker compose up -d --force-recreate \
  || { err "docker compose up не удался: docker compose logs"; exit 1; }

PORT="$(node_port)"
wait_node() {
  local _
  for _ in $(seq 1 15); do
    container_running remnanode && ss -tln 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]" && return 0
    sleep 2
  done
  return 1
}

step "Проверка результата"
VERIFY_FAIL=0
if [ -n "$PORT" ]; then
  spin_run "Ожидание порта ноды ${PORT}" wait_node 2>/dev/null
  rc=$?
  [ $rc -eq 0 ]; _chk $? "нода работает и слушает порт ${PORT}" "нода не поднялась на порту ${PORT} — смотрите: docker logs remnanode --tail 30"
else
  container_running remnanode; _chk $? "контейнер remnanode работает" "контейнер remnanode не работает"
fi
docker logs remnanode --tail 10 2>&1 | grep -qi "Environment Configuration Errors"
[ $? -ne 0 ]; _chk $? "в логах нет ошибок конфигурации" "в логах ошибка конфигурации окружения (проверьте SECRET_KEY/NODE_PORT)"

NEW_ID="$(img_id)"; NEW_XRAY="$(xray_ver)"
echo
box_top "Нода обновлена"
box_row "Образ:  ${OLD_ID:-—} → ${C_BOLD}${NEW_ID:-—}${C_RESET}"
[ -n "$NEW_XRAY" ] && box_row "Xray:   ${OLD_XRAY:-—} → ${C_BOLD}${NEW_XRAY}${C_RESET}"
box_bottom
docker image prune -f &>/dev/null || true

[ "$VERIFY_FAIL" -eq 0 ]
