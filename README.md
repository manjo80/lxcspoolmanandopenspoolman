# spoolman-stack

One-command [Proxmox VE](https://www.proxmox.com/) LXC installer for
**[Spoolman](https://github.com/Donkie/Spoolman)** +
**[OpenSpoolMan](https://github.com/drndos/openspoolman)**.

Inspired by the [tteck Proxmox Helper Scripts](https://community-scripts.github.io/ProxmoxVE/).

---

## What it installs

| Service | Description |
|---------|-------------|
| **Spoolman** | Filament inventory & spool tracker |
| **OpenSpoolMan** | Bambu Lab NFC-spool bridge for Spoolman |
| **Nginx** | HTTPS reverse proxy with self-signed CA |
| **CA download** | HTTP endpoint to grab the root CA cert |

All services run as unprivileged system users under **systemd**, without Docker.

---

## Requirements

- Proxmox VE 7 or 8
- Internet access from the Proxmox host (template download) and from the container
- Bambu Lab printer on the local network (for OpenSpoolMan)

The Debian 12 LXC template is downloaded automatically if it is not already present.

---

## Installation

Run **on the Proxmox host** as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Manjo80/lxcspoolmanandopenspoolman/main/install.sh)"
```

The script will interactively ask for:

- Container ID, hostname, RAM, CPU cores, disk size, storage, bridge
- Static IP or DHCP
- Spoolman / OpenSpoolMan hostnames and ports
- Bambu printer IP, serial number, and LAN access code

---

## Ports

| Port | Service |
|------|---------|
| `7913` | Spoolman HTTPS (Nginx) |
| `7912` | Spoolman internal (uvicorn, localhost only) |
| `8443` | OpenSpoolMan HTTPS (Nginx) |
| `8000` | OpenSpoolMan internal (uvicorn, localhost only) |
| `8080` | CA certificate download (plain HTTP) |

All port defaults can be changed during installation.

---

## After installation

### 1. DNS

Add two entries to your local DNS resolver (e.g. Pi-hole, AdGuard Home, or router):

```
spoolman.home      →  <container-ip>
openspoolman.home  →  <container-ip>
```

### 2. Install the CA certificate

Download the root CA from:

```
http://<container-ip>:8080/spoolman-ca.crt
```

#### iPhone / iPad

1. Open the URL above in **Safari** (not Chrome).
2. **Settings → General → VPN & Device Management** → tap the profile → **Install**.
3. **Settings → General → About → Certificate Trust Settings** → enable full trust for *Spoolman-Stack-CA*.

#### Android

1. Download the `.crt` file.
2. **Settings → Security → Install from storage** (path varies by vendor).
3. Choose *CA certificate* when prompted.

#### macOS

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ~/Downloads/spoolman-ca.crt
```

#### Windows

1. Double-click `spoolman-ca.crt`.
2. **Install Certificate → Local Machine → Trusted Root Certification Authorities**.

---

## Troubleshooting

```bash
# Check service status inside the container
pct exec <CTID> -- systemctl status spoolman openspoolman nginx

# View live logs
pct exec <CTID> -- journalctl -fu spoolman
pct exec <CTID> -- journalctl -fu openspoolman

# Re-run only the container installer
pct exec <CTID> -- bash -c \
  "$(curl -fsSL https://raw.githubusercontent.com/Manjo80/spoolman-stack/main/scripts/lxc_install.sh)"

# Test Nginx config
pct exec <CTID> -- nginx -t
```

### Common issues

| Symptom | Likely cause |
|---------|--------------|
| Browser shows certificate warning | CA not trusted on this device yet |
| OpenSpoolMan can't reach Bambu printer | Wrong IP / serial / access code, or firewall |
| `502 Bad Gateway` | Service not running — check `journalctl` |
| Template download fails | Run `pveam update` manually on the host |

---

## Project links

- [Spoolman](https://github.com/Donkie/Spoolman)
- [OpenSpoolMan](https://github.com/drndos/openspoolman)
- [Proxmox VE Helper Scripts](https://community-scripts.github.io/ProxmoxVE/) (inspiration)
