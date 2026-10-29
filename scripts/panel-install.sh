#!/usr/bin/env bash
# DORIK toolkit — панель Remnawave и страница подписки: установка и обновление.
#
#   panel-install.sh              — меню
#   panel-install.sh install      — установить панель (+ nginx и сертификат)
#   panel-install.sh update       — обновить панель (с бэкапом БД)
#   panel-install.sh sub          — установить страницу подписки
#   panel-install.sh sub-update   — обновить страницу подписки
#   panel-install.sh status       — состояние и ссылка для входа
#
# Compose и .env.sample берутся из официальных репозиториев Remnawave на момент
# установки/обновления — поэтому новые версии не требуют правки этого скрипта.
# Без вопросов: ASSUME_YES=1 + PANEL_DOMAIN, SUB_DOMAIN, REMNAWAVE_API_TOKEN.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW="${DORIK_RAW:-https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main}"
source "${SCRIPT_DIR}/lib.sh" 2>/dev/null || {
  t=$(mktemp); curl -fsSL --retry 3 "${RAW}/scripts/lib.sh" -o "$t" && source "$t"
} || { echo "Не удалось загрузить lib.sh" >&2; exit 1; }
_dorik_source state.sh
_dorik_source preflight.sh
require_root
require_apt_os

UP_BACKEND="${RW_UPSTREAM_BACKEND:-https://raw.githubusercontent.com/remnawave/backend/main}"
UP_SUB="${RW_UPSTREAM_SUB:-https://raw.githubusercontent.com/remnawave/subscription-page/main}"
PANEL_CONF="$PANEL_DIR/.dorik-panel.conf"
BACKUP_DIR="$PANEL_DIR/backups"
NGX_AV=/etc/nginx/sites-available
NGX_EN=/etc/nginx/sites-enabled

# ---- мелкие помощники ---------------------------------------------------------
rand_hex()  { openssl rand -hex "$1"; }
panel_installed() { [ -f "$PANEL_DIR/docker-compose.yml" ] && [ -f "$PANEL_DIR/.env" ]; }
sub_installed()   { [ -f "$SUB_DIR/docker-compose.yml" ] && [ -f "$SUB_DIR/.env" ]; }

# set_env <файл> <КЛЮЧ> <значение> — заменить KEY=... или дописать, если ключа нет.
# Файл .env из репозитория Remnawave может заканчиваться БЕЗ перевода строки — тогда
# дописанный ключ приклеился бы к последней строке (POSTGRES_DB=postgresKEY=...).
ensure_trailing_newline() { [ -s "$1" ] && [ -n "$(tail -c1 "$1")" ] && printf '\n' >> "$1"; return 0; }

set_env() {
  local f="$1" k="$2" v="$3" esc
  esc="$(printf '%s' "$v" | sed -e 's/[\/&|]/\\&/g')"
  if grep -qE "^${k}=" "$f"; then sed -i -E "s|^${k}=.*|${k}=${esc}|" "$f"
  else ensure_trailing_newline "$f"; printf '%s=%s\n' "$k" "$v" >> "$f"; fi
}
conf_set() { touch "$PANEL_CONF"; chmod 600 "$PANEL_CONF"; set_env "$PANEL_CONF" "$1" "$2"; }
conf_get() { env_get "$PANEL_CONF" "$1"; }

fetch() {  # fetch <url> <файл> — через временный файл, чтобы не затереть рабочий при сбое
  local t; t="$(mktemp)"
  if curl -fsSL --retry 3 "$1" -o "$t" && [ -s "$t" ]; then mv -f "$t" "$2"; return 0; fi
  rm -f "$t"; return 1
}

# Новые параметры из свежего .env.sample, которых ещё нет в .env, — дописываем
# (значения существующих ключей не трогаем).
merge_env_sample() {  # merge_env_sample <sample> <.env>
  local line k
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    k="${line%%=*}"
    grep -qE "^${k}=" "$2" || { ensure_trailing_newline "$2"; echo "$line" >> "$2"; info "в .env добавлен новый параметр ${k}"; }
  done < "$1"
}

keep_last() {  # keep_last <шаблон> <сколько> — оставить N самых новых файлов бэкапа
  # shellcheck disable=SC2012
  ls -1t $1 2>/dev/null | tail -n +"$(($2+1))" | xargs -r rm -f
}

