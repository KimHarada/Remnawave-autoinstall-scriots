#!/bin/bash
set -euo pipefail

# ============================================================
#  Server Toolkit — главное меню
#  Запуск: bash <(curl -fsSL https://raw.githubusercontent.com/ВАШ_ЮЗЕР/ВАШ_РЕПО/main/menu.sh)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# !!! ЗАМЕНИТЕ на свои реальные значения !!!
GH_USER="KimHarada"
GH_REPO="Remnawave-autoinstall-scriots"
GH_BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${GH_BRANCH}/scripts"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[x]${NC} Запускать нужно от root (sudo bash <(curl ...))."
   exit 1
fi

run_remote_script() {
    local script_name="$1"
    local url="${BASE_URL}/${script_name}"
    local tmpfile
    tmpfile=$(mktemp /tmp/server-toolkit-XXXXXX.sh)

    echo -e "${BLUE}[i]${NC} Загружаем ${script_name}..."
    if ! curl -fsSL "$url" -o "$tmpfile"; then
        echo -e "${RED}[x]${NC} Не удалось скачать скрипт: ${url}"
        rm -f "$tmpfile"
        exit 1
    fi

    chmod +x "$tmpfile"
    echo -e "${GREEN}[+]${NC} Запускаем ${script_name}..."
    echo
    bash "$tmpfile"
    local exit_code=$?
    rm -f "$tmpfile"
    return $exit_code
}

show_menu() {
    clear
    echo "============================================================"
    echo "  Server Toolkit"
    echo "============================================================"
    echo
    echo "  1) Harden SSH  — смена SSH-порта, ufw, fail2ban,"
    echo "                   часовой пояс Иркутск, автоперезагрузка 04:00"
    echo "  2) (зарезервировано)"
    echo "  3) (зарезервировано)"
    echo "  0) Выход"
    echo
    echo "============================================================"
}

main() {
    show_menu
    read -rp "Выберите пункт: " CHOICE

    case "$CHOICE" in
        1)
            run_remote_script "harden-ssh.sh"
            ;;
        2)
            echo -e "${YELLOW}[!]${NC} Пункт пока не реализован."
            ;;
        3)
            echo -e "${YELLOW}[!]${NC} Пункт пока не реализован."
            ;;
        0)
            echo "Выход."
            exit 0
            ;;
        *)
            echo -e "${RED}[x]${NC} Некорректный выбор."
            exit 1
            ;;
    esac
}

main
