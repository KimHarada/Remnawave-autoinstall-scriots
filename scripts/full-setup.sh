#!/usr/bin/env bash
# DORIK toolkit — полная настройка сервера (нода или сервер панели).
# Сначала определяет, что уже установлено, и предлагает исправить последствия
# старых версий; затем собирает ВСЕ параметры один раз и выполняет пайплайн без
# вопросов. После каждого этапа — проверка результата:
#   обновление пакетов -> SSH -> firewall/fail2ban -> (нода: nginx+haproxy+bbr+remnanode)
#
# Без вопросов (cloud-init): ASSUME_YES=1 и параметры в переменных окружения,
# список переменных — в README.md.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW="${DORIK_RAW:-https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main}"

source "${SCRIPT_DIR}/lib.sh" 2>/dev/null || {
  LIBTMP="$(mktemp)"; curl -fsSL --retry 3 "${RAW}/scripts/lib.sh" -o "$LIBTMP" && source "$LIBTMP"
} || { echo "Не удалось загрузить lib.sh" >&2; exit 1; }
_dorik_source state.sh
_dorik_source harden.sh
_dorik_source doctor.sh
_dorik_source preflight.sh
_dorik_source decoys.sh
_dorik_source profile-setup.sh
_dorik_source scanblock.sh

require_root
require_apt_os
ensure_tty

banner
box_top "Полная настройка сервера"
box_row "Сначала посмотрим, что уже установлено, затем зададим все"
box_row "вопросы ОДИН раз — после этого всё пройдёт само."
box_row "${C_DIM}Подробный лог: ${DORIK_LOG}${C_RESET}"
box_bottom

# ---------------------------------------------------------------------------
# ШАГ 0. Базовые пакеты (нужны уже для вопросов: dig, curl, ufw, cron)
# ---------------------------------------------------------------------------
ensure_base_packages || warn "Базовые пакеты установились не полностью — часть проверок может не работать."

# ---------------------------------------------------------------------------
# ШАГ 0.5. Что уже есть на сервере + исправление последствий старых версий
# ---------------------------------------------------------------------------
step "Что уже установлено"
show_dashboard
# Укрепление (порты, ядро, SSH) предложим отдельным вопросом ниже — здесь чиним только
# последствия старых версий, чтобы отказ пользователя в вопросе не был обойдён заранее.
DORIK_IGNORE="${DORIK_IGNORE:+${DORIK_IGNORE},}ports_exposed,hardening_missing,shield_missing,ufw_ipv6" doctor_run || true

# ---------------------------------------------------------------------------
# ШАГ 1. Сбор параметров (никаких вопросов после этого блока)
# ---------------------------------------------------------------------------
step "Вопросы"

ROLE="${ROLE:-1}"; is_valid_choice12 "$ROLE" || { err "ROLE должен быть 1 (нода) или 2 (сервер панели)."; exit 1; }
ask_choice "РОЛЬ СЕРВЕРА" "$ROLE" \
  "Нода|Сервер, к которому подключаются клиенты. Вы выберете протоколы (REALITY TCP, gRPC, XHTTP, Hysteria2, Telegram), для каждого зададите домен. Ставятся заглушки self-steal, HAProxy, сертификаты, BBR и Remnanode." \
  "Сервер панели|Только защита сервера, на котором работает панель Remnawave: SSH, firewall (открыты SSH, 80 и 443), fail2ban, укрепление. Саму панель ставит пункт меню «Панель Remnawave»." \
  || { err "Отменено пользователем."; exit 1; }
ROLE="$CHOICE"

# Роль известна — проверяем окружение до остальных вопросов, чтобы не гонять
# пользователя по вопросам, если установка всё равно невозможна.
if [ "$ROLE" = "1" ]; then
  preflight_run --docker --certs --ports "80 443" || exit 1
else
  preflight_run || exit 1
fi