image_id() { docker inspect -f '{{.Image}}' "$1" 2>/dev/null | cut -c8-19; }

compose_in() {  # compose_in <каталог> <args...>
  local d="$1"; shift
  (cd "$d" && docker compose "$@")
}

# ---- TLS + nginx ----------------------------------------------------------------
ensure_cert() {  # ensure_cert <домен>
  local d="$1" acct
  if cert_is_valid "$d"; then ok "Сертификат для ${d} уже есть и валиден."; return 0; fi
  if [ -n "${LE_EMAIL:-}" ]; then acct=(-m "$LE_EMAIL"); else acct=(--register-unsafely-without-email); fi
  # pre/post-хуки сохраняются в конфиге продления: nginx освобождает :80 на время
  # проверки, и автопродление работает без вмешательства.
  spin_run "Выпуск сертификата для ${d}" certbot certonly --standalone --preferred-challenges http \
    --non-interactive --agree-tos "${acct[@]}" -d "$d" \
    --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx" || true
  systemctl start nginx &>/dev/null || true
  cert_is_valid "$d" || return 1
  # Пробное продление (staging): убеждаемся, что автопродление через ~60 дней сработает.
  spin_run "Проверка автопродления для ${d} (dry-run)" certbot renew --dry-run --cert-name "$d" \
    || warn "Автопродление для ${d} может не сработать — проверьте, что порт 80 открыт и DNS верный."
  systemctl start nginx &>/dev/null || true
  return 0
}

nginx_proxy_headers() {
  cat <<'EOF'
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $dorik_conn_upgrade;
        proxy_read_timeout 300s;
EOF
}

write_nginx_panel() {
  local d="$1" protect="$2" key="$3" val="$4" f="$NGX_AV/remnawave-panel"
  {
    cat <<EOF
# Создано DORIK toolkit. Панель Remnawave за nginx.
map \$http_upgrade \$dorik_conn_upgrade { default upgrade; '' close; }
EOF
    if [ "$protect" = "1" ]; then
      # Панель открывается только по секретной ссылке (/?${key}=...): при первом
      # заходе ставится cookie, дальше ссылка не нужна. Остальным nginx молча
      # рвёт соединение (444) — панель не видна сканерам.
      cat <<EOF
map \$http_cookie \$dorik_auth_cookie { default 0; "~*${key}=${val}" 1; }
map \$arg_${key} \$dorik_auth_query { default 0; "${val}" 1; }
map "\$dorik_auth_cookie\$dorik_auth_query" \$dorik_authorized { "00" 0; default 1; }
map \$arg_${key} \$dorik_set_cookie { default ""; "${val}" "${key}=${val}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=31536000"; }
EOF
    fi
    cat <<EOF

server {
    listen 80 default_server;
    server_name _;
    return 444;
}

server {
    listen 80;
    server_name ${d};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${d};
    server_tokens off;

    ssl_certificate     /etc/letsencrypt/live/${d}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${d}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    client_max_body_size 20m;

EOF
    [ "$protect" = "1" ] && echo '    add_header Set-Cookie $dorik_set_cookie;' && echo
    cat <<EOF
    # Встроенная выдача подписок публична по замыслу — клиентам нужен доступ без cookie.
    location /api/sub/ {
        proxy_pass http://127.0.0.1:3000;
$(nginx_proxy_headers)
    }

    location / {
EOF
    if [ "$protect" = "1" ]; then
      cat <<'EOF'
        error_page 418 = @unauthorized;
        if ($dorik_authorized = 0) { return 418; }
EOF
    fi
    cat <<EOF
        proxy_pass http://127.0.0.1:3000;
$(nginx_proxy_headers)
    }

    location @unauthorized { return 444; }
}
EOF
  } > "$f"
  ln -sf "$f" "$NGX_EN/remnawave-panel"
}

write_nginx_sub() {
  local d="$1" f="$NGX_AV/remnawave-sub"
  cat > "$f" <<EOF
# Создано DORIK toolkit. Страница подписки Remnawave.
map \$http_upgrade \$dorik_conn_upgrade_sub { default upgrade; '' close; }

server {
    listen 80;
    server_name ${d};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${d};
    server_tokens off;

    ssl_certificate     /etc/letsencrypt/live/${d}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${d}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    location / {
        proxy_pass http://127.0.0.1:3010;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$dorik_conn_upgrade_sub;
    }
}
EOF
  ln -sf "$f" "$NGX_EN/remnawave-sub"
}

