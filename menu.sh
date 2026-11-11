#!/usr/bin/env bash
# DORIK — точка входа. Работает на чистой Ubuntu/Debian: сам скачивает
# тулкит, ставит нужные пакеты и запускает настройку.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main/menu.sh)
#
# После первого запуска меню открывается командой:   dorik
#
# Параметры (запуск без меню; два дефиса можно не писать: «dorik report» = «dorik --report»):
#   --full           полная настройка сервера (нода или панель)
#   --doctor         проверка и исправление последствий старых версий
#   --profile        создать профиль и хосты на панели по API
#   --harden         закрыть лишние порты и укрепить сервер (--ports — только показать порты)
#   --shield         блок-лист сетей сканеров: --shield on|update|status|off
#   --web            WEB-прокси Telegram (установка/ссылка/тег/удаление: --web status|link|tag <тег>|remove)
#   --update-node    обновить ноду          --bbr   BBR + сетевая оптимизация
#   --panel-install  установить панель      --panel-update  обновить панель
#   --sub            страница подписки      --sub-update    обновить страницу
#   --hy2-port       сменить UDP-порт Hysteria2 (--hy2-port show — показать текущий)
#   --report         отчёт о сервере (--report last — прошлый, --report log — журнал, --report print — в вывод)
#   --status         показать состояние сервера
#   --update         обновить сам тулкит до свежей версии
# Без вопросов (cloud-init):  ASSUME_YES=1 DOMAIN_TCP=... SECRET_KEY=... bash menu.sh --full
set -uo pipefail

# Переменные можно переопределить — для форка или проверки другой ветки.
GH_USER="${GH_USER:-KimHarada}"
GH_REPO="${GH_REPO:-Remnawave-autoinstall-scriots}"
INSTALL_DIR="${DORIK_DIR:-/opt/dorik-toolkit}"
# Ветка: из окружения, иначе та, с которой тулкит ставили в прошлый раз, иначе main.
GH_BRANCH="${GH_BRANCH:-$(cat "${INSTALL_DIR}/.dorik-branch" 2>/dev/null || true)}"
GH_BRANCH="${GH_BRANCH:-main}"
DORIK_RAW="${DORIK_RAW:-https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${GH_BRANCH}}"
TARBALL_URL="${DORIK_TARBALL_URL:-https://github.com/${GH_USER}/${GH_REPO}/archive/refs/heads/${GH_BRANCH}.tar.gz}"
DORIK_BIN="${DORIK_BIN:-/usr/local/bin/dorik}"
export DORIK_RAW