CUR_SSH_PORT=$(get_real_ssh_port)
CUR_SSH_PORT=${CUR_SSH_PORT:-$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')}
CUR_SSH_PORT=${CUR_SSH_PORT:-22}
info "Текущий SSH порт: ${CUR_SSH_PORT}"
NEW_SSH_PORT=$(ask_valid "Новый SSH порт (Enter — оставить как есть)" "${NEW_SSH_PORT:-$CUR_SSH_PORT}" is_valid_port) || exit 1
# 80/443 заняты под certbot/HAProxy — SSH на них посадить нельзя.
while [ "$NEW_SSH_PORT" = "80" ] || [ "$NEW_SSH_PORT" = "443" ]; do
  err "Порт ${NEW_SSH_PORT} нужен под HTTPS/сертификаты — выберите другой порт для SSH."
  [ "${ASSUME_YES:-0}" = "1" ] && exit 1
  NEW_SSH_PORT=$(ask_valid "Новый SSH порт" "" is_valid_port) || exit 1
done

if [ "$ROLE" = "1" ]; then
  # ---- домены протоколов -----------------------------------------------------------------------
  # Вручную (по домену на протокол) либо от ОДНОГО базового домена: остальные сгенерирую сам
  # (случайные имена — по названию поддомена нельзя угадать протокол; нужна wildcard-запись DNS).
  # значения из окружения (режим без вопросов) запоминаем до обнуления
  USE_TG_ENV="${USE_TG:-0}"; USE_HY2_ENV="${USE_HY2:-1}"; USE_WEB_ENV="${USE_WEB:-0}"
  DOMAIN_TCP="${DOMAIN_TCP:-}"; DOMAIN_GRPC="${DOMAIN_GRPC:-}"; DOMAIN_XHTTP="${DOMAIN_XHTTP:-}"
  DOMAIN_HY2="${DOMAIN_HY2:-}"; DOMAIN_TG="${DOMAIN_TG:-}"; DOMAIN_WEB="${DOMAIN_WEB:-}"

  # домен протокола из прошлой установки (чтобы повторный запуск не менял домены)
  prev_domain() { [ -s /etc/dorik/decoys.conf ] && awk -F'|' -v p="$1" '$1==p{print $2; exit}' /etc/dorik/decoys.conf; return 0; }

  # ---- 1. какие протоколы ставим -------------------------------------------------------------
  # Сначала выбор протоколов, потом домены — только для выбранных.
  # Без вопросов: PROTOCOLS="tcp grpc xhttp hy2 tg web" (либо, как раньше, по заданным DOMAIN_* и USE_*).
  PROTO_KEYS=(tcp grpc xhttp hy2 tg web)
  PROTO_HOT=(1 2 3 4 5 6)
  PROTO_LABELS=("VLESS REALITY TCP" "VLESS REALITY gRPC" "VLESS REALITY XHTTP" "Hysteria2" "Telegram-хост" "WEB-прокси Telegram")
  declare -A PROTO_VAR=( [tcp]=DOMAIN_TCP [grpc]=DOMAIN_GRPC [xhttp]=DOMAIN_XHTTP [hy2]=DOMAIN_HY2 [tg]=DOMAIN_TG [web]=DOMAIN_WEB )
  NL=$'\n'
  PROTO_DESC=(
    "Основной протокол: самый совместимый, работает во всех клиентах. Трафик выглядит как обычный HTTPS к вашему домену, чужим отдаётся страница-заглушка.${NL}${NL}@ПОРТ${NL}443/tcp через HAProxy${NL}${NL}@НУЖНО${NL}свой домен и сертификат"
    "VLESS REALITY поверх gRPC. Запасной транспорт: помогает там, где обычный TCP режут по поведению соединения.${NL}${NL}@ПОРТ${NL}443/tcp через HAProxy (по SNI)${NL}${NL}@НУЖНО${NL}отдельный домен"
    "VLESS REALITY поверх XHTTP: запросы выглядят как обычная работа сайта, устойчив к обрывам длинных соединений.${NL}${NL}@ПОРТ${NL}443/tcp через HAProxy (по SNI)${NL}${NL}@НУЖНО${NL}отдельный домен"
    "Быстрый протокол поверх QUIC (UDP). Хорош на плохих и мобильных сетях; там, где UDP режут, не работает — поэтому ставится вместе с TCP-протоколами.${NL}${NL}@ПОРТ${NL}443/udp напрямую${NL}${NL}@НУЖНО${NL}отдельный домен и сертификат"
    "Отдельный хост, через который ходят только Telegram и ЮKassa/ЮMoney — остальное на нём блокируется. Удобно для бесплатного или ограниченного тарифа.${NL}${NL}@ПОРТ${NL}443/tcp через HAProxy (по SNI)${NL}${NL}@НУЖНО${NL}отдельный домен"
    "Прокси Telegram типа «WEB» (Telemt) с рекламой вашего канала через @MTProxybot. К Xray и подпискам не относится — это отдельная служба.${NL}${NL}@ПОРТ${NL}443/tcp через HAProxy (по SNI)${NL}${NL}@НУЖНО${NL}отдельный домен"
  )
  declare -A SEL=()
  if [ -n "${PROTOCOLS:-}" ]; then
    for p in ${PROTOCOLS//,/ }; do SEL[${p,,}]=1; done
  elif [ -n "${DOMAIN_TCP}${DOMAIN_GRPC}${DOMAIN_XHTTP}${DOMAIN_HY2}" ]; then
    # прежний способ: что задано в DOMAIN_* — то и ставим
    [ -n "$DOMAIN_TCP" ] && SEL[tcp]=1
    [ -n "$DOMAIN_GRPC" ] && SEL[grpc]=1
    [ -n "$DOMAIN_XHTTP" ] && SEL[xhttp]=1
    [ -n "$DOMAIN_HY2" ] && [ "$USE_HY2_ENV" != "0" ] && SEL[hy2]=1
    [ "$USE_TG_ENV" = "1" ] && SEL[tg]=1
    [ "$USE_WEB_ENV" = "1" ] && SEL[web]=1
  elif [ -s /etc/dorik/decoys.conf ]; then
    # повторный запуск: отмечено то, что уже стоит
    while IFS='|' read -r p _; do [ -n "$p" ] && SEL[$p]=1; done < /etc/dorik/decoys.conf
  else
    SEL[tcp]=1; SEL[grpc]=1; SEL[xhttp]=1
    [ "$USE_HY2_ENV" != "0" ] && SEL[hy2]=1
    [ "$USE_TG_ENV" = "1" ] && SEL[tg]=1
    [ "$USE_WEB_ENV" = "1" ] && SEL[web]=1
  fi
  PROTO_STATE=()
  for p in "${PROTO_KEYS[@]}"; do PROTO_STATE+=("${SEL[$p]:-0}"); done
  while true; do
    TUI_SEL=0
    tui_checklist "ПРОТОКОЛЫ" PROTO_LABELS PROTO_DESC PROTO_HOT PROTO_STATE || { err "Отменено пользователем."; exit 1; }
    case " ${PROTO_STATE[*]} " in *" 1 "*) break ;; esac
    err "Не выбран ни один протокол — отметьте хотя бы один."
    [ "${ASSUME_YES:-0}" = "1" ] && exit 1
    sleep 2
  done
  SEL=()
  for i in "${!PROTO_KEYS[@]}"; do [ "${PROTO_STATE[$i]}" = "1" ] && SEL[${PROTO_KEYS[$i]}]=1; done
  # Есть ли что-то, что обслуживает Xray (нода Remnanode нужна только тогда).
  HAS_XRAY=0
  for p in tcp grpc xhttp hy2 tg; do [ -n "${SEL[$p]:-}" ] && HAS_XRAY=1; done
  USE_HY2="${SEL[hy2]:-0}"; USE_TG="${SEL[tg]:-0}"; USE_WEB="${SEL[web]:-0}"

  # ---- 2. веб-сервер заглушек: nginx или Caddy ------------------------------------------------
  if [ "${ASSUME_YES:-0}" = "1" ]; then WEB_SERVER="$(ws_current)"; else ws_ask node || { err "Отменено пользователем."; exit 1; }; fi
  export WEB_SERVER

  # ---- 3. домены — только для выбранных протоколов --------------------------------------------
  # Вручную (по домену на протокол) либо от ОДНОГО базового домена: остальные сгенерирую сам
  # (случайные имена — по названию поддомена нельзя угадать протокол; нужна wildcard-запись DNS).
  DOMAIN_MODE=2
  if [ -n "${DOMAIN_TCP}${DOMAIN_GRPC}${DOMAIN_XHTTP}${DOMAIN_HY2}" ] || { [ -s /etc/dorik/decoys.conf ] && [ -z "${BASE_DOMAIN:-}" ]; }; then DOMAIN_MODE=1; fi
  ask_choice "ДОМЕНЫ" "$DOMAIN_MODE" \
    "Каждый домен вручную|Для каждого выбранного протокола вы вводите свой домен. Домены могут быть на разных зонах — так их труднее связать между собой.${NL}${NL}@DNS${NL}A-запись каждого домена на IP этого сервера" \
    "Один базовый домен|Вы вводите один домен, а поддомены для выбранных протоколов я создам сам — со случайными именами, чтобы по названию нельзя было угадать протокол.${NL}${NL}@DNS${NL}одна запись *.домен на IP этого сервера" \
    || { err "Отменено пользователем."; exit 1; }
  DOMAIN_MODE="$CHOICE"

  if [ "$DOMAIN_MODE" = "2" ]; then
    BASE_DOMAIN=$(ask_valid "Базовый домен (например example.com)" "${BASE_DOMAIN:-}" is_valid_domain) || exit 1
    BASE_DOMAIN="${BASE_DOMAIN,,}"
    gen_domain() {  # gen_domain <proto> — прежний домен под этой базой либо новый случайный
      local d; d="$(prev_domain "$1")"
      case "$d" in *".${BASE_DOMAIN}") echo "$d" ;; *) echo "$(openssl rand -hex 4).${BASE_DOMAIN}" ;; esac
    }
    for p in "${PROTO_KEYS[@]}"; do
      if [ -n "${SEL[$p]:-}" ]; then printf -v "${PROTO_VAR[$p]}" '%s' "$(gen_domain "$p")"; else printf -v "${PROTO_VAR[$p]}" '%s' ""; fi
    done
  else
    info "Домены нужны только для выбранных протоколов: $(for i in "${!PROTO_KEYS[@]}"; do [ "${PROTO_STATE[$i]}" = "1" ] && printf '%s; ' "${PROTO_LABELS[$i]}"; done)"
    for i in "${!PROTO_KEYS[@]}"; do
      p="${PROTO_KEYS[$i]}"; v="${PROTO_VAR[$p]}"
      if [ -n "${SEL[$p]:-}" ]; then
        cur="${!v}"; [ -n "$cur" ] || cur="$(prev_domain "$p")"
        val=$(ask_valid "Домен для ${PROTO_LABELS[$i]}" "$cur" is_valid_domain) || exit 1
        printf -v "$v" '%s' "$val"
      else
        printf -v "$v" '%s' ""
      fi
    done
  fi
  DOMAIN_TCP="${DOMAIN_TCP,,}"; DOMAIN_GRPC="${DOMAIN_GRPC,,}"; DOMAIN_XHTTP="${DOMAIN_XHTTP,,}"; DOMAIN_HY2="${DOMAIN_HY2,,}"; DOMAIN_TG="${DOMAIN_TG,,}"; DOMAIN_WEB="${DOMAIN_WEB,,}"

  echo
  box_top "Домены протоколов"
  for i in "${!PROTO_KEYS[@]}"; do
    p="${PROTO_KEYS[$i]}"; v="${PROTO_VAR[$p]}"
    [ -n "${!v}" ] && box_row "${C_B}${PROTO_LABELS[$i]}${C_RESET}  ${!v}"
  done
  box_sep
  if [ "$DOMAIN_MODE" = "2" ]; then
    box_wrap "${C_DIM}→${C_RESET}" "DNS: создайте A-запись *.${BASE_DOMAIN} на IP этого сервера (или отдельные A-записи на каждый домен выше)."
  else
    box_wrap "${C_DIM}→${C_RESET}" "DNS: A-запись каждого домена должна указывать на IP этого сервера."
  fi
  box_bottom
  # Рекламный тег канала-спонсора для WEB-прокси (необязательно; можно добавить позже: webproxy-setup.sh tag <тег>)
  WEB_AD_TAG="${WEB_AD_TAG:-}"
  if [ "$USE_WEB" = "1" ]; then
    # Ключ нужен боту ДО выдачи тега, поэтому создаём его сейчас (установка возьмёт тот же).
    WEB_SECRET="${WEB_SECRET:-$([ -s /etc/dorik/webproxy.json ] && jq -r '.secret // empty' /etc/dorik/webproxy.json 2>/dev/null)}"
    WEB_SECRET="${WEB_SECRET:-$(openssl rand -hex 16)}"
    echo
    box_top "Реклама канала: регистрация в @MTProxybot (по желанию)"
    box_row "Бот: ${C_BOLD}https://t.me/MTProxybot${C_RESET}"
    box_row "1. Отправьте боту: /newproxy"
    box_row "2. Адрес:  ${C_BOLD}${DOMAIN_WEB}:443${C_RESET}"
    box_row "3. Ключ:   ${C_BOLD}${WEB_SECRET}${C_RESET}"
    box_row "4. Тег из бота (32 символа) введите ниже; пропустить можно"
    box_bottom
    WEB_AD_TAG=$(ask_valid "Рекламный тег (Enter — без рекламы канала)" "$WEB_AD_TAG" is_hex32 1) || exit 1
  fi
  export USE_WEB DOMAIN_WEB WEB_AD_TAG WEB_SECRET

  # ---- предварительная проверка DNS сразу после ввода доменов --------------
  # Видно сразу, до подтверждения запуска, пока ещё можно поправить A-записи
  # и не жечь лимит Let's Encrypt.
  step "Предварительная проверка DNS"
  PREFLIGHT_PUB_IP="$(get_public_ip)"
  if [ -z "$PREFLIGHT_PUB_IP" ]; then
    warn "Не удалось определить публичный IP сервера — проверку DNS пропускаю."
  else
    info "Публичный IP сервера: ${PREFLIGHT_PUB_IP}"
    DNS_PREFLIGHT_BAD=0
    for d in "$DOMAIN_TCP" "$DOMAIN_GRPC" "$DOMAIN_XHTTP" "$DOMAIN_HY2" "$DOMAIN_TG" "$DOMAIN_WEB"; do
      [ -z "$d" ] && continue
      if dns_points_here "$d" "$PREFLIGHT_PUB_IP"; then
        ok "${d}: DNS указывает на этот сервер."
      else
        RESOLVED=$(dig +short A "$d" 2>/dev/null | tail -1)
        warn "${d}: DNS указывает на '${RESOLVED:-<нет ответа>}', а не на ${PREFLIGHT_PUB_IP}. Сертификат для этого домена НЕ будет выпущен, пока не поправишь A-запись."
        DNS_PREFLIGHT_BAD=1
      fi
    done
    if [ "$DNS_PREFLIGHT_BAD" = "1" ]; then
      warn "Часть доменов пока не указывает на этот сервер. Можно продолжить — эти сертификаты не выпустятся сейчас, скрипт подхватит их при повторном запуске."
    fi
  fi

  if ask_yes_no "Ставить красивые страницы-заглушки (своя, разная для каждого протокола)?" "1"; then
    INSTALL_DECOY=1
  else
    INSTALL_DECOY=0
    warn "Красивые страницы не ставим — self-steal всё равно настроится (у каждого протокола свой TLS-листенер на 127.0.0.1), но отдавать он будет простую страницу (у каждого протокола свою)."
  fi

  if ask_yes_no "Ставить BBR и сетевую оптимизацию?" "1"; then USE_BBR=1; else USE_BBR=0; fi

  # ---- профиль и хосты на панели по API -------------------------------------------------------------
  USE_API=0
  API_DEFAULT=2; [ -n "${PANEL_URL:-}" ] && API_DEFAULT=1
  if [ "$HAS_XRAY" != "1" ]; then
    # Выбран только WEB-прокси Telegram: нода Remnanode и профиль на панели не нужны.
    PROFILE_CREATE_NODE=0
    info "Протоколы Xray не выбраны — нода Remnanode и профиль на панели не ставятся."
  elif ask_yes_no "Создать профиль и хосты на панели автоматически по API (и получить SECRET_KEY)?" "$API_DEFAULT"; then
    USE_API=1
    profile_collect_params || exit 1     # PROFILE_CREATE_NODE и др. берутся из окружения либо спрашиваются
    PROFILE_CREATE_NODE="${PROFILE_CREATE_NODE:-0}"
    PANEL_HOST_HINT="${RW_BASE#*://}"; PANEL_HOST_HINT="${PANEL_HOST_HINT%%[:/]*}"
    PANEL_IP_HINT="$(getent ahostsv4 "$PANEL_HOST_HINT" 2>/dev/null | awk '{print $1; exit}')"
    [ -n "$PANEL_IP_HINT" ] && info "Адрес панели ${PANEL_HOST_HINT} → ${PANEL_IP_HINT} (подсказка для ограничения порта ноды; за Cloudflare это будет не ваш сервер)"
  else
    PROFILE_CREATE_NODE=0
  fi

  NODE_PORT="${NODE_PORT:-}"; OPEN_NODE_PORT=0; SECRET_KEY="${SECRET_KEY:-}"; PANEL_IP="${PANEL_IP:-}"
  if [ "$HAS_XRAY" = "1" ]; then
  # При повторном запуске порт предлагаем тот, что уже настроен в compose ноды.
  EXISTING_NODE_PORT=""
  [ -f "$NODE_DIR/docker-compose.yml" ] && \
    EXISTING_NODE_PORT=$(grep -oE 'NODE_PORT=[0-9]+' "$NODE_DIR/docker-compose.yml" | head -1 | cut -d= -f2)
  NODE_PORT=$(ask_valid "Порт remnanode (для связи с панелью)" "${NODE_PORT:-${EXISTING_NODE_PORT:-$DEFAULT_NODE_PORT}}" is_valid_port) || exit 1
  # Порт ноды не должен совпадать с SSH, 80 и 443: иначе один из сервисов не поднимется,
  # а проверка «порт слушает» ошибочно сочтёт успехом чужой процесс.
  while [ "$NODE_PORT" = "$NEW_SSH_PORT" ] || [ "$NODE_PORT" = "80" ] || [ "$NODE_PORT" = "443" ]; do
    err "Порт ноды ${NODE_PORT} уже занят под SSH/HTTPS — выберите другой."
    [ "${ASSUME_YES:-0}" = "1" ] && exit 1
    NODE_PORT=$(ask_valid "Порт remnanode" "" is_valid_port) || exit 1
  done
  OPEN_NODE_PORT=0
  if ask_yes_no "Открыть порт ${NODE_PORT} для панели в firewall сейчас?" "1"; then
    OPEN_NODE_PORT=1
    PANEL_IP=$(ask_valid "IP панели (Enter — открыть порт для всех)" "${PANEL_IP:-}" is_valid_ip 1) || exit 1
  fi

  # ---- SECRET_KEY ------------------------------------------------------------------------------------------
  OLD_KEY=""
  [ -f "$NODE_DIR/docker-compose.yml" ] && \
    OLD_KEY=$(grep -oE 'SECRET_KEY=.*' "$NODE_DIR/docker-compose.yml" | head -1 | sed 's/SECRET_KEY=//')
  if [ "$USE_API" = "1" ]; then
    # Ключ ноды общий для панели — берём по API, вставлять вручную не нужно.
    SECRET_KEY="$(fetch_secret_key)" || exit 1
    [ -n "$SECRET_KEY" ] || { err "Панель не вернула SECRET_KEY."; exit 1; }
    ok "SECRET_KEY получен от панели по API"
  else
    while true; do
      if [ -n "$OLD_KEY" ]; then
        SECRET_KEY=$(ask_value "SECRET_KEY ноды (Enter — оставить текущий)" "${SECRET_KEY:-}")
      else
        SECRET_KEY=$(ask_value "SECRET_KEY ноды (из панели Remnawave, обязателен)" "${SECRET_KEY:-}")
      fi
      # Убираем случайные кавычки/переводы строк — частая причина "Invalid SECRET_KEY payload"
      SECRET_KEY=$(echo -n "$SECRET_KEY" | sed -E 's/^"+//; s/"+$//' | tr -d '\r\n')
      if [ -n "$SECRET_KEY" ] || [ -n "$OLD_KEY" ]; then break; fi
      err "SECRET_KEY не может быть пустым."
      [ "${ASSUME_YES:-0}" = "1" ] && exit 1
    done
  fi
  else
    NODE_PORT=""
  fi   # HAS_XRAY
