#!/usr/bin/env bash
# install.sh — Proxmox host script: creates two separate LXC containers
#   LXC 1: Spoolman (no nginx, plain HTTP on port 7912)
#   LXC 2: OpenSpoolMan (nginx + self-signed SSL, connects to LXC 1)
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
echo -e "${BOLD}  Spoolman + OpenSpoolMan — Proxmox LXC Installer (2-container)${NC}"
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
# Spoolman LXC Configuration
# ---------------------------------------------------------------------------
section "Spoolman LXC Configuration"

NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")

ask CTID1      "Container ID (Spoolman)"          "${NEXT_ID}"
ask HOSTNAME1  "LXC hostname (Spoolman)"          "spoolman"
ask RAM1       "RAM (MB)"                         "512"
ask CORES1     "CPU cores"                        "1"
ask DISK1      "Disk size (GB)"                   "4"

# ---------------------------------------------------------------------------
# OpenSpoolMan LXC Configuration
# ---------------------------------------------------------------------------
section "OpenSpoolMan LXC Configuration"

NEXT_ID2=$(( CTID1 + 1 ))

ask CTID2      "Container ID (OpenSpoolMan)"      "${NEXT_ID2}"
ask HOSTNAME2  "LXC hostname (OpenSpoolMan)"      "openspoolman"
ask RAM2       "RAM (MB)"                         "512"
ask CORES2     "CPU cores"                        "1"
ask DISK2      "Disk size (GB)"                   "4"

# ---------------------------------------------------------------------------
# Shared: storage + bridge
# ---------------------------------------------------------------------------
section "Shared Network & Storage Configuration"