nginx_apply() {
  rm -f "$NGX_EN/default"
  if nginx -t 2>/tmp/dorik_nginx_err; then
    systemctl enable nginx &>/dev/null || true
    systemctl restart nginx
    return 0
  fi
  err "nginx -t: $(head -3 /tmp/dorik_nginx_err | tr '\n' ' ')"
  return 1
}

# Порт 80/443 должны быть свободны (или заняты нашим же nginx).
check_ports_free() {
  local p busy
  for p in 80 443; do
    busy="$(ss -tlnp 2>/dev/null | grep -E "[:.]${p}[[:space:]]" | grep -v nginx || true)"
    if [ -n "$busy" ]; then
      err "Порт ${p} уже занят другим сервисом:"
      echo "$busy" | head -2 | sed 's/^/      /' >&2
      err "Панель ставьте на отдельный сервер (на сервере с нодой 443 занимает HAProxy)."
      return 1
    fi
  done
}

# ---- установка панели ---------------------------------------------------------------
panel_install() {
  step "Установка панели Remnawave"
  if panel_installed; then
    warn "Панель уже установлена в ${PANEL_DIR}. Для обновления выберите «Обновить панель»."
    return 0
  fi
  # Панель тяжелее ноды: PostgreSQL + Valkey + backend — от 2 ГБ памяти и 10 ГБ диска.
  preflight_run --docker --certs --ports "80 443" --allow nginx --ram-mb 2048 --disk-gb 10 || return 1
  # Для панели строже, чем в предполётной проверке: 443 не должен занимать и HAProxy ноды.
  check_ports_free || return 1

  # local X="$X": значение из окружения (режим без вопросов) используется как ответ по умолчанию.
  local PANEL_DOMAIN="${PANEL_DOMAIN:-}" SUB_DOMAIN="${SUB_DOMAIN:-}" PROTECT=1 KEY VAL pub_ip
  PANEL_DOMAIN=$(ask_valid "Домен панели (например panel.example.com)" "${PANEL_DOMAIN:-}" is_valid_domain) || return 1
  SUB_DOMAIN=$(ask_valid "Домен страницы подписки (Enter — пропустить, будет /api/sub панели)" "${SUB_DOMAIN:-}" is_valid_domain 1) || return 1
  PANEL_DOMAIN="${PANEL_DOMAIN,,}"; SUB_DOMAIN="${SUB_DOMAIN,,}"
  if ask_yes_no "Скрыть панель за секретной ссылкой (рекомендуется)?" "1"; then PROTECT=1; else PROTECT=0; fi

  # DNS заранее: без него сертификат не выпустится, а HTTPS-панель не откроется.
  pub_ip="$(get_public_ip)"
  local d
  for d in "$PANEL_DOMAIN" "$SUB_DOMAIN"; do
    [ -z "$d" ] && continue
    if cert_is_valid "$d"; then continue; fi
    if [ -n "$pub_ip" ] && ! dns_points_here "$d" "$pub_ip"; then
      warn "${d}: DNS указывает не на этот сервер (${pub_ip}). Сертификат не выпустится."
      ask_yes_no "Всё равно продолжить?" "2" || { err "Сначала поправьте A-запись ${d} -> ${pub_ip}."; return 1; }
    fi
  done

  ensure_docker || return 1
  mkdir -p "$PANEL_DIR" "$BACKUP_DIR"

  step "Конфигурация панели"
  fetch "$UP_BACKEND/docker-compose-prod.yml" "$PANEL_DIR/docker-compose.yml" \
    || { err "Не удалось скачать docker-compose-prod.yml из репозитория Remnawave."; return 1; }
  fetch "$UP_BACKEND/.env.sample" "$PANEL_DIR/.env.sample" \
    || { err "Не удалось скачать .env.sample из репозитория Remnawave."; return 1; }
  cp -f "$PANEL_DIR/.env.sample" "$PANEL_DIR/.env"
  local env="$PANEL_DIR/.env" pg_pass
  pg_pass="$(rand_hex 24)"
  set_env "$env" APP_SECRET "$(rand_hex 64)"
  set_env "$env" POSTGRES_PASSWORD "$pg_pass"
  set_env "$env" DATABASE_URL "\"postgresql://postgres:${pg_pass}@remnawave-db:5432/postgres\""
  set_env "$env" METRICS_PASS "$(rand_hex 16)"
  set_env "$env" WEBHOOK_SECRET_HEADER "$(rand_hex 32)"
  set_env "$env" PANEL_DOMAIN "$PANEL_DOMAIN"
  set_env "$env" FRONT_END_DOMAIN "$PANEL_DOMAIN"
  set_env "$env" SUB_PUBLIC_DOMAIN "${SUB_DOMAIN:-${PANEL_DOMAIN}/api/sub}"
  chmod 600 "$env"
  ok "Секреты сгенерированы, ${env} (права 600)."

  KEY="k$(rand_hex 4)"; VAL="$(rand_hex 16)"
  conf_set PANEL_DOMAIN "$PANEL_DOMAIN"; conf_set SUB_DOMAIN "$SUB_DOMAIN"
  conf_set PROTECT "$PROTECT"; conf_set KEY "$KEY"; conf_set VAL "$VAL"

  step "Запуск панели"
  spin_run "Загрузка образов (backend, postgres, valkey)" compose_in "$PANEL_DIR" pull \
    || { err "Не удалось загрузить образы."; return 1; }
  spin_run "Запуск контейнеров" compose_in "$PANEL_DIR" up -d || { err "docker compose up не удался."; return 1; }
  spin_run "Ожидание готовности панели (до 3 минут)" wait_container_ready remnawave 180 \
    || { err "Панель не стала healthy: docker logs remnawave --tail 50"; return 1; }

  step "Домен и HTTPS"
  local web_ok=1
  if ! have nginx || ! have certbot; then apt_install nginx certbot || web_ok=0; fi
  if [ "$web_ok" = 1 ]; then
    systemctl stop nginx &>/dev/null || true
    ensure_cert "$PANEL_DOMAIN" || web_ok=0
    [ -n "$SUB_DOMAIN" ] && { ensure_cert "$SUB_DOMAIN" || warn "Сертификат для ${SUB_DOMAIN} не выпущен — страницу подписки настроите позже."; }
  fi
  if [ "$web_ok" = 1 ]; then
    install_renew_hook
    write_nginx_panel "$PANEL_DOMAIN" "$PROTECT" "$KEY" "$VAL"
    if [ -n "$SUB_DOMAIN" ] && cert_is_valid "$SUB_DOMAIN"; then write_nginx_sub "$SUB_DOMAIN"; fi
    nginx_apply || web_ok=0
  fi
  if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 80/tcp comment "HTTP" &>/dev/null; ufw allow 443/tcp comment "HTTPS" &>/dev/null
  fi

  # ---- проверка результата ----
  step "Проверка результата"
  VERIFY_FAIL=0
  local c
  for c in remnawave remnawave-db remnawave-redis; do
    container_running "$c"; _chk $? "контейнер ${c} запущен" "контейнер ${c} не запущен"
  done
  curl -fs --max-time 5 http://127.0.0.1:3001/health &>/dev/null; _chk $? "health-check панели отвечает" "health-check панели не отвечает"
  if [ "$web_ok" = 1 ]; then
    local code
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 --resolve "${PANEL_DOMAIN}:443:127.0.0.1" "https://${PANEL_DOMAIN}/$([ "$PROTECT" = 1 ] && echo "?${KEY}=${VAL}")" || true)"
    [[ "$code" =~ ^[234] ]]; _chk $? "https://${PANEL_DOMAIN} отвечает (HTTP ${code})" "https://${PANEL_DOMAIN} не отвечает (код ${code:-000})"
    if [ "$PROTECT" = 1 ]; then
      code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 --resolve "${PANEL_DOMAIN}:443:127.0.0.1" "https://${PANEL_DOMAIN}/" || true)"
      [ "$code" = "000" ]; _chk $? "без секретной ссылки панель не отвечает (защита работает)" "без секретной ссылки панель отвечает кодом ${code} — защита не работает"
    fi
  else
    err "HTTPS не настроен (сертификат/nginx) — панель доступна только локально на 127.0.0.1:3000."; VERIFY_FAIL=$((VERIFY_FAIL+1))
  fi

  local login_url=""
  if [ "$web_ok" = 1 ]; then
    login_url="https://${PANEL_DOMAIN}"
    [ "$PROTECT" = 1 ] && login_url="https://${PANEL_DOMAIN}/?${KEY}=${VAL}"
  fi
  echo
  box_top "Панель Remnawave установлена"
  if [ -n "$login_url" ]; then
    box_row "Ссылка для входа — ${C_BOLD}сохраните её${C_RESET}:"
    [ "$PROTECT" = 1 ] && box_wrap "${C_DIM}•${C_RESET}" "Без секретной ссылки панель закрыта; cookie ставится на год."
  fi
  box_sep
  box_wrap "1." "Откройте ссылку и создайте суперадминистратора."
  box_wrap "2." "Настройки → API-токены → создайте токен (понадобится для страницы подписки)."
  box_wrap "3." "Ноды → Добавить: SECRET_KEY вставьте в установщик ноды."
  box_row "${C_DIM}Файлы: ${PANEL_DIR} · секреты: ${PANEL_DIR}/.env${C_RESET}"
  box_bottom
  # URL — вне рамки: его нельзя переносить и обрезать, его копируют целиком.
  [ -n "$login_url" ] && echo -e "\n  ${C_B}${C_BOLD}${login_url}${C_RESET}\n"

  if [ -n "$SUB_DOMAIN" ] && ask_yes_no "Установить страницу подписки сейчас? (нужен API-токен из шага 2)" "2"; then
    sub_install || true
  elif [ -n "$SUB_DOMAIN" ]; then
    info "Страницу подписки поставите позже: меню → Панель Remnawave → «Страница подписки»."
  fi
  return "$VERIFY_FAIL"
}

