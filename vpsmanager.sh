#!/usr/bin/env bash
set -euo pipefail

SSH_PORT="22"
BASE_DIR="/srv"
DEPLOY_DIR="$BASE_DIR/deploy-scripts"
BACKUP_ROOT="/backup"

need_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "Jalankan pakai sudo: sudo ./vps-manager.sh"
    exit 1
  fi
}

pause() {
  echo
  read -rp "Tekan ENTER untuk lanjut..."
}

install_whiptail() {
  if ! command -v whiptail >/dev/null 2>&1; then
    apt update
    apt install -y whiptail
  fi
}

input_project_name() {
  whiptail --inputbox "Nama project:" 10 60 "inkrova" 3>&1 1>&2 2>&3
}

full_setup_vps() {
  need_root

  apt update
  apt upgrade -y

  apt install -y ca-certificates curl gnupg git ufw fail2ban unattended-upgrades nano htop unzip zip whiptail

  install -m 0755 -d /etc/apt/keyrings

  . /etc/os-release

  if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
    whiptail --msgbox "OS harus Ubuntu/Debian." 10 50
    return
  fi

  curl -fsSL "https://download.docker.com/linux/$ID/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg || true
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list

  apt update
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
  systemctl enable --now fail2ban || true
  systemctl enable --now unattended-upgrades || true

  id deploy &>/dev/null || adduser --disabled-password --gecos "" deploy
  id hermes &>/dev/null || adduser --disabled-password --gecos "" hermes

  usermod -aG docker deploy

  mkdir -p "$BASE_DIR/repos" "$BASE_DIR/apps" "$BASE_DIR/secrets" "$DEPLOY_DIR" "$BACKUP_ROOT"

  chown -R deploy:deploy "$BASE_DIR/repos" "$BASE_DIR/apps" "$DEPLOY_DIR"
  chown -R root:root "$BASE_DIR/secrets"
  chmod 750 "$BASE_DIR/repos" "$BASE_DIR/apps" "$DEPLOY_DIR"
  chmod 700 "$BASE_DIR/secrets"

  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "$SSH_PORT"/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable

  cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = %(sshd_log)s
maxretry = 5
bantime = 1h
findtime = 10m
EOF

  systemctl restart fail2ban || true

  cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%F-%H%M%S)

  sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
  sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
  sed -i 's/^#*X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config

  sshd -t && systemctl reload ssh || true

  whiptail --msgbox "Full setup VPS selesai." 10 50
}

add_project() {
  need_root

  PROJECT_NAME=$(input_project_name) || return
  REPO_URL=$(whiptail --inputbox "GitHub repo URL:" 10 80 "https://github.com/user/repo.git" 3>&1 1>&2 2>&3) || return
  BRANCH=$(whiptail --inputbox "Branch:" 10 60 "main" 3>&1 1>&2 2>&3) || return

  REPO_DIR="$BASE_DIR/repos/$PROJECT_NAME"
  APP_DIR="$BASE_DIR/apps/$PROJECT_NAME"
  SECRET_DIR="$BASE_DIR/secrets/$PROJECT_NAME"
  ENV_FILE="$SECRET_DIR/.env"
  DEPLOY_SCRIPT="$DEPLOY_DIR/deploy-$PROJECT_NAME.sh"

  mkdir -p "$APP_DIR" "$SECRET_DIR" "$DEPLOY_DIR"

  chown -R deploy:deploy "$BASE_DIR/repos" "$BASE_DIR/apps" "$DEPLOY_DIR"
  chown -R root:root "$BASE_DIR/secrets"

  chmod 750 "$BASE_DIR/repos" "$BASE_DIR/apps" "$DEPLOY_DIR"
  chmod 700 "$BASE_DIR/secrets" "$SECRET_DIR"

  touch "$ENV_FILE"
  chown root:root "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  if [[ ! -d "$REPO_DIR/.git" ]]; then
    rm -rf "$REPO_DIR"
    sudo -u deploy git clone "$REPO_URL" "$REPO_DIR"
  fi

  cat > "$DEPLOY_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="$PROJECT_NAME"
BRANCH="$BRANCH"
REPO_DIR="$REPO_DIR"
ENV_FILE="$ENV_FILE"

cd "\$REPO_DIR"

echo "==> Ambil update dari GitHub..."
git fetch origin "\$BRANCH"
git reset --hard "origin/\$BRANCH"

echo "==> Build dan restart Docker..."
docker compose --env-file "\$ENV_FILE" up -d --build

echo "==> Bersihkan image lama..."
docker image prune -f

echo "==> Status container:"
docker compose ps

echo "==> Deploy \$PROJECT_NAME selesai."
EOF

  chown deploy:deploy "$DEPLOY_SCRIPT"
  chmod 750 "$DEPLOY_SCRIPT"

  cat > /etc/sudoers.d/hermes-"$PROJECT_NAME" <<EOF
hermes ALL=(deploy) NOPASSWD: $DEPLOY_SCRIPT
EOF

  chmod 440 /etc/sudoers.d/hermes-"$PROJECT_NAME"

  whiptail --msgbox "Project $PROJECT_NAME berhasil ditambahkan.

Env:
$ENV_FILE

Deploy script:
$DEPLOY_SCRIPT

Command Hermes:
sudo -u deploy $DEPLOY_SCRIPT" 18 75
}

