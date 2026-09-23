#!/usr/bin/env bash
# DORIK — точка входа. Основной путь — один пункт "Полная настройка",
# который проходит всё пошагово без конфликтов. Остальное — под "Дополнительно",
# для точечных операций/восстановления.
set -uo pipefail

GH_USER="KimHarada"
GH_REPO="Remnawave-autoinstall-scriots"
GH_BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${GH_BRANCH}/scripts"

ensure_toilet() {
  if ! command -v toilet &>/dev/null; then
    apt-get update -qq &>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq toilet toilet-fonts &>/dev/null || true
  fi
}

banner() {
  ensure_toilet
  if command -v toilet &>/dev/null; then
    toilet -f mono12 "DORIK" 2>/dev/null || toilet "DORIK"
  elif command -v figlet &>/dev/null; then
    figlet "DORIK"
  else
    echo "=== DORIK ==="
  fi
}

run_remote_script() {
  local name="${1:?run_remote_script: script name required}"; shift
  local tmp; tmp="$(mktemp)"
  curl -fsSL "${BASE_URL}/${name}" -o "$tmp"
  chmod +x "$tmp"
  bash "$tmp" "$@"
  rm -f "$tmp"
}

clear
banner
echo
echo "  1) Полная настройка (нода + защита сервера, одним шагом)"
echo "  2) Дополнительно (точечные операции)"
echo "  0) Выход"
echo
read -r -p "Выбор: " CH

case "$CH" in
  1)
    run_remote_script "full-setup.sh"
    ;;
  2)
    clear
    echo "Дополнительно:"
    echo "  1) Восстановить SSH-доступ (экстренно)"
    echo "  2) Только BBR"
    echo "  3) Только Nginx+HAProxy (на уже настроенную ноду)"
    echo "  4) Только Remnanode"
    echo "  9) Назад"
    read -r -p "Выбор: " CH2
    case "$CH2" in
      1) run_remote_script "fix-ssh-access.sh" ;;
      2) run_remote_script "bbr-install.sh" ;;
      3) run_remote_script "haproxy-setup.sh" ;;
      4) run_remote_script "remnanode-setup.sh" ;;
      *) exit 0 ;;
    esac
    ;;
  0|*) exit 0 ;;
esac