# ---- обновление панели ------------------------------------------------------------------
backup_db() {
  local user db f="$BACKUP_DIR/db-$(date +%Y%m%d-%H%M%S).sql.gz"
  user="$(env_get "$PANEL_DIR/.env" POSTGRES_USER)"; user="${user:-postgres}"
  db="$(env_get "$PANEL_DIR/.env" POSTGRES_DB)"; db="${db:-postgres}"
  docker exec remnawave-db pg_dump -U "$user" -d "$db" | gzip > "$f"
  [ -s "$f" ] && [ "$(stat -c %s "$f")" -gt 200 ] || { rm -f "$f"; return 1; }
  echo "$f" > "$BACKUP_DIR/.last-db"
  keep_last "$BACKUP_DIR/db-*.sql.gz" 5
}

panel_update() {
  step "Обновление панели Remnawave"
  panel_installed || { err "Панель не найдена в ${PANEL_DIR}. Сначала установите её."; return 1; }
  ensure_docker || return 1
  mkdir -p "$BACKUP_DIR"
  local ts; ts="$(date +%Y%m%d-%H%M%S)"

  declare -A before
  local c
  for c in remnawave remnawave-db remnawave-redis; do before[$c]="$(image_id "$c")"; done

  if container_running remnawave-db; then
    spin_run "Резервная копия базы данных" backup_db \
      || { err "Не удалось сделать бэкап БД — обновление отменено (данные важнее)."; return 1; }
    ok "Бэкап: $(cat "$BACKUP_DIR/.last-db")"
  else
    warn "Контейнер БД не запущен — бэкап пропущен."
  fi
  cp -f "$PANEL_DIR/docker-compose.yml" "$BACKUP_DIR/compose-$ts.yml"
  cp -f "$PANEL_DIR/.env" "$BACKUP_DIR/env-$ts"; chmod 600 "$BACKUP_DIR/env-$ts"
  keep_last "$BACKUP_DIR/compose-*.yml" 5; keep_last "$BACKUP_DIR/env-*" 5

  local newc="$PANEL_DIR/.compose.new" news="$PANEL_DIR/.env.sample"
  fetch "$UP_BACKEND/docker-compose-prod.yml" "$newc" || { err "Не удалось скачать свежий compose."; return 1; }
  fetch "$UP_BACKEND/.env.sample" "$news" || warn "Не удалось скачать .env.sample — новые параметры не будут добавлены."
  if ! diff -q "$PANEL_DIR/docker-compose.yml" "$newc" &>/dev/null; then
    info "compose изменился в репозитории Remnawave:"
    diff <(grep -E 'image:' "$PANEL_DIR/docker-compose.yml") <(grep -E 'image:' "$newc") | sed -n 's/^[<>] /      /p' | head -8 | sed 's/^/ /'
  fi
  mv -f "$newc" "$PANEL_DIR/docker-compose.yml"
  [ -s "$news" ] && merge_env_sample "$news" "$PANEL_DIR/.env"

  spin_run "Загрузка новых образов" compose_in "$PANEL_DIR" pull || { err "pull не удался."; return 1; }
  spin_run "Перезапуск контейнеров" compose_in "$PANEL_DIR" up -d || { err "up -d не удался."; return 1; }
  spin_run "Ожидание готовности панели (до 3 минут)" wait_container_ready remnawave 180 \
    || { err "Панель не стала healthy после обновления."; warn "Откат: cp ${BACKUP_DIR}/compose-${ts}.yml ${PANEL_DIR}/docker-compose.yml && cd ${PANEL_DIR} && docker compose up -d"; warn "База: zcat \$(cat ${BACKUP_DIR}/.last-db) | docker exec -i remnawave-db psql -U postgres"; return 1; }

  step "Проверка результата"
  VERIFY_FAIL=0
  for c in remnawave remnawave-db remnawave-redis; do
    container_running "$c"; _chk $? "контейнер ${c} работает" "контейнер ${c} не работает"
    local now; now="$(image_id "$c")"
    if [ "$now" != "${before[$c]}" ]; then ok "  ${c}: образ обновлён (${before[$c]:-—} → ${now})"
    else info "  ${c}: образ без изменений (уже последняя версия)"; fi
  done
  curl -fs --max-time 5 http://127.0.0.1:3001/health &>/dev/null; _chk $? "health-check панели отвечает" "health-check панели не отвечает"
  docker image prune -f &>/dev/null || true
  return "$VERIFY_FAIL"
}