else
  HAS_XRAY=0; USE_TG=0; USE_WEB=0; WEB_SERVER="$(ws_current)"
  DOMAIN_TCP=""; DOMAIN_GRPC=""; DOMAIN_XHTTP=""; DOMAIN_HY2=""; DOMAIN_TG=""; DOMAIN_WEB=""
  USE_HY2=0; USE_BBR=0; OPEN_NODE_PORT=0; NODE_PORT=""
  PANEL_IP=$(ask_valid "IP панели (если нужно ограничить доступ, Enter — пропустить)" "${PANEL_IP:-}" is_valid_ip 1) || exit 1
fi

if ask_yes_no "Ежедневная перезагрузка сервера в 04:00 (${DORIK_TZ})?" "1"; then
  ENABLE_REBOOT=1
else
  ENABLE_REBOOT=0
fi

# Закрытие лишних портов и укрепление: firewall без лишних правил, отключение ненужных
# служб, защита ядра и SSH, автообновления безопасности.
SSH_PW_OFF=0
if ask_yes_no "Закрыть все лишние порты и укрепить систему (рекомендуется)?" "1"; then
  DO_HARDEN=1
  # Вход по паролю отключаем только при наличии ключей и только по явному согласию.
  if [ "$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')" = "no" ]; then
    info "Вход по паролю в SSH уже отключён — останется отключённым."
    SSH_PW_OFF=1
  elif _has_ssh_keys; then
    if [ "${ASSUME_YES:-0}" = "1" ]; then
      SSH_PW_OFF="${SSH_DISABLE_PASSWORD:-0}"
    elif ask_yes_no "Отключить вход по паролю в SSH (только по ключу)? Убедитесь, что вход по ключу у вас работает" "2"; then
      SSH_PW_OFF=1
    fi
  fi