die() { echo -e "\e[31m✖\e[0m $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Запустите от root: sudo -i, затем повторите команду."
command -v apt-get >/dev/null 2>&1 || die "Нужна Ubuntu/Debian (apt-get не найден)."

# ---- где лежат скрипты ------------------------------------------------------
# Запуск из git-чекаута -> берём скрипты рядом. Запуск через curl/<(...) ->
# скачиваем репозиторий целиком ОДИН раз (а не по файлу на каждый шаг).
download_repo() {
  local tmp f
  tmp="$(mktemp -d)" || return 1
  if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
    echo "• Ставлю curl/tar..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq -o DPkg::Lock::Timeout=120 >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o DPkg::Lock::Timeout=120 curl ca-certificates tar gzip >/dev/null 2>&1 || true
  fi
  echo "• Скачиваю тулкит (${GH_USER}/${GH_REPO}@${GH_BRANCH})..."
  if curl -fsSL --retry 3 --retry-delay 2 "$TARBALL_URL" \
     | tar -xz --strip-components=1 -C "$tmp" 2>/dev/null && [ -f "$tmp/scripts/lib.sh" ] && [ -f "$tmp/menu.sh" ]; then
    :
  else
    # запасной путь: по одному файлу из raw
    echo "▲ Архив не скачался — пробую по файлам."
    rm -rf "$tmp"; tmp="$(mktemp -d)"; mkdir -p "$tmp/scripts"
    curl -fsSL --retry 3 "${DORIK_RAW}/menu.sh" -o "$tmp/menu.sh" || { rm -rf "$tmp"; return 1; }
    for f in lib.sh ui.sh tui.sh webserver.sh state.sh harden.sh decoys.sh profile-setup.sh doctor.sh preflight.sh full-setup.sh \
             bbr-install.sh haproxy-setup.sh remnanode-setup.sh node-update.sh panel-install.sh fix-ssh-access.sh \
             webproxy-setup.sh scanblock.sh report.sh hy2-port.sh; do
      curl -fsSL --retry 3 "${DORIK_RAW}/scripts/${f}" -o "$tmp/scripts/${f}" || { rm -rf "$tmp"; return 1; }
    done
  fi
  echo "$GH_BRANCH" > "$tmp/.dorik-branch"
  chmod 755 "$tmp"
  find "$tmp" -name '*.sh' -exec chmod 755 {} +
  rm -rf "${INSTALL_DIR}.old"
  [ -d "$INSTALL_DIR" ] && mv "$INSTALL_DIR" "${INSTALL_DIR}.old"
  mv "$tmp" "$INSTALL_DIR" || return 1
  rm -rf "${INSTALL_DIR}.old"
}

# Команда «dorik»: короткий запуск меню из любого каталога.
install_cmd() {  # install_cmd <путь к menu.sh> [force]
  local target="$1" force="${2:-0}" want
  want="#!/usr/bin/env bash
# DORIK toolkit — запуск меню одной командой. Файл создан menu.sh.
exec bash \"${target}\" \"\$@\""
  # Уже есть команда, указывающая на установленный тулкит, — запуск из другого каталога её не трогает.
  [ "$force" = "1" ] || [ ! -f "$DORIK_BIN" ] || [ "$target" = "${INSTALL_DIR}/menu.sh" ] || return 0
  [ -f "$DORIK_BIN" ] && [ "$(cat "$DORIK_BIN" 2>/dev/null)" = "$want" ] && return 0
  mkdir -p "$(dirname "$DORIK_BIN")" 2>/dev/null
  printf '%s\n' "$want" > "$DORIK_BIN" 2>/dev/null && chmod 755 "$DORIK_BIN"
}

# Первый параметр без дефисов («dorik report») понимаем как параметр с дефисами («--report»).
ARG="${1:-}"
case "$ARG" in ""|-*) ;; *) ARG="--${ARG}" ;; esac

SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [ "$ARG" = "--update" ]; then
  download_repo || die "Не удалось скачать тулкит с GitHub. Проверьте сеть и доступ к github.com."
  install_cmd "${INSTALL_DIR}/menu.sh" 1
  echo -e "\e[32m✔\e[0m Тулкит обновлён до версии $(sed -nE 's/^DORIK_VERSION="([^"]+)".*/\1/p' "${INSTALL_DIR}/scripts/lib.sh") (ветка ${GH_BRANCH}). Запуск: dorik"
  exit 0
fi

if [ -n "$SELF_DIR" ] && [ -f "${SELF_DIR}/scripts/lib.sh" ]; then
  SCRIPTS_DIR="${SELF_DIR}/scripts"
  install_cmd "${SELF_DIR}/menu.sh"
else
  download_repo || die "Не удалось скачать тулкит с GitHub. Проверьте сеть и доступ к github.com."
  SCRIPTS_DIR="${INSTALL_DIR}/scripts"
  install_cmd "${INSTALL_DIR}/menu.sh" 1
fi

SCRIPT_DIR="$SCRIPTS_DIR"
# shellcheck disable=SC1091
source "${SCRIPTS_DIR}/lib.sh" || die "Не удалось загрузить lib.sh"
# shellcheck disable=SC1091
source "${SCRIPTS_DIR}/state.sh"
# shellcheck disable=SC1091
source "${SCRIPTS_DIR}/harden.sh"
# shellcheck disable=SC1091
source "${SCRIPTS_DIR}/doctor.sh"
# shellcheck disable=SC1091
source "${SCRIPTS_DIR}/decoys.sh"
# shellcheck disable=SC1091
source "${SCRIPTS_DIR}/scanblock.sh"
# shellcheck disable=SC1091
source "${SCRIPTS_DIR}/report.sh"

run_script() {
  local name="${1:?script name}"; shift
  if [ -t 0 ]; then
    bash "${SCRIPTS_DIR}/${name}" "$@"
  else
    # stdin — pipe (curl | bash): дочерний скрипт не должен читать из него, иначе
    # съест оставшийся текст родителя. Вопросы он задаёт через /dev/tty.
    bash "${SCRIPTS_DIR}/${name}" "$@" </dev/null
  fi
}

pause() {
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  echo
  read -r -p "$(echo -e "${C_DIM}Enter — вернуться в меню${C_RESET} ")" _ <"$(prompt_input)" || true
}

# ---- запуск без меню ----------------------------------------------------------
[ $# -gt 0 ] && shift
case "$ARG" in
  --full)          run_script full-setup.sh; exit $? ;;
  --bbr)           run_script bbr-install.sh; exit $? ;;
  --doctor)        run_script doctor.sh; exit $? ;;
  --profile)       run_script profile-setup.sh; exit $? ;;
  --web)           run_script webproxy-setup.sh "$@"; exit $? ;;
  --harden)        run_script harden.sh; exit $? ;;
  --ports)         run_script harden.sh --audit; exit $? ;;
  --shield)        run_script scanblock.sh "${1:-status}"; exit $? ;;
  --update-node)   run_script node-update.sh; exit $? ;;
  --panel-install) run_script panel-install.sh install; exit $? ;;
  --panel-update)  run_script panel-install.sh update; exit $? ;;
  --sub)           run_script panel-install.sh sub; exit $? ;;
  --sub-update)    run_script panel-install.sh sub-update; exit $? ;;
  --report)        run_script report.sh "${1:-new}"; exit $? ;;
  --hy2-port)      run_script hy2-port.sh "$@"; exit $? ;;
  --status)        banner; show_dashboard; exit 0 ;;
  --help|-h)       sed -n '2,24p' "${BASH_SOURCE[0]:-$0}" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) die "Неизвестный параметр: ${ARG#--} (список: dorik --help)" ;;
esac

ensure_tty
NL=$'\n'

# ---- помощники меню -------------------------------------------------------------
# menu_desc <текст> [названия пунктов сводки...] — описание пункта + состояние связанных компонентов.
menu_desc() {
  local text="$1" name i out=""; shift
  for name in "$@"; do
    for i in "${!DASH_N[@]}"; do
      [ "${DASH_N[$i]}" = "$name" ] || continue
      tui_status_row "${DASH_L[$i]}" "$name" "${DASH_T[$i]}"
      out+="${NL}${REPLY}"
    done
  done
  REPLY="${text}${out:+${NL}${NL}@СОСТОЯНИЕ${out}}"
}

# menu_mark <названия пунктов сводки...> — пометка справа от пункта меню: худшее из состояний.
menu_mark() {
  local name i worst=""
  for name in "$@"; do
    for i in "${!DASH_N[@]}"; do
      [ "${DASH_N[$i]}" = "$name" ] || continue
      case "${DASH_L[$i]}" in
        bad)  worst="bad" ;;
        warn) [ "$worst" = "bad" ] || worst="warn" ;;
        ok)   [ -n "$worst" ] || worst="ok" ;;
      esac
    done
  done
  case "$worst" in
    bad)  REPLY="${C_R}✖${C_RESET}" ;;
    warn) REPLY="${T_ORG}▲${C_RESET}" ;;
    ok)   REPLY="${C_G}✓${C_RESET}" ;;
    *)    REPLY="" ;;
  esac
}