# ---- страница подписки -----------------------------------------------------------------
# При неверном токене страница подписки падает на старте и PM2 перезапускает её по
# кругу — снаружи это выглядит как «контейнер Up». Поэтому смотрим в её логи.
sub_check_token() {
  local token code restarts
  token="$(env_get "$SUB_DIR/.env" REMNAWAVE_API_TOKEN)"
  # Прямой запрос к API панели с токеном: 200 — токен рабочий, 401/403 — нет.
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
    -H 'X-Forwarded-For: 127.0.0.1' -H 'X-Forwarded-Proto: https' \
    -H "Authorization: Bearer ${token}" http://127.0.0.1:3000/api/nodes || true)"
  restarts="$(docker inspect -f '{{.RestartCount}}' remnawave-subscription-page 2>/dev/null)"
  case "$code" in
    200) ok "API-токен принят панелью"
         [ "${restarts:-0}" -gt 2 ] && warn "Страница подписки перезапускалась ${restarts} раз(а) (мог быть прежний неверный токен) — если не стабилизируется: docker logs remnawave-subscription-page" ;;
    401|403)
         err "Панель отклонила API-токен (HTTP ${code}) — страница подписки не сможет работать."
         err "Создайте новый токен: панель → Настройки → API-токены, затем повторите установку страницы подписки."
         VERIFY_FAIL=$((VERIFY_FAIL+1)) ;;
    000) err "Панель не отвечает на 127.0.0.1:3000 — проверьте: docker logs remnawave"
         VERIFY_FAIL=$((VERIFY_FAIL+1)) ;;
    *)   warn "Не удалось проверить токен (HTTP ${code}) — убедитесь в логах: docker logs remnawave-subscription-page" ;;
  esac
}

