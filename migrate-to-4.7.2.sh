#!/usr/bin/env bash
# =============================================================================
#  Family Hub — retrofit the v4.7.2 in-app update pipeline onto an existing
#  LXC install (v4.7.1 or earlier).
# =============================================================================
#
#  v4.7.2 added a parent-only "Check for updates / Update now" card in
#  Settings → System. It's implemented as a privilege-separated flow:
#
#     web app (unprivileged, uid 1001)
#         └── touches /var/lib/family-hub/state/{check,update}-requested
#                 └── systemd path unit fires on the LXC host
#                         └── runs /opt/family-hub/state-helper.sh as root
#                                 └── git fetch / update.sh
#                                 └── writes JSON status files the app polls
#
#  For *new* v4.7.2 installs the installer wires all of that up. Existing
#  v4.7.1 containers have the new app code (after `git pull` / `update`) but
#  are missing the host-side bits — state dir, state-helper.sh, and the six
#  systemd units. This script installs exactly those bits. It is idempotent;
#  you can re-run it any time.
#
#  Usage (run as root INSIDE the LXC — e.g. `pct exec <CTID> -- bash -c ...`):
#
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/Reece-OG/Family-Hub-LXC/main/migrate-to-4.7.2.sh)"
#
#  or, if you'd rather download then inspect first:
#
#    curl -fsSL https://raw.githubusercontent.com/Reece-OG/Family-Hub-LXC/main/migrate-to-4.7.2.sh -o /tmp/m.sh
#    less /tmp/m.sh
#    bash /tmp/m.sh
# =============================================================================
set -euo pipefail

