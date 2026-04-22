#!/usr/bin/env bash
# =============================================================================
#  Family Hub - Proxmox VE LXC installer
# =============================================================================
#  Creates an unprivileged LXC container on a Proxmox VE 8/9 host, installs
#  Docker + compose inside, clones the Family Hub repo and brings the stack
#  up. Tested on Proxmox VE 9.1 (Debian 13 trixie base).
#
#  One-liner usage (run as root on the Proxmox host):
#
#    bash -c "$(wget -qLO - https://github.com/Reece-OG/Family-Hub-LXC/raw/main/install.sh)"
#
#  Skip the wizard with sensible defaults:
#
#    bash -c "$(wget -qLO - https://github.com/Reece-OG/Family-Hub-LXC/raw/main/install.sh)" -- --default
#
#  ---------------------------------------------------------------------------
#  Private Family Hub repo?
#  ---------------------------------------------------------------------------
#  If the repo at FH_REPO is private, you must pick one of these auth modes:
#
#    1. Personal Access Token (PAT) - easiest.
#       Create a fine-grained PAT at
#         https://github.com/settings/personal-access-tokens/new
#       Resource owner: Reece-OG   Repos: only "Family-Hub"
#       Permissions:    "Contents: Read-only"
#       Expiry:         whatever you like (the installer stores it inside
#                       the LXC so future `git pull`s keep working).
#       Then run with:  FH_AUTH=pat FH_TOKEN=github_pat_xxx ... --default
#       Or pick "PAT" in the wizard and paste the token when prompted.
#
#    2. SSH deploy key - generated automatically inside the LXC.
#       The installer pauses, prints a public key, and you paste it into
#         Settings -> Deploy keys on the repo (leave "Allow write" unticked),
#       then press Enter to continue.
#       Run with:  FH_AUTH=ssh ... --default   (or pick "SSH" in the wizard).
#
#    3. public - repo is public, no auth needed (default).
#
#  ---------------------------------------------------------------------------
#  Install method: Docker vs Native
#  ---------------------------------------------------------------------------
#    FH_METHOD=docker  (default) - installs Docker + compose, runs the app in
#                      containers. Mirrors the `docker compose up -d` dev flow.
#    FH_METHOD=native  - installs Node 20 + PostgreSQL 16 directly on Debian,
#                      builds the app from source, runs it under systemd.
#                      Lower RAM, no `nesting`/`keyctl` LXC features required,
#                      native pg_dump for backups. Recommended for an LXC.
#
#  Any of these env vars pre-seed the wizard / defaults:
#    CTID HOSTNAME CORES MEMORY DISK_GB STORAGE BRIDGE NET TIMEZONE
#    FH_REPO FH_BRANCH FH_AUTH FH_TOKEN FH_METHOD APP_NAME
# =============================================================================
set -euo pipefail