sub_install() {
  step "Страница подписки Remnawave"
  panel_installed || { err "Панель не найдена на этом сервере — страница подписки ставится рядом с панелью."; return 1; }
  ensure_docker || return 1

  local SUB_DOMAIN="${SUB_DOMAIN:-}" token web_ok=1
  [ -z "$SUB_DOMAIN" ] && SUB_DOMAIN="$(conf_get SUB_DOMAIN)"
  SUB_DOMAIN=$(ask_valid "Домен страницы подписки" "$SUB_DOMAIN" is_valid_domain) || return 1
  SUB_DOMAIN="${SUB_DOMAIN,,}"
  token="${REMNAWAVE_API_TOKEN:-}"
  if [ -z "$token" ] && sub_installed; then token="$(env_get "$SUB_DIR/.env" REMNAWAVE_API_TOKEN)"; fi
  while [ -z "$token" ] || [ "${#token}" -lt 20 ]; do
    info "API-токен: панель → Настройки → API-токены → создать."
    token=$(ask_value "API-токен Remnawave" "")
    token="$(echo -n "$token" | tr -d ' \r\n"')"
    [ "${ASSUME_YES:-0}" = "1" ] && [ "${#token}" -lt 20 ] && { err "REMNAWAVE_API_TOKEN не задан."; return 1; }
  done

  docker network inspect remnawave-network &>/dev/null \
    || { err "Сеть remnawave-network не найдена — панель запущена не из этого установщика?"; return 1; }

  mkdir -p "$SUB_DIR"
  fetch "$UP_SUB/docker-compose-prod.yml" "$SUB_DIR/docker-compose.yml" || { err "Не удалось скачать compose страницы подписки."; return 1; }
  fetch "$UP_SUB/.env.sample" "$SUB_DIR/.env.sample" || { err "Не удалось скачать .env.sample страницы подписки."; return 1; }
  [ -f "$SUB_DIR/.env" ] || cp -f "$SUB_DIR/.env.sample" "$SUB_DIR/.env"
  local env="$SUB_DIR/.env"
  set_env "$env" APP_PORT 3010
  set_env "$env" REMNAWAVE_PANEL_URL "http://remnawave:3000"
  set_env "$env" REMNAWAVE_API_TOKEN "$token"
  chmod 600 "$env"

  spin_run "Загрузка образа страницы подписки" compose_in "$SUB_DIR" pull || { err "pull не удался."; return 1; }
  spin_run "Запуск страницы подписки" compose_in "$SUB_DIR" up -d || { err "up -d не удался."; return 1; }
  spin_run "Ожидание запуска страницы подписки" wait_container_ready remnawave-subscription-page 40 || true

  # Панель должна отдавать клиентам ссылки на домен страницы, а не на свой.
  if [ "$(env_get "$PANEL_DIR/.env" SUB_PUBLIC_DOMAIN)" != "$SUB_DOMAIN" ]; then
    set_env "$PANEL_DIR/.env" SUB_PUBLIC_DOMAIN "$SUB_DOMAIN"
    spin_run "Применяю SUB_PUBLIC_DOMAIN в панели" compose_in "$PANEL_DIR" up -d
  fi
  conf_set SUB_DOMAIN "$SUB_DOMAIN"

  if ! have nginx || ! have certbot; then apt_install nginx certbot || web_ok=0; fi
  if [ "$web_ok" = 1 ]; then
    ensure_cert "$SUB_DOMAIN" || web_ok=0
  fi
  if [ "$web_ok" = 1 ]; then
    install_renew_hook
    write_nginx_sub "$SUB_DOMAIN"
    nginx_apply || web_ok=0
  fi
  have ufw && ufw status 2>/dev/null | grep -q '^Status: active' && { ufw allow 80/tcp &>/dev/null; ufw allow 443/tcp &>/dev/null; }

  step "Проверка результата"
  VERIFY_FAIL=0
  container_running remnawave-subscription-page; _chk $? "контейнер страницы подписки работает" "контейнер страницы подписки не работает"
  # Страница подписки на запрос корня «/» намеренно не отвечает (рвёт соединение) —
  # так она не видна сканерам. Поэтому судим по healthcheck контейнера и по логам.
  [ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' remnawave-subscription-page 2>/dev/null)" != "unhealthy" ]
  _chk $? "healthcheck страницы подписки в порядке" "healthcheck страницы подписки: unhealthy"
  sub_check_token
  local code
  if [ "$web_ok" = 1 ]; then
    # 502 на «/» — штатно (см. выше); 000 означает, что nginx/TLS не работают.
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 --resolve "${SUB_DOMAIN}:443:127.0.0.1" "https://${SUB_DOMAIN}/" || true)"
    [ "$code" != "000" ]; _chk $? "nginx принимает HTTPS для ${SUB_DOMAIN} (HTTP ${code})" "nginx не отвечает по HTTPS для ${SUB_DOMAIN}"
  else
    err "HTTPS для ${SUB_DOMAIN} не настроен (сертификат/nginx)."; VERIFY_FAIL=$((VERIFY_FAIL+1))
  fi
  echo
  box_top "Страница подписки"
  box_row "Адрес:  ${C_B}https://${SUB_DOMAIN}${C_RESET}"
  box_row "${C_DIM}Ссылки подписок в панели теперь ведут на этот домен.${C_RESET}"
  box_bottom
  return "$VERIFY_FAIL"
}

