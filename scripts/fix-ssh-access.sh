#!/usr/bin/env bash
# Экстренное восстановление SSH-доступа. Запускается только вручную из меню.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh" 2>/dev/null || {
  RAW="https://raw.githubusercontent.com/KimHarada/Remnawave-autoinstall-scriots/main"
  t=$(mktemp); curl -fsSL "${RAW}/scripts/lib.sh" -o "$t"; source "$t"
}
require_root

UNIT="$(detect_ssh_unit)"
step "Проверка службы SSH (${UNIT})"

if ! systemctl is-enabled "${UNIT}" &>/dev/null; then
  warn "Служба ${UNIT} выключена (disabled) — включаю, иначе не переживёт reboot."
  systemctl enable "${UNIT}" &>/dev/null || true
fi

mkdir -p /run/sshd
cat > /etc/tmpfiles.d/sshd.conf <<'EOF'
d /run/sshd 0755 root root -
EOF

if ! sshd -t 2>/dev/null; then
  err "Ошибка синтаксиса sshd_config."
  echo "Варианты восстановления:"
  echo "  1) Восстановить из последнего бэкапа"
  echo "  2) Сбросить порт на 22, остальное не трогать"
  echo "  3) Открыть вручную (nano)"
  CH=$(ask_value "Выбор" "2")
  case "$CH" in
    1)
      LAST=$(ls -t /etc/ssh/sshd_config.bak.* 2>/dev/null | head -1)
      if [ -n "$LAST" ]; then cp -f "$LAST" /etc/ssh/sshd_config; ok "Восстановлено из $LAST"; else err "Бэкапов не найдено"; fi
      ;;
    2)
      sed -i -E "/^[#[:space:]]*Port[[:space:]]+[0-9]+/d" /etc/ssh/sshd_config
      echo "Port 22" >> /etc/ssh/sshd_config
      ok "Порт сброшен на 22."
      ;;
    3) nano /etc/ssh/sshd_config ;;
  esac
fi

systemctl status "${UNIT}" --no-pager -l 2>&1 | tail -20 || true

CONFIGURED_PORT=$(grep -oE '^Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config | tail -1 | grep -oE '[0-9]+')
CONFIGURED_PORT="${CONFIGURED_PORT:-22}"

if ! ssh_selfheal "$CONFIGURED_PORT"; then
  err "Не удалось поднять SSH на порту ${CONFIGURED_PORT} автоматически."
  err "Проверьте вручную: journalctl -u ssh.service -n 50 --no-pager; sshd -t"
  exit 1
fi

PORTS=$(ss -tlnp 2>/dev/null | grep sshd | grep -oE ':[0-9]+' | tr -d ':' | sort -u)
for p in $PORTS; do
  ufw allow "${p}/tcp" comment "SSH recovered" &>/dev/null || true
  ok "Порт ${p} открыт в ufw и слушается."
done
ok "SSH-доступ восстановлен."