# ---------- output helpers -----------------------------------------------------
RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[0;33m'; BLU=$'\033[0;34m'
BLD=$'\033[1m';    RST=$'\033[0m'
msg()  { echo "${BLU}==>${RST} ${BLD}$*${RST}"; }
ok()   { echo "${GRN}  [ok]${RST} $*"; }
warn() { echo "${YLW}  [!]${RST}  $*"; }
die()  { echo "${RED}[x] $*${RST}" >&2; exit 1; }

header() {
  clear
  cat <<'BANNER'
  ______                _ _         _   _       _
 |  ____|              (_) |       | | | |     | |
 | |__ __ _ _ __ ___   _| |_   _   | |_| |_   _| |__
 |  __/ _` | '_ ` _ \ | | | | | |  |  _  | | | | '_ \
 | | | (_| | | | | | || | | |_| |  | | | | |_| | |_) |
 |_|  \__,_|_| |_| |_||_|_|\__, |  \_| |_/\__,_|_.__/
                            __/ |
  Proxmox VE LXC installer |___/     github.com/Reece-OG

BANNER
}

# ---------- pre-flight ---------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run as root on the Proxmox host."
command -v pct        >/dev/null 2>&1 || die "pct not found - must run on a Proxmox VE host."
command -v pveversion >/dev/null 2>&1 || die "pveversion not found - is this a Proxmox host?"
command -v pvesm      >/dev/null 2>&1 || die "pvesm not found."
command -v pveam      >/dev/null 2>&1 || die "pveam not found."

if ! command -v whiptail >/dev/null 2>&1; then
  msg "Installing whiptail..."
  apt-get update -qq >/dev/null
  apt-get install -y whiptail >/dev/null || die "Could not install whiptail."
fi

PVE_VER="$(pveversion -v | head -1 | awk '{print $2}' | cut -d'/' -f2)"
header
msg "Detected Proxmox VE ${PVE_VER}"

# ---------- defaults -----------------------------------------------------------
NEXT_CTID="$(pvesh get /cluster/nextid)"
DEFAULT_CTID="${CTID:-$NEXT_CTID}"
DEFAULT_HOSTNAME="${HOSTNAME:-familyhub}"
# Default disk is 32 GB to leave headroom for the photos gallery, menu
# images, recipes, and the Postgres dump dir. Override with DISK_GB env var
# if you really want smaller/larger.
DEFAULT_DISK_GB="${DISK_GB:-32}"
DEFAULT_CORES="${CORES:-2}"
DEFAULT_MEMORY="${MEMORY:-2048}"
DEFAULT_STORAGE="${STORAGE:-local-lvm}"
DEFAULT_BRIDGE="${BRIDGE:-vmbr0}"
DEFAULT_NET="${NET:-dhcp}"
# Blank DNS means "inherit /etc/resolv.conf from the Proxmox host", which is
# usually what you want. Set DNS to a space-separated list (e.g. "1.1.1.1
# 8.8.8.8") only if you want to override the host's resolvers.
DEFAULT_DNS="${DNS:-}"
DEFAULT_TIMEZONE="${TIMEZONE:-$(cat /etc/timezone 2>/dev/null || echo 'UTC')}"
# Optional root password inside the container. Leave blank to skip (you can
# still enter the CT via `pct enter <CTID>` from the Proxmox host).
DEFAULT_CT_PASSWORD="${CT_PASSWORD:-}"
# Git details are intentionally NOT exposed in the wizard — everyone should
# be pulling from the canonical repo/branch. They remain overridable via
# env vars for advanced use (e.g. pointing at a fork during dev).
DEFAULT_FH_REPO="${FH_REPO:-https://github.com/Reece-OG/Family-Hub.git}"
DEFAULT_FH_BRANCH="${FH_BRANCH:-main}"
DEFAULT_FH_AUTH="${FH_AUTH:-public}"
DEFAULT_FH_METHOD="${FH_METHOD:-docker}"
DEFAULT_APP_NAME="${APP_NAME:-}"

# ---------- wizard / defaults --------------------------------------------------
MODE="wizard"
if [[ "${1:-}" == "--default" ]] || [[ -n "${SKIP_WIZARD:-}" ]]; then
  MODE="default"
fi

if [[ "$MODE" == "default" ]]; then
  CTID="$DEFAULT_CTID"
  HOSTNAME="$DEFAULT_HOSTNAME"
  DISK_GB="$DEFAULT_DISK_GB"
  CORES="$DEFAULT_CORES"
  MEMORY="$DEFAULT_MEMORY"
  STORAGE="$DEFAULT_STORAGE"
  BRIDGE="$DEFAULT_BRIDGE"
  NET="$DEFAULT_NET"
  DNS="$DEFAULT_DNS"
  TIMEZONE="$DEFAULT_TIMEZONE"
  CT_PASSWORD="$DEFAULT_CT_PASSWORD"
  FH_REPO="$DEFAULT_FH_REPO"
  FH_BRANCH="$DEFAULT_FH_BRANCH"
  FH_AUTH="$DEFAULT_FH_AUTH"
  FH_METHOD="$DEFAULT_FH_METHOD"
  APP_NAME="$DEFAULT_APP_NAME"

  # PAT auth in default mode must have a token.
  if [[ "$FH_AUTH" == "pat" ]] && [[ -z "${FH_TOKEN:-}" ]]; then
    die "FH_AUTH=pat requires FH_TOKEN=<github_pat_...> in the environment."
  fi
  case "$FH_METHOD" in docker|native) ;; *) die "FH_METHOD must be 'docker' or 'native' (got: ${FH_METHOD}).";; esac
  ok "Running with defaults (CTID=${CTID}, host=${HOSTNAME}, method=${FH_METHOD}, auth=${FH_AUTH})."