sub_update() {
  step "Обновление страницы подписки"
  sub_installed || { err "Страница подписки не установлена."; return 1; }
  ensure_docker || return 1
  local before now
  before="$(image_id remnawave-subscription-page)"
  fetch "$UP_SUB/docker-compose-prod.yml" "$SUB_DIR/docker-compose.yml" || warn "Свежий compose не скачан — использую текущий."
  fetch "$UP_SUB/.env.sample" "$SUB_DIR/.env.sample" && merge_env_sample "$SUB_DIR/.env.sample" "$SUB_DIR/.env"
  spin_run "Загрузка нового образа" compose_in "$SUB_DIR" pull || { err "pull не удался."; return 1; }
  spin_run "Перезапуск страницы подписки" compose_in "$SUB_DIR" up -d || { err "up -d не удался."; return 1; }
  spin_run "Ожидание запуска страницы подписки" wait_container_ready remnawave-subscription-page 40 || true
  step "Проверка результата"
  VERIFY_FAIL=0
  now="$(image_id remnawave-subscription-page)"
  container_running remnawave-subscription-page; _chk $? "контейнер работает" "контейнер не работает"
  sub_check_token
  if [ "$now" != "$before" ]; then ok "образ обновлён (${before:-—} → ${now})"; else info "образ без изменений (уже последняя версия)"; fi
  docker image prune -f &>/dev/null || true
  return "$VERIFY_FAIL"
}

