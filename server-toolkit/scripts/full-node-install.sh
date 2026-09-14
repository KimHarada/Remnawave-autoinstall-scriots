#!/bin/bash
set -euo pipefail

# ============================================================
#  full-node-install — полная установка ноды одним запуском
#  Nginx(self-steal)+HAProxy → BBR → Remnanode (с вопросом про Hysteria2)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    err "Запускать нужно от root."
    exit 1
fi

GH_USER="KimHarada"
GH_REPO="Remnawave-autoinstall-scriots"
GH_BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${GH_BRANCH}/scripts"

run_step() {
    local script_name="$1"
    local title="$2"
    local tmpfile
    tmpfile=$(mktemp /tmp/full-install-XXXXXX.sh)

    echo
    echo "============================================================"
    log "ЭТАП: ${title}"
    echo "============================================================"
    echo

    if ! curl -fsSL "${BASE_URL}/${script_name}" -o "$tmpfile"; then
        err "Не удалось скачать ${script_name}"
        rm -f "$tmpfile"
        exit 1
    fi
    chmod +x "$tmpfile"
    bash "$tmpfile"
    local exit_code=$?
    rm -f "$tmpfile"

    if [[ $exit_code -ne 0 ]]; then
        err "Этап '${title}' завершился с ошибкой (код ${exit_code})."
        err "Прерываем полную установку — остальные этапы не будут выполнены."
        exit $exit_code
    fi
}

echo "============================================================"
echo " Полная установка ноды"
echo " Nginx (self-steal) + HAProxy → BBR → Remnanode"
echo "============================================================"

run_step "haproxy-setup.sh" "Nginx (self-steal) + HAProxy + Certbot"
run_step "bbr-install.sh" "BBR3"
run_step "remnanode-setup.sh" "Remnanode (спросит про Hysteria2 и пропишет volumes)"

echo
echo "============================================================"
log "Полная установка завершена."
echo "============================================================"
echo "  Проверьте статус:"
echo "    docker logs remnanode -f"
echo "    systemctl status haproxy nginx --no-pager"
echo "    sysctl net.ipv4.tcp_congestion_control"
echo "============================================================"