else
  DO_HARDEN=0
fi

# Защита от сканеров: HAProxy отбрасывает чужой SNI и не-TLS, лимит соединений с одного IP,
# усиленный REALITY в профиле и бан перебора портов (последнее — вместе с укреплением).
if [ "${SCAN_PROTECT:-}" = "" ]; then
  if ask_yes_no "Включить защиту от сканеров (рекомендуется)?" "1"; then SCAN_PROTECT=1; else SCAN_PROTECT=0; fi
fi
export SCAN_PROTECT

# Блок-лист сетей сканеров: пакеты от них отбрасываются до HAProxy/Xray (ipset, список обновляется
# раз в сутки). Ваш SSH-адрес и IP панели добавляются в исключения. Подробности — scanblock.sh.
if [ "${SCAN_BLOCKLIST:-}" = "" ]; then
  if [ "$SCAN_PROTECT" = "1" ] && ask_yes_no "Не отвечать сетям сканеров по блок-листу (обновляется раз в сутки)?" "1"; then SCAN_BLOCKLIST=1; else SCAN_BLOCKLIST=0; fi
fi
export SCAN_BLOCKLIST

# ---- план выполнения: что именно сейчас будет сделано ------------------------
yn() { [ "$1" = "1" ] && echo "да" || echo "нет"; }
PROTO_LIST=""
if [ "$ROLE" = "1" ]; then
  for i in "${!PROTO_KEYS[@]}"; do [ "${PROTO_STATE[$i]}" = "1" ] && PROTO_LIST+="${PROTO_LIST:+, }${PROTO_LABELS[$i]}"; done
