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

echo
echo -e "${CYAN}Root login:${NC}"
echo    "  1) Enable root login with password"
echo    "  2) Disable root login (SSH key only)"
read -rp "$(echo -e "${CYAN}Choice${NC} [1]: ")" ROOT_CHOICE
ROOT_CHOICE=${ROOT_CHOICE:-1}

ROOT_PW=""
if [[ "$ROOT_CHOICE" == "1" ]]; then
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
  info "Root login: enabled"
else
  info "Root login: disabled"
fi

# ---------------------------------------------------------------------------
# Spoolman stack configuration
# ---------------------------------------------------------------------------
section "Spoolman Stack Configuration"

ask SPOOL_HOST   "Hostname for Spoolman (DNS)"       "spoolman.home"
ask OSPOOL_HOST  "Hostname for OpenSpoolMan (DNS)"   "openspoolman.home"
ask SPOOL_HTTPS  "HTTPS port for Spoolman Nginx"     "7913"
ask OSPOOL_HTTPS "HTTPS port for OpenSpoolMan Nginx" "8443"
ask SPOOL_PORT   "Internal port for Spoolman"        "7912"
ask OSPOOL_PORT  "Internal port for OpenSpoolMan"    "8000"

echo
info "Bambu printer credentials (required)"
ask PRINTER_IP     "Bambu printer IP"       ""
ask PRINTER_SERIAL "Bambu printer serial"   ""
ask ACCESS_CODE    "Bambu LAN access code"  ""

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
echo
echo -e "${BOLD}Summary:${NC}"
echo    "  Container ID  : ${CTID}  (${CORES} cores, ${RAM} MB RAM, ${DISK} GB on ${STORAGE})"
echo    "  Hostname      : ${HOSTNAME}  bridge ${BRIDGE}  net ${NET_CONFIG}"
echo    "  Root login    : $( [[ -n "$ROOT_PW" ]] && echo enabled || echo disabled )"
echo    "  Spoolman      : ${SPOOL_HOST}  HTTPS :${SPOOL_HTTPS} → :${SPOOL_PORT}"
echo    "  OpenSpoolMan  : ${OSPOOL_HOST}  HTTPS :${OSPOOL_HTTPS} → :${OSPOOL_PORT}"
echo    "  Printer IP    : ${PRINTER_IP}"
echo    "  Serial        : ${PRINTER_SERIAL}"
echo    "  Access code   : ${ACCESS_CODE}"
echo
read -rp "$(echo -e "${YELLOW}Proceed? [y/N]: ${NC}")" _CONFIRM
[[ "${_CONFIRM,,}" =~ ^y ]] || { info "Aborted."; exit 0; }

# ---------------------------------------------------------------------------
# Detect template storage (first storage that supports vztmpl content)
# ---------------------------------------------------------------------------
section "Detecting template storage"

TMPL_STORAGE=$(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 {print $1}' | head -1)
if [[ -z "${TMPL_STORAGE}" ]]; then
  error "No storage with vztmpl support found. Check 'pvesm status'."
  exit 1
fi
info "Using template storage: ${TMPL_STORAGE}"

# ---------------------------------------------------------------------------
# Debian 13 template
# ---------------------------------------------------------------------------
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
# Create LXC container
# ---------------------------------------------------------------------------
section "Creating LXC container ${CTID}"

if pct status "${CTID}" &>/dev/null; then
  warn "Container ${CTID} already exists — skipping creation."
else
  PCT_ARGS=(
    "${CTID}" "${TEMPLATE_PATH}"
    --hostname  "${HOSTNAME}"
    --memory    "${RAM}"
    --cores     "${CORES}"
    --rootfs    "${STORAGE}:${DISK}"
    --net0      "name=eth0,bridge=${BRIDGE},${NET_CONFIG}"
    --ostype    debian
    --unprivileged 1
    --features  nesting=1
  )
  [[ -n "$ROOT_PW" ]] && PCT_ARGS+=(--password "${ROOT_PW}")
  # shellcheck disable=SC2086
  [[ -n "$DNS_CONFIG" ]] && PCT_ARGS+=(${DNS_CONFIG})
  pct create "${PCT_ARGS[@]}"
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

LXC_SCRIPT_URL="https://raw.githubusercontent.com/Manjo80/lxcspoolmanandopenspoolman/main/scripts/lxc_install.sh"

pct exec "${CTID}" -- env \
  SPOOL_HOST="${SPOOL_HOST}" \
  OSPOOL_HOST="${OSPOOL_HOST}" \
  SPOOL_HTTPS="${SPOOL_HTTPS}" \
  OSPOOL_HTTPS="${OSPOOL_HTTPS}" \
  SPOOL_PORT="${SPOOL_PORT}" \
  OSPOOL_PORT="${OSPOOL_PORT}" \
  PRINTER_IP="${PRINTER_IP}" \
  PRINTER_SERIAL="${PRINTER_SERIAL}" \
  ACCESS_CODE="${ACCESS_CODE}" \
  bash -c "
    set -euo pipefail
    apt-get update -q
    apt-get install -y --no-install-recommends curl ca-certificates > /dev/null
    curl -fsSL '${LXC_SCRIPT_URL}' -o /tmp/lxc_install.sh
    bash /tmp/lxc_install.sh
    rm -f /tmp/lxc_install.sh
  "

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