self_update() {
  download_repo || { err "Не удалось скачать тулкит с GitHub."; return 1; }
  install_cmd "${INSTALL_DIR}/menu.sh" 1
  ok "Тулкит обновлён (ветка ${GH_BRANCH}) — перезапускаю меню."
  sleep 1
  exec bash "${INSTALL_DIR}/menu.sh"
}

# ---- меню -------------------------------------------------------------------------
main_menu() {
  local -a MM_L MM_D MM_K MM_M
  local sel=0 refresh=1
  MM_L=("Полная настройка сервера" "Панель Remnawave" "Профиль и хосты на панели" "Обновить ноду" "Защита и порты"
        "Проверка и исправление" "WEB-прокси Telegram" "Отчёт" "Дополнительно" "Состояние сервера" "Обновить тулкит")
  MM_K=(1 2 3 4 5 6 7 8 9 s u)
  while true; do
    if [ "$refresh" = "1" ]; then tui_splash; refresh=0; fi
    tui_dims
    MM_D=(); MM_M=()
    menu_desc "Настройка сервера с нуля — ноды или сервера панели. Сначала вы отмечаете, какие протоколы ставить (REALITY TCP, gRPC, XHTTP, Hysteria2, Telegram-хост, WEB-прокси), затем вводите домены только для выбранных и выбираете веб-сервер заглушек — Nginx или Caddy. Все вопросы задаются один раз, дальше установка идёт сама, с проверкой каждого этапа." \
      "Система" "SSH" "Веб-сервер" "Сертификаты" "Нода Remnanode"; MM_D+=("$REPLY")
    menu_mark "Веб-сервер" "Сертификаты" "Нода Remnanode"; MM_M+=("$REPLY")
    menu_desc "Установка и обновление панели Remnawave и страницы подписки. Перед панелью ставится Nginx или Caddy с сертификатом; панель можно скрыть за секретной ссылкой." \
      "Панель Remnawave" "Страница подп." "Docker"; MM_D+=("$REPLY")
    menu_mark "Панель Remnawave" "Страница подп."; MM_M+=("$REPLY")
    menu_desc "Создаёт на панели профиль Xray с оптимизированным конфигом, хосты для каждого выбранного протокола и ноду этого сервера — по API, без ручного копирования. У каждого протокола свои ключи, shortId, отпечаток и заглушка." \
      "Профиль панели" "Нода Remnanode"; MM_D+=("$REPLY")
    menu_mark "Профиль панели"; MM_M+=("$REPLY")
    menu_desc "Обновляет контейнер Remnanode до свежего образа и проверяет, что нода поднялась и слушает свой порт." \
      "Нода Remnanode" "Docker"; MM_D+=("$REPLY")
    menu_mark "Нода Remnanode"; MM_M+=("$REPLY")
    menu_desc "Закрывает лишние порты, укрепляет ядро и SSH, включает автообновления безопасности. Защита от сканеров: бан перебора портов и блок-лист сетей, с которых ведётся зондирование." \
      "Firewall (ufw)" "fail2ban" "Щит сканеров" "Открытые порты"; MM_D+=("$REPLY")
    menu_mark "Firewall (ufw)" "fail2ban" "Щит сканеров" "Открытые порты"; MM_M+=("$REPLY")
    menu_desc "Ищет неполадки и последствия старых версий скрипта: остановленные службы, истекающие сертификаты, незакрытые порты, сломанные правила. Найденное предлагает исправить." \
      "Проверка"; MM_D+=("$REPLY")
    menu_mark "Проверка"; MM_M+=("$REPLY")
    menu_desc "Прокси Telegram типа «WEB» (Telemt) на отдельном домене с рекламой вашего канала через @MTProxybot: установка, ссылка для клиентов, рекламный тег, удаление." \
      "WEB-прокси TG"; MM_D+=("$REPLY")
    menu_mark "WEB-прокси TG"; MM_M+=("$REPLY")
    menu_desc "Отчёт о сервере одним файлом: состояние компонентов, протоколы и домены со сроком сертификатов и проверкой DNS, защита от сканеров, открытые порты, найденные проблемы. Здесь же журнал последней операции.${NL}${NL}@КОМАНДА${NL}dorik report"
    MM_D+=("$REPLY"); MM_M+=("")
    menu_desc "Отдельные шаги без полной настройки: восстановление SSH-доступа, только BBR, только веб-сервер с HAProxy, только Remnanode." \
      "BBR" "Расписание"; MM_D+=("$REPLY"); MM_M+=("")
    menu_desc "Полная сводка по серверу в одной рамке — всё, что видно в правой панели по частям." "${DASH_N[@]}"
    MM_D+=("$REPLY"); MM_M+=("")
    menu_desc "Скачивает свежую версию тулкита с GitHub и перезапускает меню. Настройки сервера при этом не меняются.${NL}${NL}@СЕЙЧАС${NL}версия ${DORIK_VERSION} · ветка ${GH_BRANCH}${NL}${NL}@КОМАНДА${NL}dorik update"
    MM_D+=("$REPLY"); MM_M+=("")

    if ! tui_ok; then banner; dash_print; fi
    TUI_SEL=$sel
    tui_select "DORIK" MM_L MM_D MM_K MM_M || exit 0
    sel=$TUI_SEL
    case "$sel" in
      0) run_script full-setup.sh; pause; refresh=1 ;;
      1) run_script panel-install.sh; refresh=1 ;;
      2) run_script profile-setup.sh; pause; refresh=1 ;;
      3) run_script node-update.sh; pause; refresh=1 ;;
      4) protect_menu && refresh=1 ;;
      5) run_script doctor.sh; pause; refresh=1 ;;
      6) web_menu && refresh=1 ;;
      7) report_menu ;;
      8) advanced_menu && refresh=1 ;;
      9) echo; dash_print; pause ;;
      10) self_update; pause ;;
    esac
  done
}