# Storage picker — list every active rootdir-capable storage with free space
mapfile -t _STOR_ROWS < <(
  pvesm status --content rootdir 2>/dev/null \
    | awk 'NR>1 && $3=="active" {printf "%s|%.1f GB\n", $1, $6/1024/1024}'
)
if [[ ${#_STOR_ROWS[@]} -eq 0 ]]; then
  error "No active storage with 'rootdir' support found. Check 'pvesm status'."
  exit 1
fi
echo
echo -e "${CYAN}Available storages:${NC}"
for i in "${!_STOR_ROWS[@]}"; do
  IFS='|' read -r _name _avail <<< "${_STOR_ROWS[$i]}"
  printf "  %d)  %-20s %s free\n" "$((i+1))" "${_name}" "${_avail}"
done
echo
read -rp "$(echo -e "${CYAN}Storage choice${NC} [1]: ")" _SC
_SC=${_SC:-1}
if [[ ! "${_SC}" =~ ^[0-9]+$ ]] || (( _SC < 1 || _SC > ${#_STOR_ROWS[@]} )); then
  error "Invalid choice '${_SC}'."; exit 1
fi
IFS='|' read -r STORAGE _ <<< "${_STOR_ROWS[$((_SC-1))]}"
info "Using storage: ${STORAGE}"

ask BRIDGE     "Network bridge"                   "vmbr0"

# ---------------------------------------------------------------------------
# Network config for each container
# ---------------------------------------------------------------------------
echo
echo -e "${CYAN}IP configuration for Spoolman LXC (CT${CTID1}):${NC}"
echo    "  1) DHCP"
echo    "  2) Static"
read -rp "$(echo -e "${CYAN}Choice${NC} [1]: ")" IP_CHOICE1
IP_CHOICE1=${IP_CHOICE1:-1}

if [[ "$IP_CHOICE1" == "2" ]]; then
  ask CT1_IP  "Spoolman IP (CIDR, e.g. 192.168.1.50/24)" ""
  ask CT1_GW  "Gateway"                                   ""
  ask CT1_DNS "DNS server"                                 "8.8.8.8"
  CT1_NET_CONFIG="ip=${CT1_IP},gw=${CT1_GW}"
  CT1_DNS_CONFIG="--nameserver ${CT1_DNS}"
else
  CT1_NET_CONFIG="ip=dhcp"
  CT1_DNS_CONFIG=""
fi

echo
echo -e "${CYAN}IP configuration for OpenSpoolMan LXC (CT${CTID2}):${NC}"
echo    "  1) DHCP"
echo    "  2) Static"
read -rp "$(echo -e "${CYAN}Choice${NC} [1]: ")" IP_CHOICE2
IP_CHOICE2=${IP_CHOICE2:-1}

if [[ "$IP_CHOICE2" == "2" ]]; then
  ask CT2_IP  "OpenSpoolMan IP (CIDR, e.g. 192.168.1.51/24)" ""
  ask CT2_GW  "Gateway"                                      ""
  ask CT2_DNS "DNS server"                                    "8.8.8.8"
  CT2_NET_CONFIG="ip=${CT2_IP},gw=${CT2_GW}"
  CT2_DNS_CONFIG="--nameserver ${CT2_DNS}"
else
  CT2_NET_CONFIG="ip=dhcp"
  CT2_DNS_CONFIG=""
fi

# ---------------------------------------------------------------------------
# Root password (shared for both containers)
# ---------------------------------------------------------------------------
echo
echo -e "${CYAN}Root password (used for both containers):${NC}"
while true; do
  read -rsp "$(echo -e "${CYAN}Root password${NC}: ")" ROOT_PW; echo
  [[ -n "$ROOT_PW" ]] && break
  warn "Password must not be empty."
done
while true; do
  read -rsp "$(echo -e "${CYAN}Confirm root password${NC}: ")" ROOT_PW2; echo
  [[ "$ROOT_PW" == "$ROOT_PW2" ]] && break
  warn "Passwords do not match — try again."
  read -rsp "$(echo -e "${CYAN}Root password${NC}: ")" ROOT_PW; echo
done
info "Root password set."

# ---------------------------------------------------------------------------
# Stack Configuration
# ---------------------------------------------------------------------------
section "Stack Configuration"

ask OSPOOL_HOST  "Hostname for OpenSpoolMan (DNS)"   "openspoolman.home"
ask SPOOL_PORT   "Spoolman port"                     "7912"
ask OSPOOL_PORT  "OpenSpoolMan internal port"        "8000"

echo
info "Bambu printer credentials (required)"
ask PRINTER_IP     "Bambu printer IP"                                    ""
ask PRINTER_SERIAL "Bambu printer ID (Settings → Device → Printer SN)"  ""
ask ACCESS_CODE    "Bambu LAN access code (Settings → LAN Only Mode)"    ""

# ---------------------------------------------------------------------------
# Confirmation summary
# ---------------------------------------------------------------------------
echo
echo -e "${BOLD}Summary:${NC}"
echo    "  --- Spoolman LXC ---"
echo    "  Container ID  : ${CTID1}  (${CORES1} cores, ${RAM1} MB RAM, ${DISK1} GB on ${STORAGE})"
echo    "  Hostname      : ${HOSTNAME1}  bridge ${BRIDGE}  net ${CT1_NET_CONFIG}"
echo    "  Spoolman port : ${SPOOL_PORT}"
echo    "  --- OpenSpoolMan LXC ---"
echo    "  Container ID  : ${CTID2}  (${CORES2} cores, ${RAM2} MB RAM, ${DISK2} GB on ${STORAGE})"
echo    "  Hostname      : ${HOSTNAME2}  bridge ${BRIDGE}  net ${CT2_NET_CONFIG}"
echo    "  OpenSpoolMan  : https://${OSPOOL_HOST}  (internal :${OSPOOL_PORT})"
echo    "  --- Shared ---"
echo    "  Printer IP    : ${PRINTER_IP}"
echo    "  Serial        : ${PRINTER_SERIAL}"
echo    "  Access code   : ${ACCESS_CODE}"
echo
read -rp "$(echo -e "${YELLOW}Proceed? [y/N]: ${NC}")" _CONFIRM
[[ "${_CONFIRM,,}" =~ ^y ]] || { info "Aborted."; exit 0; }

# ---------------------------------------------------------------------------
# Template detection (shared between both containers)
# ---------------------------------------------------------------------------
section "Detecting template storage"

TMPL_STORAGE=$(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 {print $1}' | head -1)
if [[ -z "${TMPL_STORAGE}" ]]; then
  error "No storage with vztmpl support found. Check 'pvesm status'."
  exit 1
fi
info "Using template storage: ${TMPL_STORAGE}"

section "Checking Debian 13 template"

pveam update
TEMPLATE_NAME=$(pveam available --section system 2>/dev/null \
  | awk '{print $2}' | grep "^debian-13" | sort -V | tail -1)

if [[ -z "${TEMPLATE_NAME}" ]]; then
  error "No Debian 13 template found in pveam available. Run 'pveam update' manually and retry."
  exit 1
fi
info "Latest Debian 13 template: ${TEMPLATE_NAME}"

TEMPLATE_PATH="${TMPL_STORAGE}:vztmpl/${TEMPLATE_NAME}"

if ! pveam list "${TMPL_STORAGE}" 2>/dev/null | grep -q "${TEMPLATE_NAME}"; then
  info "Template not found — downloading…"
  pveam download "${TMPL_STORAGE}" "${TEMPLATE_NAME}"
else
  info "Template already present."
fi

# ---------------------------------------------------------------------------
# Create LXC 1 — Spoolman
# ---------------------------------------------------------------------------
section "Creating Spoolman LXC (CT${CTID1})"

if pct status "${CTID1}" &>/dev/null; then
  warn "Container ${CTID1} already exists — skipping creation."
else
  PCT_ARGS1=(
    "${CTID1}" "${TEMPLATE_PATH}"
    --hostname  "${HOSTNAME1}"
    --memory    "${RAM1}"
    --cores     "${CORES1}"
    --rootfs    "${STORAGE}:${DISK1}"
    --net0      "name=eth0,bridge=${BRIDGE},${CT1_NET_CONFIG}"
    --ostype    debian
    --unprivileged 1
    --features  nesting=1
    --password  "${ROOT_PW}"
  )
  # shellcheck disable=SC2086
  [[ -n "${CT1_DNS_CONFIG}" ]] && PCT_ARGS1+=(${CT1_DNS_CONFIG})
  pct create "${PCT_ARGS1[@]}"
  info "Container ${CTID1} created."
fi

# ---------------------------------------------------------------------------
# Create LXC 2 — OpenSpoolMan
# ---------------------------------------------------------------------------
section "Creating OpenSpoolMan LXC (CT${CTID2})"

if pct status "${CTID2}" &>/dev/null; then
  warn "Container ${CTID2} already exists — skipping creation."
else
  PCT_ARGS2=(
    "${CTID2}" "${TEMPLATE_PATH}"
    --hostname  "${HOSTNAME2}"
    --memory    "${RAM2}"
    --cores     "${CORES2}"
    --rootfs    "${STORAGE}:${DISK2}"
    --net0      "name=eth0,bridge=${BRIDGE},${CT2_NET_CONFIG}"
    --ostype    debian
    --unprivileged 1
    --features  nesting=1
    --password  "${ROOT_PW}"
  )
  # shellcheck disable=SC2086
  [[ -n "${CT2_DNS_CONFIG}" ]] && PCT_ARGS2+=(${CT2_DNS_CONFIG})
  pct create "${PCT_ARGS2[@]}"
  info "Container ${CTID2} created."
fi

# ---------------------------------------------------------------------------
# Start LXC 1, wait for ready, install Spoolman
# ---------------------------------------------------------------------------
section "Starting Spoolman container (CT${CTID1})"

if [[ $(pct status "${CTID1}" | awk '{print $2}') != "running" ]]; then
  pct start "${CTID1}"
fi

info "Waiting for Spoolman container to become ready…"
for i in $(seq 1 30); do
  if pct exec "${CTID1}" -- true &>/dev/null 2>&1; then
    info "Container ${CTID1} ready (${i}s)."; break
  fi
  sleep 1
done

section "Running Spoolman installer inside CT${CTID1}"

LXC_SPOOLMAN_URL="https://raw.githubusercontent.com/Manjo80/lxcspoolmanandopenspoolman/main/scripts/lxc_spoolman.sh"

pct exec "${CTID1}" -- env \
  DEBIAN_FRONTEND=noninteractive \
  SPOOL_PORT="${SPOOL_PORT}" \
  bash -c "
    set -euo pipefail
    apt-get update -q
    apt-get install -y --no-install-recommends curl ca-certificates > /dev/null
    curl -fsSL '${LXC_SPOOLMAN_URL}' -o /tmp/lxc_spoolman.sh
    bash /tmp/lxc_spoolman.sh
    rm -f /tmp/lxc_spoolman.sh
  "

# Get Spoolman IP so OpenSpoolMan can reach it
SPOOLMAN_IP=$(pct exec "${CTID1}" -- hostname -I 2>/dev/null | awk '{print $1}')
info "Spoolman IP: ${SPOOLMAN_IP}"

# ---------------------------------------------------------------------------
# Start LXC 2, wait for ready, install OpenSpoolMan
# ---------------------------------------------------------------------------
section "Starting OpenSpoolMan container (CT${CTID2})"

if [[ $(pct status "${CTID2}" | awk '{print $2}') != "running" ]]; then
  pct start "${CTID2}"
fi

info "Waiting for OpenSpoolMan container to become ready…"
for i in $(seq 1 30); do
  if pct exec "${CTID2}" -- true &>/dev/null 2>&1; then
    info "Container ${CTID2} ready (${i}s)."; break
  fi
  sleep 1
done

section "Running OpenSpoolMan installer inside CT${CTID2}"

LXC_OSPOOL_URL="https://raw.githubusercontent.com/Manjo80/lxcspoolmanandopenspoolman/main/scripts/lxc_openspoolman.sh"

pct exec "${CTID2}" -- env \
  DEBIAN_FRONTEND=noninteractive \
  SPOOLMAN_IP="${SPOOLMAN_IP}" \
  SPOOL_PORT="${SPOOL_PORT}" \
  OSPOOL_HOST="${OSPOOL_HOST}" \
  OSPOOL_PORT="${OSPOOL_PORT}" \
  PRINTER_IP="${PRINTER_IP}" \
  PRINTER_SERIAL="${PRINTER_SERIAL}" \
  ACCESS_CODE="${ACCESS_CODE}" \
  bash -c "
    set -euo pipefail
    apt-get update -q
    apt-get install -y --no-install-recommends curl ca-certificates > /dev/null
    curl -fsSL '${LXC_OSPOOL_URL}' -o /tmp/lxc_openspoolman.sh
    bash /tmp/lxc_openspoolman.sh
    rm -f /tmp/lxc_openspoolman.sh
  "

OSPOOL_IP=$(pct exec "${CTID2}" -- hostname -I 2>/dev/null | awk '{print $1}')

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
echo
echo -e "${GREEN}${BOLD}"
cat <<EOF
============================================================
  Proxmox LXC deployment complete
============================================================

  Spoolman (CT${CTID1})
    Hostname  : ${HOSTNAME1}
    IP        : ${SPOOLMAN_IP}
    URL       : http://${SPOOLMAN_IP}:${SPOOL_PORT}

  OpenSpoolMan (CT${CTID2})
    Hostname  : ${HOSTNAME2}
    IP        : ${OSPOOL_IP}
    URL       : https://${OSPOOL_IP}
    CA cert   : http://${OSPOOL_IP}:8080/spoolman-ca.crt

  /etc/hosts entries (on your client machines):
    ${SPOOLMAN_IP}  ${HOSTNAME1}.home
    ${OSPOOL_IP}  ${OSPOOL_HOST}

  Install the CA certificate to trust HTTPS on OpenSpoolMan.
  Download it from: http://${OSPOOL_IP}:8080/spoolman-ca.crt

============================================================
EOF
echo -e "${NC}"