fi
echo
box_top "План выполнения"
box_row "Роль:               $([ "$ROLE" = "1" ] && echo "нода" || echo "сервер панели (только защита)")"
if [ "$ROLE" = "1" ]; then
  box_wrap "Протоколы:        " "$PROTO_LIST"
  box_row "Веб-сервер:         $(ws_label "$WEB_SERVER") ${C_DIM}(заглушки self-steal)${C_RESET}"
fi
if [ "$NEW_SSH_PORT" != "$CUR_SSH_PORT" ]; then
  box_row "SSH-порт:           ${CUR_SSH_PORT} → ${C_BOLD}${NEW_SSH_PORT}${C_RESET}"
else
  box_row "SSH-порт:           ${NEW_SSH_PORT} (без изменений)"
fi
if [ "$ROLE" = "1" ]; then
  box_wrap "Домены:           " "${DOMAIN_TCP:+${DOMAIN_TCP} }${DOMAIN_GRPC:+${DOMAIN_GRPC} }${DOMAIN_XHTTP:+${DOMAIN_XHTTP} }${DOMAIN_HY2:+${DOMAIN_HY2} }${DOMAIN_TG:+${DOMAIN_TG} }${DOMAIN_WEB:+${DOMAIN_WEB} (WEB-прокси)}"
  if [ "$USE_API" = "1" ]; then
    box_row "Профиль на панели: ${C_BOLD}${PROFILE_NAME}${C_RESET}  ${C_DIM}(хосты + SECRET_KEY по API)${C_RESET}"
    box_row "                    $([ "$PROFILE_CREATE_NODE" = "1" ] && echo "нода на панели создаётся" || echo "ноду на панели создадите сами")$([ -n "$DOMAIN_TG" ] && echo "; есть Telegram-хост")"
  elif [ "$HAS_XRAY" = "1" ]; then
    box_row "Профиль на панели: ${C_DIM}нет (конфиг добавите вручную)${C_RESET}"
  fi
  [ "$HAS_XRAY" = "1" ] && box_row "Порт ноды:          ${NODE_PORT}$([ "$OPEN_NODE_PORT" = "1" ] && echo " (открыт$([ -n "$PANEL_IP" ] && echo " только для ${PANEL_IP}"))" || echo " (в firewall не открывается)")"
  box_row "Hysteria2:          $(yn "$USE_HY2")    Заглушки: $(yn "$INSTALL_DECOY")    BBR: $(yn "$USE_BBR")"
  box_row "                    ${C_DIM}по одной заглушке на каждый протокол, все разные${C_RESET}"
