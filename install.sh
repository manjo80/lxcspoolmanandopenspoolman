#!/usr/bin/env bash
# install.sh — Proxmox host script for the Spoolman Stack LXC installer
# Run on the Proxmox host:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Manjo80/spoolman-stack/main/install.sh)"
set -euo pipefail

# ---------------------------------------------------------------------------
# Inline helpers (no external source needed on the host)
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${BLUE}${BOLD}==> $*${NC}"; }

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
echo -e "${BOLD}  Spoolman + OpenSpoolMan — Proxmox LXC Installer${NC}"
echo    "  github.com/Manjo80/spoolman-stack"
echo

# Proxmox check
if ! command -v pct &>/dev/null; then
  error "'pct' not found. This script must run on a Proxmox VE host."
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  error "Run as root on the Proxmox host."
  exit 1
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
section "LXC Container Configuration"

NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")

ask CTID       "Container ID"        "${NEXT_ID}"
ask HOSTNAME   "LXC hostname"        "spoolman"
ask RAM        "RAM (MB)"            "1024"
ask CORES      "CPU cores"           "2"
ask DISK       "Disk size (GB)"      "8"
ask STORAGE    "Storage"             "local-lvm"
ask BRIDGE     "Network bridge"      "vmbr0"

echo
echo -e "${CYAN}IP configuration:${NC}"
echo    "  1) DHCP"
echo    "  2) Static"
read -rp "$(echo -e "${CYAN}Choice${NC} [1]: ")" IP_CHOICE
IP_CHOICE=${IP_CHOICE:-1}

if [[ "$IP_CHOICE" == "2" ]]; then
  ask CT_IP  "Container IP (CIDR, e.g. 192.168.1.50/24)" ""
  ask CT_GW  "Gateway"                                    ""
  ask CT_DNS "DNS server"                                  "8.8.8.8"
  NET_CONFIG="ip=${CT_IP},gw=${CT_GW}"
  DNS_CONFIG="--nameserver ${CT_DNS}"
else
  NET_CONFIG="ip=dhcp"
  DNS_CONFIG=""
fi

# ---------------------------------------------------------------------------
# Debian 13 template
# ---------------------------------------------------------------------------
section "Checking Debian 12 template"

TEMPLATE_NAME="debian-13-standard_13.1-2_amd64.tar.zst"
TEMPLATE_PATH="local:vztmpl/${TEMPLATE_NAME}"

if ! pveam list local 2>/dev/null | grep -q "${TEMPLATE_NAME}"; then
  info "Template not found — downloading…"
  pveam update
  pveam download local "${TEMPLATE_NAME}"
else
  info "Template already present."
fi

# ---------------------------------------------------------------------------
# Create LXC container
# ---------------------------------------------------------------------------
section "Creating LXC container ${CTID}"

if pct status "${CTID}" &>/dev/null; then
  warn "Container ${CTID} already exists — skipping creation."
else
  # shellcheck disable=SC2086
  pct create "${CTID}" "${TEMPLATE_PATH}" \
    --hostname  "${HOSTNAME}" \
    --memory    "${RAM}" \
    --cores     "${CORES}" \
    --rootfs    "${STORAGE}:${DISK}" \
    --net0      "name=eth0,bridge=${BRIDGE},${NET_CONFIG}" \
    --ostype    debian \
    --unprivileged 1 \
    --features  nesting=1 \
    ${DNS_CONFIG}
  info "Container ${CTID} created."
fi

# ---------------------------------------------------------------------------
# Start and wait
# ---------------------------------------------------------------------------
section "Starting container"

if [[ $(pct status "${CTID}" | awk '{print $2}') != "running" ]]; then
  pct start "${CTID}"
fi

info "Waiting for container to become ready…"
for i in $(seq 1 30); do
  if pct exec "${CTID}" -- true &>/dev/null 2>&1; then
    info "Container ready (${i}s)."
    break
  fi
  sleep 1
done

# ---------------------------------------------------------------------------
# Run installer inside container
# ---------------------------------------------------------------------------
section "Running stack installer inside container"

LXC_SCRIPT_URL="https://raw.githubusercontent.com/Manjo80/spoolman-stack/main/scripts/lxc_install.sh"

pct exec "${CTID}" -- bash -c "apt-get install -y --no-install-recommends curl ca-certificates &>/dev/null && \
  bash <(curl -fsSL '${LXC_SCRIPT_URL}')"

# ---------------------------------------------------------------------------
# Host-side summary
# ---------------------------------------------------------------------------
CT_IP_ACTUAL=$(pct exec "${CTID}" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "<container-ip>")

echo
echo -e "${GREEN}${BOLD}"
cat <<EOF
============================================================
  Proxmox LXC deployment complete
============================================================

  Container ID : ${CTID}
  Hostname     : ${HOSTNAME}
  IP address   : ${CT_IP_ACTUAL}

  Open the stack URLs shown above in your browser.
  Install the CA certificate to trust HTTPS.

============================================================
EOF
echo -e "${NC}"
