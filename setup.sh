#!/usr/bin/env bash
set -euo pipefail

# =========================
# EDIT BAGIAN INI
# =========================
PROJECT_NAME="inkrova"
BRANCH="main"
GITHUB_REPO_URL="ISI_URL_REPO_GITHUB_KAMU"
SSH_PORT="22"

# =========================
# PATH
# =========================
REPO_DIR="/srv/repos/$PROJECT_NAME"
APP_DIR="/srv/apps/$PROJECT_NAME"
SECRET_DIR="/srv/secrets/$PROJECT_NAME"
ENV_FILE="$SECRET_DIR/.env"
DEPLOY_DIR="/srv/deploy-scripts"
DEPLOY_SCRIPT="$DEPLOY_DIR/deploy-$PROJECT_NAME.sh"

echo "==> Validasi root..."
if [[ "$EUID" -ne 0 ]]; then
  echo "Jalankan sebagai root: sudo ./full-setup-inkrova-vps.sh"
  exit 1
fi

echo "==> Update system..."
apt update
apt upgrade -y

echo "==> Install tools dasar..."
apt install -y ca-certificates curl gnupg git ufw fail2ban unattended-upgrades nano

echo "==> Setup automatic security updates..."
dpkg-reconfigure -f noninteractive unattended-upgrades || true
systemctl enable --now unattended-upgrades || true

echo "==> Install Docker official repository..."
install -m 0755 -d /etc/apt/keyrings

. /etc/os-release
DISTRO_ID="$ID"

if [[ "$DISTRO_ID" != "ubuntu" && "$DISTRO_ID" != "debian" ]]; then
  echo "OS tidak didukung otomatis. Gunakan Ubuntu/Debian."
  exit 1
fi

curl -fsSL "https://download.docker.com/linux/$DISTRO_ID/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$DISTRO_ID \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

apt update

echo "==> Install Docker Engine + Compose plugin..."
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker

echo "==> Membuat user deploy dan hermes..."
id deploy &>/dev/null || adduser --disabled-password --gecos "" deploy
id hermes &>/dev/null || adduser --disabled-password --gecos "" hermes

echo "==> Tambahkan deploy ke group docker..."
usermod -aG docker deploy

echo "==> PENTING: hermes TIDAK dimasukkan ke group docker."

echo "==> Membuat struktur folder..."
mkdir -p "$REPO_DIR" "$APP_DIR" "$SECRET_DIR" "$DEPLOY_DIR"

chown -R deploy:deploy /srv/repos /srv/apps "$DEPLOY_DIR"
chown -R root:root /srv/secrets

chmod 750 /srv/repos /srv/apps "$DEPLOY_DIR"
chmod 700 /srv/secrets "$SECRET_DIR"

touch "$ENV_FILE"
chown root:root "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo "==> Clone repo jika belum ada..."
if [[ "$GITHUB_REPO_URL" == "ISI_URL_REPO_GITHUB_KAMU" ]]; then
  echo "WARNING: GITHUB_REPO_URL belum diisi."
  echo "Nanti clone manual:"
  echo "sudo -u deploy git clone REPO_URL $REPO_DIR"
else
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    rm -rf "$REPO_DIR"
    sudo -u deploy git clone "$GITHUB_REPO_URL" "$REPO_DIR"
  fi
fi

echo "==> Membuat script deploy..."
cat > "$DEPLOY_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="$PROJECT_NAME"
BRANCH="$BRANCH"
REPO_DIR="$REPO_DIR"
ENV_FILE="$ENV_FILE"

cd "\$REPO_DIR"

echo "==> Ambil update terbaru dari GitHub..."
git fetch origin "\$BRANCH"
git reset --hard "origin/\$BRANCH"

echo "==> Deploy Docker Compose..."
docker compose --env-file "\$ENV_FILE" up -d --build

echo "==> Bersihkan image lama..."
docker image prune -f

echo "==> Status container:"
docker compose ps

echo "==> Deploy \$PROJECT_NAME selesai."
EOF

chown deploy:deploy "$DEPLOY_SCRIPT"
chmod 750 "$DEPLOY_SCRIPT"

echo "==> Setting sudo khusus Hermes..."
cat > /etc/sudoers.d/hermes-"$PROJECT_NAME" <<EOF
hermes ALL=(deploy) NOPASSWD: $DEPLOY_SCRIPT
EOF

chmod 440 /etc/sudoers.d/hermes-"$PROJECT_NAME"

echo "==> Setup firewall UFW..."
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo "==> Setup Fail2ban..."
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

systemctl enable --now fail2ban
systemctl restart fail2ban

echo "==> Hardening SSH..."
SSHD_CONFIG="/etc/ssh/sshd_config"

cp "$SSHD_CONFIG" "$SSHD_CONFIG.bak.$(date +%F-%H%M%S)"

sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"
sed -i 's/^#*X11Forwarding.*/X11Forwarding no/' "$SSHD_CONFIG"

sshd -t && systemctl reload ssh || systemctl reload sshd || true

echo "==> Versi Docker:"
docker --version
docker compose version

echo ""
echo "========================================"
echo "SETUP SELESAI"
echo "========================================"
echo "Project       : $PROJECT_NAME"
echo "Repo folder   : $REPO_DIR"
echo "Env file      : $ENV_FILE"
echo "Deploy script : $DEPLOY_SCRIPT"
echo ""
echo "Edit .env:"
echo "sudo nano $ENV_FILE"
echo ""
echo "Command untuk Hermes:"
echo "sudo -u deploy $DEPLOY_SCRIPT"
echo ""
echo "Kalau repo belum diisi, clone manual:"
echo "sudo -u deploy git clone REPO_URL $REPO_DIR"
echo ""
echo "PENTING:"
echo "- Hermes tidak bisa baca $ENV_FILE"
echo "- Hermes hanya boleh menjalankan deploy script"
echo "- Jangan masukkan hermes ke group docker"