fi
box_row "Ребут в 04:00:      $(yn "$ENABLE_REBOOT")    Часовой пояс: ${DORIK_TZ}"
box_row "Укрепление:         $(yn "$DO_HARDEN")    Вход по паролю SSH выключить: $(yn "$SSH_PW_OFF")"
box_row "Защита сканеров:    $(yn "$SCAN_PROTECT")    Блок-лист сетей сканеров: $(yn "$SCAN_BLOCKLIST")"
box_bottom

echo
warn "Все вопросы заданы. Дальше скрипт выполнит все шаги подряд БЕЗ остановок."
if [ "$NEW_SSH_PORT" != "$CUR_SSH_PORT" ]; then
  warn "SSH переедет с порта ${CUR_SSH_PORT} на ${NEW_SSH_PORT}. Текущая сессия не оборвётся, но следующее подключение — только на ${NEW_SSH_PORT}."
fi
if ! ask_yes_no "Начать выполнение сейчас?" "1"; then
  err "Отменено пользователем."
  exit 1
fi

# ---------------------------------------------------------------------------
# Пайплайн: этапы с общим прогрессом и проверкой результата
# ---------------------------------------------------------------------------
FAIL_LOG=()
STEP_NO=0
if [ "$ROLE" = "1" ]; then
  TOTAL_STEPS=5; [ "$USE_BBR" = "1" ] && TOTAL_STEPS=6
  [ "$HAS_XRAY" = "1" ] && TOTAL_STEPS=$((TOTAL_STEPS+1))     # Remnanode
else
  TOTAL_STEPS=4
fi
[ "$DO_HARDEN" = "1" ] && TOTAL_STEPS=$((TOTAL_STEPS+1))
[ "$SCAN_BLOCKLIST" = "1" ] && TOTAL_STEPS=$((TOTAL_STEPS+1))
[ "${USE_API:-0}" = "1" ] && TOTAL_STEPS=$((TOTAL_STEPS+1))
[ "${USE_API:-0}" = "1" ] && [ "${PROFILE_CREATE_NODE:-0}" = "1" ] && TOTAL_STEPS=$((TOTAL_STEPS+1))
[ "$ROLE" = "1" ] && [ "${USE_WEB:-0}" = "1" ] && TOTAL_STEPS=$((TOTAL_STEPS+1))

# run_step "Название" функция_этапа [функция_проверки]
run_step() {
  local title="${1:-step}" fn="$2" vfn="${3:-}" failed=0
  STEP_NO=$((STEP_NO+1))
  step_n "$STEP_NO" "$TOTAL_STEPS" "$title"
  export DORIK_NESTED=1
  "$fn" || failed=1
  export DORIK_NESTED=0
  if [ -n "$vfn" ]; then
    echo -e "  ${C_DIM}── проверка результата ──${C_RESET}"
    "$vfn" || failed=1
  fi
  if [ "$failed" -eq 0 ]; then
    ok "${C_BOLD}${title}${C_RESET} — выполнено и проверено"
  else
    err "${title} — ОШИБКА (продолжаю дальше, см. итог в конце)"
    FAIL_LOG+=("$title")
  fi
}

# ---------------------------------------------------------------------------
# ЭТАП. Обновление пакетов
# ---------------------------------------------------------------------------
do_apt() { apt_upgrade_smart; }
run_step "Обновление пакетов" do_apt verify_apt

# ---------------------------------------------------------------------------
# ЭТАП. SSH (безопасная миграция порта) + firewall + fail2ban + таймзона + ребут
# ---------------------------------------------------------------------------
do_ssh_harden() {
  if [ "${NEW_SSH_PORT}" = "${CUR_SSH_PORT}" ]; then
    ok "SSH порт не меняется (${CUR_SSH_PORT})."
    ufw allow "${CUR_SSH_PORT}/tcp" comment "SSH" &>/dev/null || true
    return 0
  fi

  info "Меняю SSH порт ${CUR_SSH_PORT} -> ${NEW_SSH_PORT}"
  # Сначала открываем новый порт в ufw, потом двигаем sshd: иначе при включении
  # firewall'а позже новый порт оказался бы закрыт.
  ufw allow "${NEW_SSH_PORT}/tcp" comment "SSH" &>/dev/null || true
  if ssh_apply_port "${NEW_SSH_PORT}"; then
    ok "Новый SSH порт ${NEW_SSH_PORT}: реально работает (не просто слушает, а живой sshd)."
    ufw_close_port "${CUR_SSH_PORT}"
  else
    err "Порт не переехал — SSH остался на ${CUR_SSH_PORT}."
    ufw_close_port "${NEW_SSH_PORT}"
    NEW_SSH_PORT="${CUR_SSH_PORT}"
    ssh_selfheal "${CUR_SSH_PORT}" || true
    return 1
  fi
}

