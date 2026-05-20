#!/usr/bin/env bash
# lxc_openspoolman.sh — runs inside the OpenSpoolMan LXC container
# Installs OpenSpoolMan (Flask/gunicorn) + nginx with self-signed SSL.
# Receives Spoolman's IP via SPOOLMAN_IP env var from the Proxmox host script.
set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${BLUE}${BOLD}==> $*${NC}"; }

if [[ $EUID -ne 0 ]]; then error "Run as root."; exit 1; fi

# ---------------------------------------------------------------------------
# Configuration — env vars supplied by install.sh via pct exec
# ---------------------------------------------------------------------------
SPOOLMAN_IP="${SPOOLMAN_IP:?SPOOLMAN_IP is required}"
SPOOL_PORT="${SPOOL_PORT:-7912}"
OSPOOL_HOST="${OSPOOL_HOST:-openspoolman.home}"
OSPOOL_PORT="${OSPOOL_PORT:-8000}"
PRINTER_IP="${PRINTER_IP:?PRINTER_IP is required}"
PRINTER_SERIAL="${PRINTER_SERIAL:?PRINTER_SERIAL is required}"
ACCESS_CODE="${ACCESS_CODE:?ACCESS_CODE is required}"

SERVER_IP=$(hostname -I | awk '{print $1}')

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
section "Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
LC_ALL=C apt-get install -y --no-install-recommends locales > /dev/null
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen > /dev/null
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
apt-get install -y --no-install-recommends \
  git curl ca-certificates \
  python3 python3-pip python3-venv \
  nginx openssl \
  build-essential libffi-dev libssl-dev libpq-dev libcurl4-openssl-dev

# ---------------------------------------------------------------------------
# 2. System user
# ---------------------------------------------------------------------------
section "Creating system user"
id openspoolman &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin openspoolman

# ---------------------------------------------------------------------------
# 3. TLS — Root CA + service certificate with SAN
# ---------------------------------------------------------------------------
section "Generating TLS certificates"

SSL_DIR="/etc/ssl/spoolman-stack"
mkdir -p "${SSL_DIR}"

info "Creating Root CA"
openssl genrsa -out "${SSL_DIR}/ca.key" 4096
chmod 600 "${SSL_DIR}/ca.key"
openssl req -new -x509 -days 3650 \
  -key "${SSL_DIR}/ca.key" \
  -out "${SSL_DIR}/ca.crt" \
  -subj "/CN=Spoolman-Stack-CA/O=SpoolmanStack/C=DE" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"

info "Issuing service certificate for ${OSPOOL_HOST} / ${SERVER_IP}"
openssl genrsa -out "${SSL_DIR}/openspoolman.key" 2048
chmod 600 "${SSL_DIR}/openspoolman.key"

SAN_CNF=$(mktemp)
cat > "${SAN_CNF}" <<EOF
[req]
distinguished_name = req_dn
[req_dn]
[v3_req]
subjectAltName = DNS:${OSPOOL_HOST},IP:${SERVER_IP}
EOF

openssl req -new \
  -key "${SSL_DIR}/openspoolman.key" \
  -out "${SSL_DIR}/openspoolman.csr" \
  -subj "/CN=${OSPOOL_HOST}/O=SpoolmanStack/C=DE"

openssl x509 -req -days 3650 \
  -in  "${SSL_DIR}/openspoolman.csr" \
  -CA  "${SSL_DIR}/ca.crt" \
  -CAkey "${SSL_DIR}/ca.key" \
  -CAcreateserial \
  -out "${SSL_DIR}/openspoolman.crt" \
  -extfile "${SAN_CNF}" \
  -extensions v3_req

rm -f "${SAN_CNF}" "${SSL_DIR}/openspoolman.csr"

# ---------------------------------------------------------------------------
# 4. OpenSpoolMan application
# ---------------------------------------------------------------------------
section "Installing OpenSpoolMan"

OSPOOL_DIR="/opt/openspoolman"

if [[ -d "${OSPOOL_DIR}/.git" ]]; then
  info "Updating existing OpenSpoolMan clone"
  git -C "${OSPOOL_DIR}" pull --ff-only
else
  info "Cloning OpenSpoolMan"
  git clone --depth 1 https://github.com/drndos/openspoolman.git "${OSPOOL_DIR}"
fi

[[ ! -d "${OSPOOL_DIR}/venv" ]] && python3 -m venv "${OSPOOL_DIR}/venv"