# ---- статус ------------------------------------------------------------------------------
panel_status() {
  echo
  box_top "Панель Remnawave"
  st_panel; dot_row "$ST_L" "Панель" "$ST_T"
  st_sub;   dot_row "$ST_L" "Страница подп." "$ST_T"
  local dom key val url=""
  if panel_installed; then
    box_sep
    dom="$(conf_get PANEL_DOMAIN)"; key="$(conf_get KEY)"; val="$(conf_get VAL)"
    if [ -n "$dom" ]; then
      url="https://${dom}"
      [ "$(conf_get PROTECT)" = "1" ] && [ -n "$key" ] && url="https://${dom}/?${key}=${val}"
      box_row "Ссылка для входа ниже ↓"
    fi
    box_row "${C_DIM}Каталог: ${PANEL_DIR}${C_RESET}"
    box_row "${C_DIM}Бэкапы:  ${BACKUP_DIR}${C_RESET}"
  fi
  box_bottom
  [ -n "$url" ] && echo -e "\n  ${C_B}${C_BOLD}${url}${C_RESET}\n"
  return 0
}

panel_menu() {
  local ch
  while true; do
    echo
    box_top "Панель Remnawave"
    box_row "${C_B}1${C_RESET}  Установить панель (+ nginx и сертификат)"
    box_row "${C_B}2${C_RESET}  Обновить панель (с резервной копией БД)"
    box_row "${C_B}3${C_RESET}  Установить страницу подписки"
    box_row "${C_B}4${C_RESET}  Обновить страницу подписки"
    box_row "${C_B}5${C_RESET}  Статус и ссылка для входа"
    box_row "${C_B}9${C_RESET}  Назад"
    box_bottom
    read -r -p "$(echo -e "${C_Y}›${C_RESET} Выбор: ")" ch <"$(prompt_input)" || return 0
    case "$ch" in
      1) panel_install ;;
      2) panel_update ;;
      3) sub_install ;;
      4) sub_update ;;
      5) panel_status ;;
      *) return 0 ;;
    esac
  done
}

case "${1:-menu}" in
  install)    ensure_tty; panel_install ;;
  update)     panel_update ;;
  sub)        ensure_tty; sub_install ;;
  sub-update) sub_update ;;
  status)     panel_status ;;
  menu)       ensure_tty; panel_menu ;;
  *) echo "Использование: $0 [install|update|sub|sub-update|status]" >&2; exit 2 ;;
esac