do_protect_common() {
  local rc=0
  if ! command -v ufw &>/dev/null; then
    apt_install ufw || { err "ufw не установился — firewall НЕ настроен."; rc=1; }
  fi

  if command -v ufw &>/dev/null; then
    ufw default deny incoming &>/dev/null || true
    ufw default allow outgoing &>/dev/null || true
    ufw allow "${NEW_SSH_PORT}/tcp" comment "SSH" &>/dev/null || true

    if [ "$ROLE" = "1" ]; then
      ufw allow 80/tcp comment "HTTP (certbot)" &>/dev/null || true
      ufw allow 443/tcp comment "HTTPS TCP" &>/dev/null || true
      [ "$USE_HY2" = "1" ] && { ufw allow 443/udp comment "Hysteria2" &>/dev/null || true; }
      if [ "$OPEN_NODE_PORT" = "1" ]; then
        # Прежние правила «Node panel» (от прошлого запуска — другой порт, другой IP или
        # «для всех») убираем: иначе смена порта оставит дыру, а старое правило «для
        # всех» сведёт на нет ограничение по IP панели.
        ufw_delete_matching 'Node panel'
        if [ -n "$PANEL_IP" ]; then
          ufw allow from "$PANEL_IP" to any port "${NODE_PORT}" proto tcp comment "Node panel" &>/dev/null || true
        else
          ufw allow "${NODE_PORT}/tcp" comment "Node panel" &>/dev/null || true
        fi
      fi
    else
      ufw allow 80/tcp comment "HTTP" &>/dev/null || true
      ufw allow 443/tcp comment "HTTPS" &>/dev/null || true
      ufw_delete_matching "3001"
    fi
    ufw --force enable &>/dev/null || { err "ufw не включился."; rc=1; }
  fi

  # fail2ban: backend=systemd обязателен на Ubuntu 24.04/Debian 12 — там нет
  # /var/log/auth.log, и без него jail sshd не стартует вовсе.
  install_fail2ban || { err "fail2ban не установился."; rc=1; }
  if [ -d /etc/fail2ban ]; then
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = ${NEW_SSH_PORT}
backend  = systemd
maxretry = 3
findtime = 1h
bantime  = 1d
EOF
    systemctl enable fail2ban &>/dev/null || true
    systemctl restart fail2ban 2>&1 || { err "fail2ban не перезапустился (journalctl -u fail2ban)."; rc=1; }
  fi

  timedatectl set-timezone "${DORIK_TZ}" 2>&1 || warn "Не удалось выставить таймзону ${DORIK_TZ}."

  # Старая запись в crontab root (прежние версии скрипта) -> /etc/cron.d
  if command -v crontab &>/dev/null; then
    crontab -l 2>/dev/null | grep -q 'shutdown -r now' && \
      { crontab -l 2>/dev/null | grep -v 'shutdown -r now' | crontab - || true; }
  fi
  if [ "$ENABLE_REBOOT" = "1" ]; then
    echo "0 4 * * * root /sbin/shutdown -r now" > /etc/cron.d/dorik-reboot
    chmod 644 /etc/cron.d/dorik-reboot
    systemctl enable --now cron &>/dev/null || true
  else
    rm -f /etc/cron.d/dorik-reboot
  fi
  return $rc
}

do_ssh_and_protect() { do_ssh_harden; local a=$?; do_protect_common; local b=$?; return $((a|b)); }
vf_ssh_and_protect() {
  local rc=0
  verify_ssh "$NEW_SSH_PORT" || rc=1
  verify_firewall "$NEW_SSH_PORT" "$ROLE" "$USE_HY2" "$([ "$OPEN_NODE_PORT" = "1" ] && echo "$NODE_PORT")" "$ENABLE_REBOOT" || rc=1
  return $rc
}
run_step "SSH, firewall, fail2ban, расписание" do_ssh_and_protect vf_ssh_and_protect

# ---------------------------------------------------------------------------
# Дальше — только для роли "нода"
# ---------------------------------------------------------------------------
if [ "$ROLE" = "1" ]; then

  do_nginx_haproxy() {
    local src; src="$(get_script haproxy-setup.sh)" || { err "Не удалось получить haproxy-setup.sh"; return 1; }
    DOMAIN_TCP="$DOMAIN_TCP" DOMAIN_GRPC="$DOMAIN_GRPC" DOMAIN_XHTTP="$DOMAIN_XHTTP" \
    DOMAIN_HY2="$DOMAIN_HY2" USE_HY2="$USE_HY2" DOMAIN_TG="$DOMAIN_TG" USE_TG="$USE_TG" \
    DOMAIN_WEB="$DOMAIN_WEB" USE_WEB="$USE_WEB" WEB_SERVER="$WEB_SERVER" \
    INSTALL_DECOY="$INSTALL_DECOY" NONINTERACTIVE=1 bash "$src"
  }
  run_step "$(ws_label "$WEB_SERVER") (self-steal) + HAProxy + сертификаты" do_nginx_haproxy

  if [ "$USE_BBR" = "1" ]; then
    do_bbr() {
      local src; src="$(get_script bbr-install.sh)" || { err "Не удалось получить bbr-install.sh"; return 1; }
      NONINTERACTIVE=1 bash "$src"
    }
    run_step "BBR + сетевая оптимизация" do_bbr
  fi

  # Профиль и хосты создаём ДО запуска ноды: заглушки и сертификаты уже готовы, а панель,
  # получив ноду с привязанным профилем, сама подключится к ней, как только та поднимется.
  if [ "${USE_API:-0}" = "1" ]; then
    do_profile() { profile_apply; }
    run_step "Профиль и хосты на панели (API)" do_profile
  fi

  do_remnanode() {
    local src; src="$(get_script remnanode-setup.sh)" || { err "Не удалось получить remnanode-setup.sh"; return 1; }
    NODE_PORT="$NODE_PORT" USE_HY2="$USE_HY2" SECRET_KEY="$SECRET_KEY" \
      DOMAIN_HY2="$DOMAIN_HY2" NONINTERACTIVE=1 bash "$src"
  }
  [ "$HAS_XRAY" = "1" ] && run_step "Remnanode (Docker$([ "$USE_HY2" = "1" ] && echo " + Hysteria2"))" do_remnanode

  if [ "${USE_API:-0}" = "1" ] && [ "${PROFILE_CREATE_NODE:-0}" = "1" ]; then
    do_node_link() {
      if spin_run "Подключение ноды к панели (до 2 минут)" wait_node_connected 120; then
        ok "Панель подключилась к ноде, Xray запущен с конфигом профиля"
        return 0
      fi
      err "Панель не подключилась к ноде за 2 минуты."
      warn "Проверьте: порт ноды ${NODE_PORT} открыт для IP панели; адрес ноды на панели верный; docker logs remnanode --tail 30"
      return 1
    }
    run_step "Подключение ноды к панели" do_node_link
  fi

  # WEB-прокси Telegram: домен, сертификат, nginx-сайт и маршрут HAProxy уже сделал этап nginx/HAProxy
  # (домен передан в DOMAIN_WEB), здесь ставится только Telemt.
  if [ "${USE_WEB:-0}" = "1" ]; then
    do_webproxy() {
      local src; src="$(get_script webproxy-setup.sh)" || { err "Не удалось получить webproxy-setup.sh"; return 1; }
      DOMAIN_WEB="$DOMAIN_WEB" WEB_AD_TAG="$WEB_AD_TAG" WEB_SECRET="$WEB_SECRET" WEB_FRONT_DONE=1 WEB_NONINTERACTIVE=1 bash "$src" install
    }
    run_step "WEB-прокси Telegram (Telemt)" do_webproxy
  fi

