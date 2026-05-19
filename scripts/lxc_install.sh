#!/usr/bin/env bash
# lxc_install.sh — runs inside the Debian 13 LXC container
# Installs Spoolman + OpenSpoolMan with Nginx HTTPS and self-signed CA
set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers (inline copy of build.func for standalone curl execution)
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${BLUE}${BOLD}==> $*${NC}"; }

check_root() {
  if [[ $EUID -ne 0 ]]; then error "Run as root."; exit 1; fi
}

ask() {
  local _var="$1" _prompt="$2" _default="$3" _input
  if [[ -n "$_default" ]]; then
    read -rp "$(echo -e "${CYAN}${_prompt}${NC} [${_default}]: ")" _input
    printf -v "$_var" '%s' "${_input:-$_default}"
  else
    while true; do
      read -rp "$(echo -e "${CYAN}${_prompt}${NC}: ")" _input
      [[ -n "$_input" ]] && break
      warn "This field is required."
    done
    printf -v "$_var" '%s' "$_input"
  fi
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
clear
echo -e "${BLUE}${BOLD}"
cat <<'BANNER'
 ____                  _                           ____  _             _    
/ ___| _ __   ___  ___| |_ __ _  ___ ___ _ __ ___|___ \| |_ __ _  ___| | __
\___ \| '_ \ / _ \/ _ \ | '_ ` |/ _ | '_ ` _ \  __) | __/ _` |/ __| |/ /
 ___) | |_) |  __/  __/ | | | | (_| | | | | | |/ __/| || (_| | (__|   < 
|____/| .__/ \___|\___|_|_| |_|\__,_|_| |_| |_|_____\_\__\__,_|\___|_|\_\
      |_|                                                                    
BANNER
echo -e "${NC}"
echo -e "${BOLD}  Spoolman + OpenSpoolMan LXC Installer${NC}"
echo    "  github.com/Manjo80/spoolman-stack"
echo

check_root

# ---------------------------------------------------------------------------
# Configuration — use env vars when called from install.sh, prompt otherwise
# ---------------------------------------------------------------------------

# Required vars — check if they were supplied by the caller
if [[ -z "${PRINTER_IP:-}" || -z "${PRINTER_SERIAL:-}" || -z "${ACCESS_CODE:-}" ]]; then
  section "Configuration"
  ask SPOOL_HOST    "Hostname for Spoolman (DNS)"     "spoolman.home"
  ask OSPOOL_HOST   "Hostname for OpenSpoolMan (DNS)" "openspoolman.home"
  ask SPOOL_PORT    "Internal port for Spoolman"      "7912"
  ask OSPOOL_PORT   "Internal port for OpenSpoolMan"  "8000"
  echo
  info "Bambu printer credentials (required)"
  ask PRINTER_IP     "Bambu printer IP"      ""
  ask PRINTER_SERIAL "Bambu printer serial"  ""
  ask ACCESS_CODE    "Bambu LAN access code" ""

  SERVER_IP=$(hostname -I | awk '{print $1}')
  echo
  echo -e "${BOLD}Summary:${NC}"
  echo "  Spoolman      : https://${SPOOL_HOST}  (internal :${SPOOL_PORT})"
  echo "  OpenSpoolMan  : https://${OSPOOL_HOST}  (internal :${OSPOOL_PORT})"
  echo "  Printer IP    : ${PRINTER_IP}"
  echo "  Serial        : ${PRINTER_SERIAL}"
  echo "  Access code   : ${ACCESS_CODE}"
  echo
  read -rp "$(echo -e "${YELLOW}Proceed with installation? [y/N]: ${NC}")" CONFIRM
  [[ "${CONFIRM,,}" =~ ^y ]] || { info "Aborted."; exit 0; }
else
  SPOOL_HOST="${SPOOL_HOST:-spoolman.home}"
  OSPOOL_HOST="${OSPOOL_HOST:-openspoolman.home}"
  SPOOL_PORT="${SPOOL_PORT:-7912}"
  OSPOOL_PORT="${OSPOOL_PORT:-8000}"
  SERVER_IP=$(hostname -I | awk '{print $1}')
  info "Non-interactive mode — using configuration from installer."
fi

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
section "Installing system packages"
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
apt-get update -q
apt-get install -y --no-install-recommends locales > /dev/null
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen > /dev/null
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
apt-get install -y --no-install-recommends \
  git curl wget \
  python3 python3-venv python3-pip \
  build-essential libffi-dev libssl-dev openssl \
  nginx sqlite3 ca-certificates

# ---------------------------------------------------------------------------
# 2. System users
# ---------------------------------------------------------------------------
section "Creating system users"
id spoolman    &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin spoolman
id openspoolman &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin openspoolman

# ---------------------------------------------------------------------------
# 3. TLS — Root CA + per-service certificates
# ---------------------------------------------------------------------------
section "Generating TLS certificates"

SSL_DIR="/etc/ssl/spoolman-stack"
mkdir -p "${SSL_DIR}"

# Root CA
if [[ ! -f "${SSL_DIR}/ca.key" ]]; then
  info "Creating Root CA"
  openssl genrsa -out "${SSL_DIR}/ca.key" 4096
  chmod 600 "${SSL_DIR}/ca.key"
  openssl req -new -x509 -days 3650 \
    -key "${SSL_DIR}/ca.key" \
    -out "${SSL_DIR}/ca.crt" \
    -subj "/CN=Spoolman-Stack-CA/O=SpoolmanStack/C=DE"
fi

make_cert() {
  local NAME="$1" DNS_HOST="$2"
  if [[ -f "${SSL_DIR}/${NAME}.crt" ]]; then
    info "Certificate for ${NAME} already exists — skipping"
    return
  fi
  info "Issuing certificate for ${NAME} (${DNS_HOST})"
  openssl genrsa -out "${SSL_DIR}/${NAME}.key" 2048
  chmod 600 "${SSL_DIR}/${NAME}.key"

  local SAN_CNF
  SAN_CNF=$(mktemp)
  cat > "${SAN_CNF}" <<EOF
[req]
distinguished_name = req_dn
[req_dn]
[v3_req]
subjectAltName = DNS:${DNS_HOST},IP:${SERVER_IP}
EOF

  openssl req -new \
    -key "${SSL_DIR}/${NAME}.key" \
    -out "${SSL_DIR}/${NAME}.csr" \
    -subj "/CN=${DNS_HOST}/O=SpoolmanStack/C=DE"

  openssl x509 -req -days 3650 \
    -in  "${SSL_DIR}/${NAME}.csr" \
    -CA  "${SSL_DIR}/ca.crt" \
    -CAkey "${SSL_DIR}/ca.key" \
    -CAcreateserial \
    -out "${SSL_DIR}/${NAME}.crt" \
    -extfile "${SAN_CNF}" \
    -extensions v3_req

  rm -f "${SAN_CNF}" "${SSL_DIR}/${NAME}.csr"
}

make_cert "spoolman"    "${SPOOL_HOST}"
make_cert "openspoolman" "${OSPOOL_HOST}"

# ---------------------------------------------------------------------------
# 4. Spoolman
# ---------------------------------------------------------------------------
section "Installing Spoolman"

SPOOL_DIR="/opt/spoolman"
SPOOL_DATA="/var/lib/spoolman"

mkdir -p "${SPOOL_DATA}"
chown spoolman:spoolman "${SPOOL_DATA}"

if [[ -d "${SPOOL_DIR}/.git" ]]; then
  info "Updating existing Spoolman clone"
  git -C "${SPOOL_DIR}" pull --ff-only
else
  info "Cloning Spoolman"
  git clone --depth 1 https://github.com/Donkie/Spoolman.git "${SPOOL_DIR}"
fi

# Determine start method: prefer scripts/start.sh, then uv, then venv
if [[ -f "${SPOOL_DIR}/scripts/start.sh" ]]; then
  info "Using Spoolman's built-in start script"
  SPOOL_EXECSTART="/bin/bash ${SPOOL_DIR}/scripts/start.sh"

elif [[ -f "${SPOOL_DIR}/pyproject.toml" ]]; then
  info "Modern Spoolman detected (pyproject.toml) — installing uv"
  pip3 install --quiet uv
  UV_BIN="$(command -v uv)"
  UV_CACHE="${SPOOL_DIR}/.uv-cache"
  mkdir -p "${UV_CACHE}"
  info "Syncing Spoolman dependencies with uv"
  UV_CACHE_DIR="${UV_CACHE}" "${UV_BIN}" sync --project "${SPOOL_DIR}" --locked 2>/dev/null \
    || UV_CACHE_DIR="${UV_CACHE}" "${UV_BIN}" sync --project "${SPOOL_DIR}"

  # Write wrapper so systemd can call it simply
  cat > "${SPOOL_DIR}/run.sh" <<RUNSCRIPT
#!/usr/bin/env bash
export UV_CACHE_DIR=${SPOOL_DIR}/.uv-cache
exec ${UV_BIN} run --directory ${SPOOL_DIR} uvicorn spoolman.main:app --host 127.0.0.1 --port ${SPOOL_PORT}
RUNSCRIPT
  chmod +x "${SPOOL_DIR}/run.sh"
  SPOOL_EXECSTART="/bin/bash ${SPOOL_DIR}/run.sh"

else
  info "Legacy Spoolman — using venv + pip"
  [[ ! -d "${SPOOL_DIR}/venv" ]] && python3 -m venv "${SPOOL_DIR}/venv"
  "${SPOOL_DIR}/venv/bin/pip" install --quiet --upgrade pip
  "${SPOOL_DIR}/venv/bin/pip" install --quiet "uvicorn[standard]"
  [[ -f "${SPOOL_DIR}/requirements.txt" ]] && \
    "${SPOOL_DIR}/venv/bin/pip" install --quiet -r "${SPOOL_DIR}/requirements.txt"
  SPOOL_EXECSTART="${SPOOL_DIR}/venv/bin/python -m uvicorn spoolman.main:app --host 127.0.0.1 --port ${SPOOL_PORT}"
fi

cat > "${SPOOL_DIR}/.env" <<EOF
SPOOLMAN_HOST=127.0.0.1
SPOOLMAN_PORT=${SPOOL_PORT}
SPOOLMAN_DB_PATH=${SPOOL_DATA}/spoolman.db
EOF
chmod 600 "${SPOOL_DIR}/.env"
chown spoolman:spoolman "${SPOOL_DIR}/.env"
chown -R spoolman:spoolman "${SPOOL_DIR}"

cat > /etc/systemd/system/spoolman.service <<EOF
[Unit]
Description=Spoolman filament manager
After=network.target

[Service]
Type=simple
User=spoolman
WorkingDirectory=${SPOOL_DIR}
EnvironmentFile=${SPOOL_DIR}/.env
ExecStart=${SPOOL_EXECSTART}
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=${SPOOL_DATA} ${SPOOL_DIR}

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------------------
# 5. OpenSpoolMan
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
"${OSPOOL_DIR}/venv/bin/pip" install --quiet "uvicorn[standard]"
[[ -f "${OSPOOL_DIR}/requirements.txt" ]] && \
  "${OSPOOL_DIR}/venv/bin/pip" install --quiet -r "${OSPOOL_DIR}/requirements.txt"

cat > "${OSPOOL_DIR}/.env" <<EOF
BASE_URL=https://${OSPOOL_HOST}
SPOOLMAN_URL=http://127.0.0.1:${SPOOL_PORT}
PORT=${OSPOOL_PORT}
BAMBU_PRINTER_IP=${PRINTER_IP}
BAMBU_PRINTER_SERIAL=${PRINTER_SERIAL}
BAMBU_ACCESS_CODE=${ACCESS_CODE}
EOF
chmod 600 "${OSPOOL_DIR}/.env"
chown openspoolman:openspoolman "${OSPOOL_DIR}/.env"
chown -R openspoolman:openspoolman "${OSPOOL_DIR}"

cat > /etc/systemd/system/openspoolman.service <<EOF
[Unit]
Description=OpenSpoolMan Bambu bridge
After=network.target spoolman.service
Requires=spoolman.service

[Service]
Type=simple
User=openspoolman
WorkingDirectory=${OSPOOL_DIR}
EnvironmentFile=${OSPOOL_DIR}/.env
ExecStart=${OSPOOL_DIR}/venv/bin/python -m uvicorn main:app --host 127.0.0.1 --port ${OSPOOL_PORT}
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=${OSPOOL_DIR}

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------------------
# 6. Nginx
# ---------------------------------------------------------------------------
section "Configuring Nginx"

# Disable default site
unlink /etc/nginx/sites-enabled/default 2>/dev/null || true

mkdir -p /var/www/html

# Spoolman vhost
cat > /etc/nginx/sites-available/spoolman <<EOF
server {
    listen 443 ssl;
    server_name ${SPOOL_HOST};

    ssl_certificate     ${SSL_DIR}/spoolman.crt;
    ssl_certificate_key ${SSL_DIR}/spoolman.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass         http://127.0.0.1:${SPOOL_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";
    }
}
EOF

# OpenSpoolMan vhost
cat > /etc/nginx/sites-available/openspoolman <<EOF
server {
    listen 443 ssl;
    server_name ${OSPOOL_HOST};

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
EOF

# CA download vhost (plain HTTP, port 8080)
cat > /etc/nginx/sites-available/spoolman-ca <<EOF
server {
    listen 8080;
    server_name _;
    root /var/www/html;

    location /spoolman-ca.crt {
        default_type application/x-x509-ca-cert;
    }
}
EOF

# Copy CA cert to web root
cp "${SSL_DIR}/ca.crt" /var/www/html/spoolman-ca.crt
chmod 644 /var/www/html/spoolman-ca.crt

# Enable sites
ln -sf /etc/nginx/sites-available/spoolman      /etc/nginx/sites-enabled/spoolman
ln -sf /etc/nginx/sites-available/openspoolman  /etc/nginx/sites-enabled/openspoolman
ln -sf /etc/nginx/sites-available/spoolman-ca   /etc/nginx/sites-enabled/spoolman-ca

info "Testing Nginx configuration"
nginx -t

# ---------------------------------------------------------------------------
# 7. Update command  (/usr/local/bin/update)
# ---------------------------------------------------------------------------
section "Installing update command"

cat > /usr/local/bin/update <<'UPDATESCRIPT'
#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
section() { echo -e "\n${BLUE}${BOLD}==> $*${NC}"; }

[[ $EUID -ne 0 ]] && { echo -e "${RED}[ERROR]${NC} Run as root."; exit 1; }

update_repo() {
  local NAME="$1" DIR="$2" SERVICE="$3"
  section "Checking ${NAME}"

  if [[ ! -d "${DIR}/.git" ]]; then
    warn "${DIR} is not a git repo — skipping."
    return
  fi

  local BEFORE
  BEFORE=$(git -C "${DIR}" rev-parse HEAD)
  git -C "${DIR}" fetch --quiet origin

  local REMOTE
  REMOTE=$(git -C "${DIR}" rev-parse '@{u}' 2>/dev/null || \
           git -C "${DIR}" rev-parse origin/HEAD 2>/dev/null || \
           git -C "${DIR}" rev-parse origin/main 2>/dev/null)

  if [[ "$BEFORE" == "$REMOTE" ]]; then
    info "${NAME}: already up to date (${BEFORE:0:7})."
    return
  fi

  info "${NAME}: update found (${BEFORE:0:7} → ${REMOTE:0:7}) — applying…"
  systemctl stop "${SERVICE}"

  git -C "${DIR}" pull --ff-only --quiet

  if [[ -f "${DIR}/requirements.txt" && -x "${DIR}/venv/bin/pip" ]]; then
    info "Updating Python dependencies…"
    "${DIR}/venv/bin/pip" install --quiet --upgrade pip
    "${DIR}/venv/bin/pip" install --quiet -r "${DIR}/requirements.txt"
  fi

  systemctl start "${SERVICE}"
  info "${NAME}: updated and restarted."
}

update_repo "Spoolman"     "/opt/spoolman"     "spoolman"
update_repo "OpenSpoolMan" "/opt/openspoolman" "openspoolman"

section "Service status"
systemctl --no-pager status spoolman openspoolman --lines=0
UPDATESCRIPT

chmod +x /usr/local/bin/update
info "'update' command installed — run it as root to update both services."

# ---------------------------------------------------------------------------
# 8. Enable and start services
# ---------------------------------------------------------------------------
section "Starting services"

systemctl daemon-reload
systemctl enable --now spoolman
systemctl enable --now openspoolman
systemctl enable --now nginx

# Brief pause to let services come up
sleep 3

# ---------------------------------------------------------------------------
# 9. Summary
# ---------------------------------------------------------------------------
echo
echo -e "${GREEN}${BOLD}"
cat <<EOF
============================================================
  Installation complete!
============================================================

  Spoolman:
    https://${SPOOL_HOST}

  OpenSpoolMan:
    https://${OSPOOL_HOST}

  CA certificate (install this on your devices):
    http://${SERVER_IP}:8080/spoolman-ca.crt

  DNS entries to add:
    ${SPOOL_HOST}   →  ${SERVER_IP}
    ${OSPOOL_HOST}  →  ${SERVER_IP}

  iPhone / iPad:
    Open http://${SERVER_IP}:8080/spoolman-ca.crt in Safari
    → Settings → General → VPN & Device Management
    → Install certificate, then:
    → Settings → General → About → Certificate Trust Settings
    → Enable full trust for the Spoolman-Stack-CA

============================================================
EOF
echo -e "${NC}"

section "Service status"
systemctl --no-pager status spoolman openspoolman nginx
