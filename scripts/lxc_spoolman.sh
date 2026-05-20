#!/usr/bin/env bash
# lxc_spoolman.sh — runs inside the Spoolman LXC container
# Installs Spoolman only; binds to 0.0.0.0 so OpenSpoolMan LXC can reach it.
# No nginx, no SSL — plain HTTP on SPOOL_PORT.
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
# Configuration
# ---------------------------------------------------------------------------
SPOOL_PORT="${SPOOL_PORT:-7912}"

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
  sqlite3 build-essential libffi-dev libssl-dev

# ---------------------------------------------------------------------------
# 2. System user
# ---------------------------------------------------------------------------
section "Creating system user"
id spoolman &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin spoolman

# ---------------------------------------------------------------------------
# 3. uv package manager
# ---------------------------------------------------------------------------
section "Installing uv"
pip3 install uv --quiet --break-system-packages --root-user-action=ignore
hash -r 2>/dev/null || true
UV_BIN="$(command -v uv 2>/dev/null || echo /usr/local/bin/uv)"
info "uv: $("${UV_BIN}" --version)"

# ---------------------------------------------------------------------------
# 4. Download Spoolman
# ---------------------------------------------------------------------------
section "Downloading Spoolman"

SPOOL_DIR="/opt/spoolman"

SPOOL_RELEASE=$(curl -fsSL https://api.github.com/repos/Donkie/Spoolman/releases/latest \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["tag_name"])' 2>/dev/null \
  || echo "v0.21.1")
info "Latest Spoolman release: ${SPOOL_RELEASE}"

if [[ -d "${SPOOL_DIR}/client/dist" ]]; then
  info "Spoolman already present — skipping download"
else
  info "Downloading Spoolman ${SPOOL_RELEASE}"
  curl -fsSL "https://github.com/Donkie/Spoolman/releases/download/${SPOOL_RELEASE}/spoolman.zip" \
    -o /tmp/spoolman.zip
  rm -rf "${SPOOL_DIR}"
  mkdir -p "${SPOOL_DIR}"
  python3 -m zipfile -e /tmp/spoolman.zip "${SPOOL_DIR}"
  rm -f /tmp/spoolman.zip
fi

# ---------------------------------------------------------------------------
# 5. Sync dependencies with uv
# ---------------------------------------------------------------------------
section "Syncing Spoolman dependencies"

UV_CACHE="${SPOOL_DIR}/.uv-cache"
mkdir -p "${UV_CACHE}"

UV_CACHE_DIR="${UV_CACHE}" "${UV_BIN}" --directory "${SPOOL_DIR}" sync --no-dev --locked 2>/dev/null \
  || UV_CACHE_DIR="${UV_CACHE}" "${UV_BIN}" --directory "${SPOOL_DIR}" sync --no-dev

chown -R spoolman:spoolman "${SPOOL_DIR}"

# ---------------------------------------------------------------------------
# 6. .env and systemd service
# ---------------------------------------------------------------------------
section "Configuring Spoolman service"

cat > "${SPOOL_DIR}/.env" <<EOF
SPOOLMAN_HOST=0.0.0.0
SPOOLMAN_PORT=${SPOOL_PORT}
SPOOLMAN_LOGGING_LEVEL=WARNING
EOF
chmod 600 "${SPOOL_DIR}/.env"
chown spoolman:spoolman "${SPOOL_DIR}/.env"

cat > /etc/systemd/system/spoolman.service <<EOF
[Unit]
Description=Spoolman filament manager
After=network.target

[Service]
Type=simple
User=spoolman
WorkingDirectory=${SPOOL_DIR}
EnvironmentFile=${SPOOL_DIR}/.env
Environment=UV_CACHE_DIR=${SPOOL_DIR}/.uv-cache
ExecStart=${UV_BIN} --directory ${SPOOL_DIR} run uvicorn spoolman.main:app --host 0.0.0.0 --port ${SPOOL_PORT}
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=${SPOOL_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now spoolman

# ---------------------------------------------------------------------------
# 7. Wait for Spoolman to be ready
# ---------------------------------------------------------------------------
section "Waiting for Spoolman API"

_SPOOL_READY=0
for _i in $(seq 1 60); do
  if curl -fsSL "http://127.0.0.1:${SPOOL_PORT}/api/v1/info" -o /dev/null 2>/dev/null; then
    _SPOOL_READY=1; break
  fi
  sleep 1
done

if [[ $_SPOOL_READY -eq 0 ]]; then
  warn "Spoolman not reachable after 60 s — custom fields will not be created."
  warn "Add them manually in Spoolman Settings after it starts."
fi

# ---------------------------------------------------------------------------
# 8. Create Spoolman custom fields (required by OpenSpoolMan)
# ---------------------------------------------------------------------------
if [[ $_SPOOL_READY -eq 1 ]]; then
  section "Configuring Spoolman custom fields"

  _spoolman_field() {
    local entity="$1" key="$2" name="$3" ftype="$4" extra="$5"
    local url="http://127.0.0.1:${SPOOL_PORT}/api/v1/field/${entity}"
    if curl -fsSL "${url}" | python3 -c "import sys,json; fields=json.load(sys.stdin); exit(0 if any(f['key']=='${key}' for f in fields) else 1)" 2>/dev/null; then
      info "Field '${key}' on ${entity} already exists — skipping"
      return
    fi
    local body="{\"key\":\"${key}\",\"name\":\"${name}\",\"field_type\":\"${ftype}\"${extra}}"
    if curl -fsSL -X POST "${url}" \
        -H "Content-Type: application/json" \
        -d "${body}" -o /dev/null; then
      info "Created field '${key}' on ${entity}"
    else
      warn "Could not create field '${key}' on ${entity} — add it manually in Spoolman settings"
    fi
  }

  CHOICE_VALUES='"AERO,CF,GF,FR,Basic,HF,Translucent,Aero,Dynamic,Galaxy,Glow,Impact,Lite,Marble,Matte,Metal,Silk,Silk+,Sparkle,Tough,Tough+,Wood,Support for ABS,Support for PA PET,Support for PLA,Support for PLA-PETG,G,W,85A,90A,95A,95A HF,for AMS"'
  _spoolman_field "filament" "type"               "Type"               "choice"  ",\"choices\":${CHOICE_VALUES}"
  _spoolman_field "filament" "nozzle_temperature" "Nozzle Temperature" "integer" ""
  _spoolman_field "filament" "filament_id"        "Filament ID"        "text"    ""
  _spoolman_field "spool"    "tag"                "tag"                "text"    ""
  _spoolman_field "spool"    "active_tray"        "Active Tray"        "text"    ""
fi

# ---------------------------------------------------------------------------
# 9. Summary
# ---------------------------------------------------------------------------
SERVER_IP=$(hostname -I | awk '{print $1}')

echo
echo -e "${GREEN}${BOLD}"
cat <<EOF
============================================================
  Spoolman installation complete
============================================================

  IP address : ${SERVER_IP}
  Port       : ${SPOOL_PORT}
  URL        : http://${SERVER_IP}:${SPOOL_PORT}
  API        : http://${SERVER_IP}:${SPOOL_PORT}/api/v1/info

  This container has no HTTPS — OpenSpoolMan connects
  to it over plain HTTP from the adjacent LXC.

============================================================
EOF
echo -e "${NC}"

section "Service status"
systemctl --no-pager status spoolman --lines=5