fi

# ---------------------------------------------------------------------------
# Закрытие лишних портов и укрепление (после установки сервисов — тогда известно,
# какие порты действительно нужны)
# ---------------------------------------------------------------------------
if [ "$DO_HARDEN" = "1" ]; then
  # Нужные порты объявляем один раз на весь запуск: их используют и сам этап укрепления,
  # и итоговая перепроверка — иначе она «критиковала» бы результат, не зная выбранной роли.
  HARDEN_EXPECT="${NEW_SSH_PORT}/tcp 80/tcp 443/tcp"
  if [ "$ROLE" = "1" ]; then
    [ "$USE_HY2" = "1" ] && HARDEN_EXPECT+=" 443/udp"
    [ "$OPEN_NODE_PORT" = "1" ] && HARDEN_EXPECT+=" ${NODE_PORT}/tcp"
  fi
  export HARDEN_EXPECT
  do_harden() { SSH_DISABLE_PASSWORD="$SSH_PW_OFF" harden_run; }
  run_step "Закрытие лишних портов и укрепление" do_harden
fi

# ---------------------------------------------------------------------------
# Блок-лист сетей сканеров (после firewall: правило ставится перед цепочками ufw)
# ---------------------------------------------------------------------------
if [ "$SCAN_BLOCKLIST" = "1" ]; then
  do_scanblock() { PANEL_IP="${PANEL_IP:-}" scanblock_on; }
  run_step "Блок-лист сетей сканеров" do_scanblock
fi

# ---------------------------------------------------------------------------
# Финальная страховочная проверка SSH
# ---------------------------------------------------------------------------
# Промежуточные шаги (apt install nginx/haproxy/certbot, docker install)
# тоже дёргают apt — перепроверяем SSH ещё раз в самом конце.
do_final_ssh() { ssh_selfheal "${NEW_SSH_PORT}"; }
run_step "Финальная проверка SSH" do_final_ssh

# Последний этап — независимая перепроверка всего сервера тем же «врачом»:
# если после установки что-то не так, это видно сразу, а не при первой проблеме.
do_final_audit() {
  doctor_scan
  show_dashboard
  # Осознанный отказ пользователя (BBR) замечанием не считаем.
  local id left=()
  for id in "${ISSUE_IDS[@]}"; do
    [ "$id" = "net_tuning" ] && [ "${USE_BBR:-0}" != "1" ] && continue
    case "$id" in ports_exposed|hardening_missing|shield_missing|ufw_ipv6) [ "${DO_HARDEN:-0}" != "1" ] && continue ;; esac
    left+=("$id")
  done
  [ "${#left[@]}" -eq 0 ] && return 0
  for id in "${left[@]}"; do err "${ISSUE_TXT[$id]}"; done
  warn "Исправить автоматически: меню → «Проверка и исправление проблем»."
  return 1
}
run_step "Итоговая перепроверка сервера" do_final_audit

# ---------------------------------------------------------------------------
# Итог
# ---------------------------------------------------------------------------
echo
if [ "${#FAIL_LOG[@]}" -eq 0 ]; then
  box_top "Готово"
  box_row "${C_G}✔${C_RESET} Все этапы выполнены и проверены без ошибок."
else
  box_top "Готово, но есть замечания"
  for f in "${FAIL_LOG[@]}"; do box_row "${C_R}✖${C_RESET} ${f}"; done
  box_row "${C_DIM}Скрипт идемпотентен — можно запустить повторно.${C_RESET}"
fi
box_sep
box_row "SSH-порт:        ${C_BOLD}${NEW_SSH_PORT}${C_RESET}"
if [ "$ROLE" = "1" ]; then
  box_wrap "Протоколы:     " "$PROTO_LIST"
  if [ "$HAS_XRAY" = "1" ] && [ "${PROFILE_CREATE_NODE:-0}" != "1" ]; then
    box_wrap "${C_DIM}→${C_RESET}" "Дальше: в панели Remnawave добавьте ноду (адрес сервера, порт ${NODE_PORT})."
  fi
fi
box_row "${C_DIM}Отчёт о сервере: команда ${C_RESET}${C_BOLD}dorik report${C_RESET}"
if [ -f /var/run/reboot-required ]; then
  box_row "${C_Y}▲ Нужна перезагрузка для обновлений ядра: reboot${C_RESET}"
fi
box_row "${C_DIM}Лог: ${DORIK_LOG}${C_RESET}"
box_bottom

# Итог запуска — для пункта «Отчёт» (без секретов: только что ставили и чем закончилось).
mkdir -p /var/lib/dorik
{
  echo "Дата: $(date '+%F %T %Z')"
  echo "Роль: $([ "$ROLE" = "1" ] && echo "нода" || echo "сервер панели")"
  if [ "$ROLE" = "1" ]; then
    echo "Протоколы: ${PROTO_LIST}"
    echo "Веб-сервер: $(ws_label "$WEB_SERVER")"
  fi
  echo "SSH-порт: ${NEW_SSH_PORT}"
  echo "Укрепление: $(yn "$DO_HARDEN") · защита от сканеров: $(yn "$SCAN_PROTECT") · блок-лист: $(yn "$SCAN_BLOCKLIST")"
  echo "Этапов выполнено: ${STEP_NO}, с ошибками: ${#FAIL_LOG[@]}"
  for f in "${FAIL_LOG[@]}"; do echo "  ошибка: ${f}"; done
  echo "Лог: ${DORIK_LOG}"
} > /var/lib/dorik/last-run.txt 2>/dev/null || true

[ "${#FAIL_LOG[@]}" -eq 0 ]