# Подменю возвращают 0, если что-то запускали (значит, сводку надо собрать заново).
protect_menu() {
  local -a PM_L PM_D PM_K
  local did=1
  PM_L=("Закрыть лишние порты и укрепить" "Показать открытые порты" "Блок-лист сканеров: включить" "Блок-лист: обновить список" "Блок-лист: состояние" "Блок-лист: выключить")
  PM_K=(1 2 3 4 5 6)
  PM_D=(
    "Оставляет открытыми только нужные порты (SSH, 80, 443, порт ноды, 443/udp для Hysteria2), отключает ненужные службы, укрепляет ядро и SSH, включает автообновления безопасности и бан перебора портов через fail2ban.${NL}${NL}Свои порты оставить открытыми: HARDEN_KEEP_PORTS=\"8443/tcp 9000\"."
    "Только показывает, что слушает на сервере и что из этого видно снаружи. Ничего не меняет."
    "Сервер перестаёт отвечать сетям, с которых ведётся активное зондирование (открытый список C24Be/AS_Network_List): пакеты отбрасываются ещё до HAProxy и Xray. Список обновляется раз в сутки, правила переживают перезагрузку.${NL}${NL}Ваш текущий SSH-адрес попадает в исключения автоматически.${NL}${NL}@ИСКЛЮЧЕНИЯ${NL}/etc/dorik/scanblock.allow"
    "Скачивает свежий список сетей прямо сейчас, не дожидаясь суточного обновления. Нужно и после правки файла исключений."
    "Сколько сетей в списке, сколько пакетов отброшено с момента загрузки и когда список обновлялся."
    "Убирает правила и наборы адресов, отключает ежедневное обновление. Файл исключений остаётся."
  )
  TUI_SEL=0
  while true; do
    tui_select "ЗАЩИТА И ПОРТЫ" PM_L PM_D PM_K || return "$did"
    case "$TUI_SEL" in
      0) run_script harden.sh; did=0 ;;
      1) run_script harden.sh --audit ;;
      2) run_script scanblock.sh on; did=0 ;;
      3) run_script scanblock.sh update; did=0 ;;
      4) run_script scanblock.sh status ;;
      5) run_script scanblock.sh off; did=0 ;;
    esac
    pause
  done
}