else
  whiptail --title "Family Hub LXC installer" --msgbox \
    "This will create an unprivileged LXC on this Proxmox host,\nbuild the Family Hub stack, and bring it up.\n\nYou'll be asked a handful of questions - sensible defaults are pre-filled." 12 72

  FH_METHOD=$(whiptail --title "Install method" --menu \
"How should Family Hub run inside the LXC?

  - docker: install Docker + docker compose, run the official compose stack.
            Matches the upstream dev flow. Needs nesting=1 + keyctl=1.

  - native: install Node 20 + PostgreSQL 16 directly, run via systemd.
            Lower RAM, simpler backups, plain unprivileged LXC.
            Recommended for an LXC." 20 78 2 \
    "docker" "Docker compose (mirrors upstream)" \
    "native" "Native systemd service (recommended for LXC)" \
    3>&1 1>&2 2>&3) || exit 1

  CTID=$(whiptail --title "Container ID" --inputbox "Pick a container ID:" 8 60 "$DEFAULT_CTID" 3>&1 1>&2 2>&3) || exit 1

  # Ask for the branded app name up-front so the default hostname can be derived
  # from it (lowercased, spaces stripped). Users can still override the
  # hostname in the next prompt if they want something different.
  APP_NAME=$(whiptail --title "App name" --inputbox \
"Optional: custom app name shown in the nav, login, browser tab and PDFs.
Leave blank to use \"Family Hub\". Examples: ReeceHub, SimpsonHub, HomeBase.

The container hostname will default to this name lowercased with spaces
removed — you can still override it on the next screen." \
    13 72 "$DEFAULT_APP_NAME" 3>&1 1>&2 2>&3) || APP_NAME=""

  if [[ -n "$APP_NAME" ]]; then
    DERIVED_HOSTNAME="$(echo "$APP_NAME" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    HOSTNAME_DEFAULT="${DERIVED_HOSTNAME:-$DEFAULT_HOSTNAME}"
  else
    HOSTNAME_DEFAULT="$DEFAULT_HOSTNAME"
  fi

  HOSTNAME=$(whiptail --title "Hostname" --inputbox "Hostname for the container:" 8 60 "$HOSTNAME_DEFAULT" 3>&1 1>&2 2>&3) || exit 1
  CORES=$(whiptail --title "CPU cores" --inputbox "CPU cores:" 8 60 "$DEFAULT_CORES" 3>&1 1>&2 2>&3) || exit 1
  MEMORY=$(whiptail --title "Memory" --inputbox "Memory (MiB):" 8 60 "$DEFAULT_MEMORY" 3>&1 1>&2 2>&3) || exit 1
  DISK_GB=$(whiptail --title "Disk" --inputbox "Root disk size (GB):" 8 60 "$DEFAULT_DISK_GB" 3>&1 1>&2 2>&3) || exit 1

  # Storage picker - all rootdir-capable storages
  STORAGE_OPTS=()
  while read -r line; do
    name="$(echo "$line" | awk '{print $1}')"
    [[ -n "$name" ]] && STORAGE_OPTS+=("$name" "")
  done < <(pvesm status -content rootdir 2>/dev/null | tail -n +2)
  [[ ${#STORAGE_OPTS[@]} -eq 0 ]] && STORAGE_OPTS=("$DEFAULT_STORAGE" "(default)")
  STORAGE=$(whiptail --title "Storage" --menu "Pick storage for the CT root disk:" 15 60 6 "${STORAGE_OPTS[@]}" 3>&1 1>&2 2>&3) || exit 1

  BRIDGE=$(whiptail --title "Network bridge" --inputbox "Linux bridge to attach the CT to:" 8 60 "$DEFAULT_BRIDGE" 3>&1 1>&2 2>&3) || exit 1

  NET_CHOICE=$(whiptail --title "Network mode" --menu "How should networking be configured?" 12 60 2 \
    "dhcp"   "DHCP (recommended)" \
    "static" "Static IP" \
    3>&1 1>&2 2>&3) || exit 1
  if [[ "$NET_CHOICE" == "static" ]]; then
    STATIC_IP=$(whiptail --title "Static IP" --inputbox \
      "IP address with CIDR, e.g.\n  192.168.1.50/24" 10 70 "" 3>&1 1>&2 2>&3) || exit 1
    [[ -n "$STATIC_IP" ]] || die "IP was empty."
    STATIC_GW=$(whiptail --title "Gateway" --inputbox \
      "Default gateway for this container, e.g.\n  192.168.1.1" 10 70 "" 3>&1 1>&2 2>&3) || exit 1
    [[ -n "$STATIC_GW" ]] || die "Gateway was empty."
    NET="${STATIC_IP},gw=${STATIC_GW}"
  else
    NET="dhcp"
  fi

  # DNS is optional. Blank = inherit the Proxmox host's /etc/resolv.conf,
  # which is the right default for most home setups (your router / Pi-hole
  # / whatever the host already uses will be used inside the CT too).
  # Override here only if you want the CT to use different resolvers than
  # the host.
  DNS_HELP="Optional: space-separated DNS server IPs, e.g.
  1.1.1.1 8.8.8.8

Leave blank to inherit the Proxmox host's DNS settings
(recommended — the CT will use the same resolvers as the host)."
  DNS=$(whiptail --title "DNS servers (optional)" --inputbox "$DNS_HELP" 14 72 "$DEFAULT_DNS" 3>&1 1>&2 2>&3) || DNS=""

  TIMEZONE=$(whiptail --title "Timezone" --inputbox "Timezone (tz database name):" 8 60 "$DEFAULT_TIMEZONE" 3>&1 1>&2 2>&3) || exit 1

  # Optional root password. If set, you can log into the CT at the Proxmox
  # console or via SSH. If blank, `pct enter <CTID>` from the host is the
  # only shell route — which is fine for most users.
  CT_PASSWORD=$(whiptail --title "Root password (optional)" --passwordbox \
"Optional: set a root password for the container so you can log in at
the Proxmox console or via SSH.

Leave blank to skip — you can still enter the CT any time with
    pct enter ${CTID}
from the Proxmox host." 14 72 "" 3>&1 1>&2 2>&3) || CT_PASSWORD=""

  if [[ -n "$CT_PASSWORD" ]]; then
    CT_PASSWORD_CONFIRM=$(whiptail --title "Confirm root password" --passwordbox \
      "Re-enter the root password:" 8 60 "" 3>&1 1>&2 2>&3) || exit 1
    if [[ "$CT_PASSWORD" != "$CT_PASSWORD_CONFIRM" ]]; then
      die "Passwords did not match — please run the installer again."
    fi
    unset CT_PASSWORD_CONFIRM
  fi

  # Repo / branch are intentionally not asked here — they always point at the
  # canonical Family Hub repo. Advanced users can still override via env vars
  # (FH_REPO=… FH_BRANCH=… bash install.sh). The only repo-related question
  # we ask is the auth mode, because that depends on whether the user has
  # their own private fork.
  FH_REPO="$DEFAULT_FH_REPO"
  FH_BRANCH="$DEFAULT_FH_BRANCH"

  FH_AUTH=$(whiptail --title "Repo access" --menu "Is the repo private? How should the LXC authenticate?" 14 72 3 \
    "public" "Repo is public - no auth needed (default)" \
    "pat"    "Private - use a GitHub Personal Access Token" \
    "ssh"    "Private - generate a deploy key in the LXC" \
    3>&1 1>&2 2>&3) || exit 1

  if [[ "$FH_AUTH" == "pat" ]]; then
    FH_TOKEN=$(whiptail --title "GitHub PAT" --passwordbox \
"Paste a fine-grained PAT with 'Contents: Read-only' on this repo:

Create one at:
 https://github.com/settings/personal-access-tokens/new

The token will only be stored inside the new LXC (mode 600)." 15 72 "" 3>&1 1>&2 2>&3) || exit 1
    [[ -n "$FH_TOKEN" ]] || die "PAT was empty."
    # Lightweight sanity check - GitHub PATs start with ghp_ or github_pat_.
    case "$FH_TOKEN" in
      ghp_*|github_pat_*|gho_*|ghu_*|ghs_*) : ;;
      *) warn "Token doesn't look like a standard GitHub PAT - continuing anyway." ;;
    esac
  fi

  whiptail --title "Confirm" --yesno \
"Ready to create CT ${CTID} (${HOSTNAME}).

  Method    : ${FH_METHOD}
  Cores     : ${CORES}
  Memory    : ${MEMORY} MiB
  Disk      : ${DISK_GB} GB on ${STORAGE}
  Bridge    : ${BRIDGE}
  Network   : ${NET}
  DNS       : ${DNS:-<inherit from host>}
  Timezone  : ${TIMEZONE}
  Root pwd  : $([[ -n "$CT_PASSWORD" ]] && echo "set" || echo "not set (use pct enter)")
  Repo auth : ${FH_AUTH}
  App name  : ${APP_NAME:-Family Hub}

Proceed?" 24 72 || { warn "Aborted by user."; exit 1; }
fi

# ---------- sanity: CTID not in use -------------------------------------------
if pct status "$CTID" >/dev/null 2>&1; then
  die "CT ${CTID} already exists. Pick a different ID or destroy the existing one first."
fi

# ---------- template -----------------------------------------------------------
msg "Refreshing template catalogue..."
pveam update >/dev/null

TEMPLATE=""
for PREFIX in debian-13-standard debian-12-standard; do
  cand="$(pveam available -section system 2>/dev/null | awk -v p="$PREFIX" '$2 ~ p {print $2}' | sort -V | tail -1)"
  if [[ -n "$cand" ]]; then
    TEMPLATE="$cand"
    break
  fi
done
[[ -n "$TEMPLATE" ]] || die "No Debian 12 or 13 template available from pveam."

TEMPLATE_STORE=""
for store in local; do
  if pvesm status -content vztmpl 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$store"; then
    TEMPLATE_STORE="$store"
    break
  fi
done
if [[ -z "$TEMPLATE_STORE" ]]; then
  TEMPLATE_STORE="$(pvesm status -content vztmpl 2>/dev/null | awk 'NR==2{print $1}')"
fi
[[ -n "$TEMPLATE_STORE" ]] || die "No storage with vztmpl content found."

if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE"; then
  msg "Downloading template ${TEMPLATE} to ${TEMPLATE_STORE}..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE" >/dev/null
fi
TEMPLATE_PATH="${TEMPLATE_STORE}:vztmpl/${TEMPLATE}"
ok "Template: ${TEMPLATE_PATH}"

# ---------- create container ---------------------------------------------------
NET0="name=eth0,bridge=${BRIDGE}"
if [[ "$NET" == "dhcp" ]]; then
  NET0="${NET0},ip=dhcp"
else
  NET0="${NET0},ip=${NET}"
fi

# Modern Debian (13+) ships systemd 257, which won't cleanly bring up networkd
# in an unprivileged CT without `nesting=1` — without it the CT never gets DNS
# and the installer stalls at "Waiting for DNS inside CT". Docker-in-LXC needs
# both nesting + keyctl; the native install only strictly needs nesting, but
# keyctl is cheap and matches Proxmox's modern-CT defaults, so we turn both on.
CT_FEATURES="nesting=1,keyctl=1"

msg "Creating LXC ${CTID} (${HOSTNAME}, method=${FH_METHOD})..."
CREATE_ARGS=(
  --hostname "$HOSTNAME"
  --cores "$CORES"
  --memory "$MEMORY"
  --swap "$MEMORY"
  --rootfs "${STORAGE}:${DISK_GB}"
  --net0 "$NET0"
  --features "$CT_FEATURES"
  --unprivileged 1
  --onboot 1
  --timezone "$TIMEZONE"
  --ostype debian
  --description "Family Hub - self-hosted family dashboard (github.com/Reece-OG/Family-Hub) [${FH_METHOD}]"
)
# `pct create --nameserver` takes a single space-separated string. Only pass
# it when the user actually supplied values, so a blank field still falls
# back to inheriting the Proxmox host's resolv.conf.
if [[ -n "${DNS:-}" ]]; then
  CREATE_ARGS+=(--nameserver "$DNS")
fi
pct create "$CTID" "$TEMPLATE_PATH" "${CREATE_ARGS[@]}" >/dev/null
ok "Container ${CTID} created."

# ---------- start + wait for network ------------------------------------------
msg "Starting container..."
pct start "$CTID"

msg "Waiting for DNS inside CT..."
for i in {1..45}; do
  if pct exec "$CTID" -- bash -c "getent hosts github.com" >/dev/null 2>&1; then
    ok "Network ready."
    break
  fi
  sleep 2
  [[ $i -eq 45 ]] && die "CT never got working DNS - check bridge / network config."
done

# ---------- set root password (if supplied) -----------------------------------
# Using `chpasswd` with the password piped on stdin keeps it off the process
# table (printf is a bash builtin; `pct exec ... -- chpasswd` only sees the
# command name). The password is cleared from the shell immediately after.
if [[ -n "${CT_PASSWORD:-}" ]]; then
  msg "Setting root password inside CT..."
  printf 'root:%s\n' "$CT_PASSWORD" | pct exec "$CTID" -- chpasswd
  unset CT_PASSWORD
  ok "Root password set."
fi

# ---------- inject SSH deploy key flow (if chosen) ----------------------------
if [[ "$FH_AUTH" == "ssh" ]]; then
  msg "Generating ed25519 deploy key inside CT..."
  pct exec "$CTID" -- bash -c "
    set -e
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    if [[ ! -f /root/.ssh/id_ed25519 ]]; then
      ssh-keygen -t ed25519 -N '' -C 'family-hub-lxc@$(hostname -s)' -f /root/.ssh/id_ed25519 >/dev/null
    fi
    ssh-keyscan -H github.com >> /root/.ssh/known_hosts 2>/dev/null
    sort -u /root/.ssh/known_hosts -o /root/.ssh/known_hosts
  "
  PUBKEY="$(pct exec "$CTID" -- cat /root/.ssh/id_ed25519.pub)"

  # Derive the Settings -> Deploy keys URL from the repo URL if it's a GitHub URL.
  DEPLOY_URL="$FH_REPO"
  if [[ "$FH_REPO" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
    DEPLOY_URL="https://github.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/settings/keys"
  fi

  echo
  echo "${YLW}${BLD}-- SSH DEPLOY KEY --${RST}"
  echo "Add this public key to the Family Hub repo as a DEPLOY KEY"
  echo "(leave 'Allow write access' UNTICKED):"
  echo
  echo "  ${DEPLOY_URL}"
  echo
  echo "${BLD}${PUBKEY}${RST}"
  echo
  read -rp "Press Enter once you've added the key and saved it..."

  # Switch FH_REPO to SSH form if it's a github.com URL.
  if [[ "$FH_REPO" =~ github\.com[:/]([^/]+)/([^/]+)$ ]]; then
    FH_REPO="git@github.com:${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    [[ "$FH_REPO" == *.git ]] || FH_REPO="${FH_REPO}.git"
  fi
fi

# ---------- push setup.sh ------------------------------------------------------
msg "Preparing in-container setup (method=${FH_METHOD})..."
TMP_SETUP="$(mktemp)"

# Name of the setup script to fetch matches the chosen method.
SETUP_NAME="setup-${FH_METHOD}.sh"

SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [[ -n "$SCRIPT_DIR" ]] && [[ -f "$SCRIPT_DIR/$SETUP_NAME" ]]; then
  cp "$SCRIPT_DIR/$SETUP_NAME" "$TMP_SETUP"
  ok "Using local ${SETUP_NAME} from ${SCRIPT_DIR}."
else
  if ! wget -qLO "$TMP_SETUP" "https://github.com/Reece-OG/Family-Hub-LXC/raw/main/${SETUP_NAME}"; then
    die "Could not download ${SETUP_NAME} from GitHub. Check network / repo visibility."
  fi
  ok "Downloaded ${SETUP_NAME} from GitHub."
fi

pct push "$CTID" "$TMP_SETUP" /root/setup.sh
rm -f "$TMP_SETUP"
pct exec "$CTID" -- chmod +x /root/setup.sh

# The PAT must never appear on a command line that ps/auditd can see.
# Write it to a file inside the CT with mode 600, then pass the path via env.
if [[ "$FH_AUTH" == "pat" ]]; then
  msg "Seeding PAT into CT (mode 600)..."
  TMP_TOKEN="$(mktemp)"
  printf '%s' "$FH_TOKEN" > "$TMP_TOKEN"
  pct push "$CTID" "$TMP_TOKEN" /root/.fh-token
  shred -u "$TMP_TOKEN" 2>/dev/null || rm -f "$TMP_TOKEN"
  pct exec "$CTID" -- chmod 600 /root/.fh-token
fi

if [[ "$FH_METHOD" == "docker" ]]; then
  msg "Running in-container setup (Docker install + first build, ~5 min)..."
else
  msg "Running in-container setup (Node + Postgres + build, ~6 min)..."
fi
pct exec "$CTID" -- env \
  FH_REPO="$FH_REPO" \
  FH_BRANCH="$FH_BRANCH" \
  FH_AUTH="$FH_AUTH" \
  TIMEZONE="$TIMEZONE" \
  APP_NAME="$APP_NAME" \
  bash /root/setup.sh

# ---------- summary ------------------------------------------------------------
IP_LINE="$(pct exec "$CTID" -- ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
PORT="3000"
echo
echo "${GRN}${BLD}================================================================${RST}"
echo "${GRN}${BLD}  Family Hub is up.${RST}"
echo
echo "  Open:            ${BLD}http://${IP_LINE:-<ct-ip>}:${PORT}${RST}"
echo "  Bootstrap login: parent@example.com / changeme  (change it in app)"
echo
echo "  Container:       CTID=${CTID}  host=${HOSTNAME}"
echo "  Install method:  ${FH_METHOD}"
echo "  Repo auth mode:  ${FH_AUTH}"
echo "  Shell in:        pct enter ${CTID}"
if [[ "$FH_METHOD" == "docker" ]]; then
  echo "  View web logs:   pct exec ${CTID} -- bash -c 'cd /opt/family-hub && docker compose logs -f web'"
else
  echo "  View web logs:   pct exec ${CTID} -- journalctl -u family-hub -f"
  echo "  Service status:  pct exec ${CTID} -- systemctl status family-hub"
fi
echo "  Update to HEAD:  pct exec ${CTID} -- /opt/family-hub/update.sh"
echo "  Destroy:         pct stop ${CTID} && pct destroy ${CTID} --purge"
echo "${GRN}${BLD}================================================================${RST}"