info "Installing OpenSpoolMan dependencies"
"${OSPOOL_DIR}/venv/bin/pip" install --quiet --upgrade pip
[[ -f "${OSPOOL_DIR}/requirements.txt" ]] && \
  "${OSPOOL_DIR}/venv/bin/pip" install --quiet -r "${OSPOOL_DIR}/requirements.txt"

# OpenSpoolMan is Docker-native and hardcodes /home/app for logs/data.
mkdir -p /home/app/logs /home/app/data
chown -R openspoolman:openspoolman /home/app

# config.env — this is the filename config.py loads via load_dotenv().
cat > "${OSPOOL_DIR}/config.env" <<EOF
OPENSPOOLMAN_BASE_URL=https://${SERVER_IP}
SPOOLMAN_BASE_URL=http://${SPOOLMAN_IP}:${SPOOL_PORT}
PORT=${OSPOOL_PORT}
PRINTER_IP=${PRINTER_IP}
PRINTER_ID=${PRINTER_SERIAL}
PRINTER_ACCESS_CODE=${ACCESS_CODE}
EOF
chmod 600 "${OSPOOL_DIR}/config.env"
chown openspoolman:openspoolman "${OSPOOL_DIR}/config.env"
chown -R openspoolman:openspoolman "${OSPOOL_DIR}"

# ---------------------------------------------------------------------------
# 5. Systemd service for OpenSpoolMan (gunicorn)
# ---------------------------------------------------------------------------
section "Configuring OpenSpoolMan service"

cat > /etc/systemd/system/openspoolman.service <<EOF
[Unit]
Description=OpenSpoolMan Bambu bridge
After=network.target

[Service]
Type=simple
User=openspoolman
WorkingDirectory=${OSPOOL_DIR}
EnvironmentFile=${OSPOOL_DIR}/config.env
ExecStart=${OSPOOL_DIR}/venv/bin/gunicorn -w 1 --threads 4 -b 127.0.0.1:${OSPOOL_PORT} app:app
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=${OSPOOL_DIR} /home/app

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------------------
# 6. Nginx — HTTPS (443) + CA download (8080)
# ---------------------------------------------------------------------------
section "Configuring Nginx"

unlink /etc/nginx/sites-enabled/default 2>/dev/null || true

mkdir -p /var/www/html

cat > /etc/nginx/sites-available/openspoolman <<EOF
server {
    listen 443 ssl;
    server_name ${OSPOOL_HOST} ${SERVER_IP};

    ssl_certificate     ${SSL_DIR}/openspoolman.crt;
    ssl_certificate_key ${SSL_DIR}/openspoolman.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    add_header Permissions-Policy "nfc=*";

    location / {
        proxy_pass         http://127.0.0.1:${OSPOOL_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";
    }
}

server {
    listen 8080;
    server_name _;
    root /var/www/html;

    location /spoolman-ca.crt {
        default_type application/x-x509-ca-cert;
    }
}
EOF

cp "${SSL_DIR}/ca.crt" /var/www/html/spoolman-ca.crt
chmod 644 /var/www/html/spoolman-ca.crt

ln -sf /etc/nginx/sites-available/openspoolman /etc/nginx/sites-enabled/openspoolman

info "Testing Nginx configuration"
nginx -t

# ---------------------------------------------------------------------------
# 7. Enable and start services
# ---------------------------------------------------------------------------
section "Starting services"

systemctl daemon-reload
systemctl enable --now openspoolman
systemctl enable nginx
systemctl restart nginx

# ---------------------------------------------------------------------------
# 8. Summary
# ---------------------------------------------------------------------------
echo
echo -e "${GREEN}${BOLD}"
cat <<EOF
============================================================
  OpenSpoolMan installation complete
============================================================

  IP address    : ${SERVER_IP}
  HTTPS URL     : https://${SERVER_IP}
  Hostname URL  : https://${OSPOOL_HOST}
  CA cert       : http://${SERVER_IP}:8080/spoolman-ca.crt

  Spoolman backend : http://${SPOOLMAN_IP}:${SPOOL_PORT}

  /etc/hosts entry needed on client machines:
    ${SERVER_IP}  ${OSPOOL_HOST}

  Install the CA certificate to trust HTTPS in your browser.
  Download it from: http://${SERVER_IP}:8080/spoolman-ca.crt

  iPhone / iPad:
    Open the CA URL in Safari
    Settings → General → VPN & Device Management → Install
    Settings → General → About → Certificate Trust Settings
    Enable full trust for Spoolman-Stack-CA

============================================================
EOF
echo -e "${NC}"

section "Service status"
systemctl --no-pager status openspoolman nginx --lines=5 || true