web_menu() {
  local -a WM_L WM_D WM_K
  local did=1 tg
  WM_L=("Установить / обновить" "Показать ссылку и состояние" "Рекламный тег канала-спонсора" "Удалить WEB-прокси" "Создать ключ для @MTProxybot")
  WM_K=(1 2 3 4 5)
  WM_D=(
    "Ставит Telemt, выпускает сертификат для домена WEB-прокси и подключает его к HAProxy по SNI — отдельный порт не нужен. Сначала должна быть выполнена полная настройка ноды.${NL}${NL}@НУЖНО${NL}отдельный домен с A-записью на этот сервер"
    "Ссылка для клиентов Telegram и состояние службы."
    "Тег из @MTProxybot (32 символа): с ним в клиентах показывается ваш канал-спонсор. «off» — убрать тег."
    "Удаляет Telemt, его конфиг и ключ, убирает маршрут из HAProxy. Домен и сертификат остаются."
    "Создаёт ключ до установки: он нужен боту @MTProxybot, чтобы выдать рекламный тег."
  )
  TUI_SEL=0
  while true; do
    tui_select "WEB-ПРОКСИ TELEGRAM" WM_L WM_D WM_K || return "$did"
    case "$TUI_SEL" in
      0) run_script webproxy-setup.sh install; did=0 ;;
      1) run_script webproxy-setup.sh status ;;
      2) read -r -p "Тег из @MTProxybot (32 символа; off — убрать): " tg <"$(prompt_input)" || tg=""
         [ -n "$tg" ] && { run_script webproxy-setup.sh tag "$tg"; did=0; } ;;
      3) run_script webproxy-setup.sh remove; did=0 ;;
      4) run_script webproxy-setup.sh secret ;;
    esac
    pause
  done
}

advanced_menu() {
  local -a AM_L AM_D AM_K
  local did=1
  AM_L=("Восстановить SSH-доступ" "Только BBR и сетевая оптимизация" "Только веб-сервер + HAProxy" "Только Remnanode" "Порт Hysteria2")
  AM_K=(1 2 3 4 5)
  AM_D=(
    "Экстренный случай: SSH перестал отвечать на нужном порту. Проверяет sshd, firewall и fail2ban и возвращает доступ."
    "Включает BBR и сетевые параметры ядра для ноды, ничего больше не трогая."
    "На уже настроенную ноду: заглушки (Nginx или Caddy), сертификаты и маршрутизация HAProxy по SNI. Спросит веб-сервер и домены протоколов."
    "Ставит или пересоздаёт только контейнер ноды Remnanode."
    "Меняет UDP-порт Hysteria2 на настроенной ноде: 443, случайный свободный или свой. Переносит правило firewall и предлагает обновить inbound и хост на панели по API; без этого нода останется на прежнем порту.${NL}${NL}@СЕЙЧАС${NL}$(hy2_port)/udp${NL}${NL}@КОМАНДА${NL}dorik hy2-port"
  )
  TUI_SEL=0
  while true; do
    tui_select "ДОПОЛНИТЕЛЬНО" AM_L AM_D AM_K || return "$did"
    case "$TUI_SEL" in
      0) run_script fix-ssh-access.sh ;;
      1) run_script bbr-install.sh ;;
      2) run_script haproxy-setup.sh ;;
      3) run_script remnanode-setup.sh ;;
      4) run_script hy2-port.sh ;;
    esac
    did=0
    pause
  done
}

main_menu