# ---------- output helpers ---------------------------------------------------
RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[0;33m'; BLU=$'\033[0;34m'
BLD=$'\033[1m'; RST=$'\033[0m'
msg() { printf "${BLU}==>${RST} ${BLD}%s${RST}\n" "$*"; }
ok()  { printf "  ${GRN}[\xe2\x9c\x93]${RST} %s\n" "$*"; }
warn(){ printf "  ${YLW}[!]${RST} %s\n" "$*"; }
die() { printf "${RED}[x]${RST} %s\n" "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this as root (try: pct exec <CTID> -- bash migrate-to-4.7.2.sh)"

INSTALL_DIR=/opt/family-hub
STATE_DIR=/var/lib/family-hub/state
STATE_HELPER="${INSTALL_DIR}/state-helper.sh"
SERVICE_USER=familyhub
RAW_BASE="${FH_LXC_RAW_BASE:-https://raw.githubusercontent.com/Reece-OG/Family-Hub-LXC/main}"

[[ -d "$INSTALL_DIR/.git" ]] || die "$INSTALL_DIR is not a Family Hub install."

# ---------- detect install method --------------------------------------------
METHOD=
if systemctl list-unit-files family-hub.service >/dev/null 2>&1; then
  METHOD=native
elif [[ -f "$INSTALL_DIR/docker-compose.yml" ]] && command -v docker >/dev/null 2>&1; then
  METHOD=docker
else
  die "Couldn't detect install method (no family-hub.service, no docker-compose.yml)."
fi
msg "Detected ${BLD}${METHOD}${RST} install at $INSTALL_DIR"

# ---------- state dir --------------------------------------------------------
# Owner: familyhub (native) or uid 1001 via group (docker). The nextjs user
# inside the docker image is uid 1001. We chgrp to familyhub (which on Debian
# after useradd --system is also group familyhub, typically gid ~998) so the
# group bit lets the app write triggers. For docker we ALSO chown to 1001:1001
# so the container-side user can write directly without a gid match.
msg "Preparing $STATE_DIR..."
mkdir -p "$STATE_DIR"
if [[ "$METHOD" == "docker" ]]; then
  chown 1001:1001 "$STATE_DIR"
else
  # Tolerate a missing group — fresh 4.7.1 boxes should have it but don't die
  # if a bespoke setup renamed the service user.
  chgrp "$SERVICE_USER" "$STATE_DIR" 2>/dev/null || warn "group $SERVICE_USER missing; leaving root-owned"
fi
chmod 775 "$STATE_DIR"
ok "$STATE_DIR ready"

# ---------- fetch state-helper.sh --------------------------------------------
msg "Downloading state-helper.sh from $RAW_BASE..."
TMP_HELPER="$(mktemp)"
if ! curl -fsSL "$RAW_BASE/state-helper.sh" -o "$TMP_HELPER"; then
  rm -f "$TMP_HELPER"
  die "Could not download state-helper.sh — check the CT has internet access."
fi
# Cheap sanity check that we got the script and not an HTML error page.
head -1 "$TMP_HELPER" | grep -q '^#!.*bash' || {
  rm -f "$TMP_HELPER"
  die "Downloaded file doesn't look like a bash script."
}
install -o root -g root -m 755 "$TMP_HELPER" "$STATE_HELPER"
rm -f "$TMP_HELPER"
ok "$STATE_HELPER installed"

# ---------- systemd units ----------------------------------------------------
msg "Writing systemd units..."

cat > /etc/systemd/system/family-hub-check.path <<'UNIT'
[Unit]
Description=Watch for Family Hub update-check requests
Documentation=https://github.com/Reece-OG/Family-Hub

[Path]
PathChanged=/var/lib/family-hub/state/check-requested

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/family-hub-check.service <<UNIT
[Unit]
Description=Check Family Hub for available updates
Documentation=https://github.com/Reece-OG/Family-Hub
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${STATE_HELPER} check
TimeoutStartSec=120
UNIT

cat > /etc/systemd/system/family-hub-update.path <<'UNIT'
[Unit]
Description=Watch for Family Hub update requests
Documentation=https://github.com/Reece-OG/Family-Hub

[Path]
PathChanged=/var/lib/family-hub/state/update-requested

[Install]
WantedBy=multi-user.target
UNIT

# Update service — spec differs slightly between methods (docker needs
# docker.service; native needs nothing extra).
if [[ "$METHOD" == "docker" ]]; then
  cat > /etc/systemd/system/family-hub-update.service <<UNIT
[Unit]
Description=Apply Family Hub update (git pull + docker rebuild)
Documentation=https://github.com/Reece-OG/Family-Hub
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${STATE_HELPER} update
# docker compose build can take 3-5 minutes on a low-end CT. Give it 15.
TimeoutStartSec=15min
UNIT
else
  cat > /etc/systemd/system/family-hub-update.service <<UNIT
[Unit]
Description=Apply Family Hub update (git pull + rebuild + restart)
Documentation=https://github.com/Reece-OG/Family-Hub
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${STATE_HELPER} update
# npm install + next build can take ~3 min on a small CT. Give it 15.
TimeoutStartSec=15min
UNIT
fi

cat > /etc/systemd/system/family-hub-auto-check.timer <<'UNIT'
[Unit]
Description=Daily automatic Family Hub update check

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNIT

cat > /etc/systemd/system/family-hub-auto-check.service <<'UNIT'
[Unit]
Description=Fire the Family Hub update-check trigger

[Service]
Type=oneshot
ExecStart=/usr/bin/touch /var/lib/family-hub/state/check-requested
UNIT

ok "Units written"

# ---------- enable + start ---------------------------------------------------
msg "Reloading systemd and enabling units..."
systemctl daemon-reload
systemctl enable --now \
  family-hub-check.path \
  family-hub-update.path \
  family-hub-auto-check.timer >/dev/null
ok "Path units + daily timer enabled"

# ---------- docker: ensure compose has the bind mount ------------------------
# v4.7.2 docker-compose.yml mounts the state dir into the nextjs container.
# If the user pulled the new code but never restarted, the running container
# won't have the mount. `docker compose up -d` is a no-op when nothing
# changed and a graceful recreate otherwise.
if [[ "$METHOD" == "docker" ]]; then
  if grep -q '/var/lib/family-hub/state' "$INSTALL_DIR/docker-compose.yml"; then
    msg "Ensuring docker container has the state bind mount..."
    (cd "$INSTALL_DIR" && docker compose up -d) >/dev/null
    ok "Container up with state bind mount"
  else
    warn "docker-compose.yml doesn't mount $STATE_DIR — pull v4.7.2 app code first (cd $INSTALL_DIR && git pull && ./update.sh), then re-run this script."
  fi
fi

# ---------- prime version.json -----------------------------------------------
msg "Running initial version check to populate version.json..."
if "$STATE_HELPER" check >/dev/null 2>&1; then
  ok "version.json written"
else
  warn "Initial check failed — the UI will retry automatically. Inspect: journalctl -u family-hub-check -n 50"
fi

echo
printf "${GRN}${BLD}Migration complete.${RST}\n"
echo "  Open Family Hub in your browser, sign in as a parent, then"
echo "  go to Settings → System to see the new Updates card."
echo
echo "  Logs:    journalctl -u family-hub-update -n 50"
echo "           tail -f /var/log/family-hub-update.log"
echo "  Disable daily auto-check:  systemctl disable --now family-hub-auto-check.timer"