deploy_project() {
  need_root

  PROJECT_NAME=$(input_project_name) || return
  DEPLOY_SCRIPT="$DEPLOY_DIR/deploy-$PROJECT_NAME.sh"

  if [[ ! -f "$DEPLOY_SCRIPT" ]]; then
    whiptail --msgbox "Deploy script tidak ditemukan: $DEPLOY_SCRIPT" 10 70
    return
  fi

  sudo -u deploy "$DEPLOY_SCRIPT"
  pause
}

restart_project() {
  need_root

  PROJECT_NAME=$(input_project_name) || return
  REPO_DIR="$BASE_DIR/repos/$PROJECT_NAME"
  ENV_FILE="$BASE_DIR/secrets/$PROJECT_NAME/.env"

  cd "$REPO_DIR"
  sudo -u deploy docker compose --env-file "$ENV_FILE" restart
  pause
}

view_logs() {
  need_root

  PROJECT_NAME=$(input_project_name) || return
  REPO_DIR="$BASE_DIR/repos/$PROJECT_NAME"

  cd "$REPO_DIR"
  sudo -u deploy docker compose logs --tail=150
  pause
}

status_project() {
  need_root

  PROJECT_NAME=$(input_project_name) || return
  REPO_DIR="$BASE_DIR/repos/$PROJECT_NAME"

  cd "$REPO_DIR"
  sudo -u deploy docker compose ps
  echo
  docker stats --no-stream || true
  pause
}

edit_env() {
  need_root

  PROJECT_NAME=$(input_project_name) || return
  ENV_FILE="$BASE_DIR/secrets/$PROJECT_NAME/.env"

  nano "$ENV_FILE"
  chown root:root "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

backup_project() {
  need_root

  PROJECT_NAME=$(input_project_name) || return
  REPO_DIR="$BASE_DIR/repos/$PROJECT_NAME"
  ENV_FILE="$BASE_DIR/secrets/$PROJECT_NAME/.env"
  BACKUP_DIR="$BACKUP_ROOT/$PROJECT_NAME/$(date +%F-%H%M%S)"

  mkdir -p "$BACKUP_DIR"

  tar -czf "$BACKUP_DIR/repo.tar.gz" -C "$REPO_DIR" .
  cp "$ENV_FILE" "$BACKUP_DIR/.env.backup"

  chmod -R 700 "$BACKUP_ROOT/$PROJECT_NAME"

  whiptail --msgbox "Backup selesai:
$BACKUP_DIR" 10 70
}

security_check() {
  need_root

  echo "=== SECURITY CHECK ==="
  echo

  echo "[Hermes User]"
  id hermes || true
  echo

  echo "[Hermes Docker Group]"
  if id -nG hermes | grep -qw docker; then
    echo "BAHAYA: hermes ada di group docker."
  else
    echo "OK: hermes tidak ada di group docker."
  fi
  echo

  echo "[Deploy User Docker Group]"
  id -nG deploy || true
  echo

  echo "[UFW]"
  ufw status verbose || true
  echo

  echo "[Fail2ban]"
  systemctl status fail2ban --no-pager || true
  echo

  echo "[SSH Config]"
  grep -E "PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|X11Forwarding" /etc/ssh/sshd_config || true
  echo

  echo "[Secrets Permission]"
  ls -lah "$BASE_DIR/secrets" || true

  pause
}

docker_cleanup() {
  need_root
  docker system prune -f
  pause
}

system_info() {
  echo "=== SYSTEM INFO ==="
  hostnamectl || true
  echo
  echo "=== DISK ==="
  df -h
  echo
  echo "=== RAM ==="
  free -h
  echo
  echo "=== DOCKER ==="
  docker --version || true
  docker compose version || true
  pause
}

list_projects() {
  echo "=== PROJECTS ==="
  ls -1 "$BASE_DIR/repos" 2>/dev/null || true
  pause
}

main_menu() {
  need_root
  install_whiptail

  while true; do
    CHOICE=$(whiptail --title "VPS MANAGER - Docker + Hermes" --menu "Pilih menu:" 22 75 13 \
      "1" "Full Setup VPS dari Nol" \
      "2" "Add New Project" \
      "3" "Deploy Project" \
      "4" "Restart Project" \
      "5" "View Logs" \
      "6" "Status Project" \
      "7" "Edit .env" \
      "8" "Backup Project" \
      "9" "Security Check" \
      "10" "Docker Cleanup" \
      "11" "System Info" \
      "12" "List Projects" \
      "0" "Exit" \
      3>&1 1>&2 2>&3) || exit 0

    case "$CHOICE" in
      1) full_setup_vps ;;
      2) add_project ;;
      3) deploy_project ;;
      4) restart_project ;;
      5) view_logs ;;
      6) status_project ;;
      7) edit_env ;;
      8) backup_project ;;
      9) security_check ;;
      10) docker_cleanup ;;
      11) system_info ;;
      12) list_projects ;;
      0) exit 0 ;;
    esac
  done
}

main_menu
