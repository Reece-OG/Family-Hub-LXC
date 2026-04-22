#!/usr/bin/env bash
# =============================================================================
#  Family Hub - in-container NATIVE setup (no Docker)
# =============================================================================
#  Runs INSIDE the LXC created by install.sh when the user picks FH_METHOD=native.
#  Installs Node.js 20 + PostgreSQL 16 (PGDG) directly on Debian, builds the
#  Next.js app from source, and runs it under systemd as the `familyhub`
#  service user.
#
#  Expected environment (exported by install.sh):
#    FH_REPO     Git URL of the Family Hub repo
#    FH_BRANCH   Branch to check out
#    FH_AUTH     public | pat | ssh
#    TIMEZONE    tz database name
#    APP_NAME    (optional) baked into the client bundle at build time
#
#  Output style:
#    Each long-running action is wrapped in `step "Label" cmd args...`. Full
#    command output is appended to $LOG_FILE; the terminal only shows a green
#    tick on success or a red cross on failure (plus the log tail on failure).
#    So the screen stays a clean checklist, but the raw log is still there
#    for post-mortem.
# =============================================================================
set -euo pipefail

FH_REPO="${FH_REPO:-https://github.com/Reece-OG/Family-Hub.git}"
FH_BRANCH="${FH_BRANCH:-main}"
FH_AUTH="${FH_AUTH:-public}"
TIMEZONE="${TIMEZONE:-UTC}"
APP_NAME="${APP_NAME:-}"

INSTALL_DIR="/opt/family-hub"
WEB_DIR="${INSTALL_DIR}/web"
SERVICE_USER="familyhub"
TOKEN_FILE="/root/.fh-token"
SYSTEMD_UNIT="/etc/systemd/system/family-hub.service"
LOG_FILE="/var/log/family-hub-install.log"
STATE_DIR="/var/lib/family-hub/state"
STATE_HELPER_SRC="/root/state-helper.sh"
STATE_HELPER="${INSTALL_DIR}/state-helper.sh"

# ---------- output helpers -----------------------------------------------------
RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[0;33m'; BLU=$'\033[0;34m'
DIM=$'\033[2m';    BLD=$'\033[1m';    RST=$'\033[0m'

# Section header. Blank line + bold blue arrow.
section() { printf "\n${BLU}==>${RST} ${BLD}%s${RST}\n" "$*"; }
note()    { printf "  ${DIM}%s${RST}\n" "$*"; }
warn()    { printf "  ${YLW}[!]${RST}  %s\n" "$*"; }
die()     { printf "${RED}[x]${RST} %s\n" "$*" >&2; exit 1; }

# Run a command silently and show a single-line pass/fail indicator.
#   step "Label" cmd arg1 arg2 ...
# On failure, prints the tail of the log file and exits with the command's
# exit code — so `set -e` still applies to the script as a whole.
step() {
  local label="$1"; shift
  printf "  [ ] %s..." "$label"
  if "$@" >>"$LOG_FILE" 2>&1; then
    # \r + spaces at end to scrub any leftover "...", keeps the line clean
    # even when a previous render was longer than the new one.
    printf "\r  ${GRN}[\xe2\x9c\x93]${RST} %s        \n" "$label"
    return 0
  else
    local rc=$?
    printf "\r  ${RED}[\xe2\x9c\x97]${RST} %s        \n" "$label"
    echo
    echo "${RED}---- Last 40 lines of ${LOG_FILE} ----${RST}"
    tail -40 "$LOG_FILE" || true
    echo "${RED}---- end of log (full log: ${LOG_FILE}) ----${RST}"
    exit "$rc"
  fi
}

[[ $EUID -eq 0 ]] || die "setup-native.sh must run as root inside the container."

# Fresh log each run. The header line gives the reader a grep anchor.
: >"$LOG_FILE"
echo "=== Family Hub install log - $(date -Is) ===" >>"$LOG_FILE"

# ---------- step implementations ----------------------------------------------
# Each helper is a thin wrapper so `step "Label" do_thing` reads cleanly above.
# Any output these produce goes to the log file, not the terminal.

export DEBIAN_FRONTEND=noninteractive

do_apt_update() {
  apt-get update -qq
}

do_install_base_tools() {
  # `sudo` isn't in the Debian 13 standard LXC template — we drop privs to
  # the postgres / familyhub service users throughout, and the generated
  # update.sh assumes `sudo -u familyhub ...` works, so pull it in here.
  apt-get install -y --no-install-recommends \
    sudo ca-certificates curl git openssh-client openssl tzdata gnupg lsb-release \
    build-essential python3 pkg-config libssl-dev
}

do_set_timezone() {
  [[ -z "$TIMEZONE" ]] && return 0
  echo "$TIMEZONE" > /etc/timezone
  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true
}

do_install_node() {
  if command -v node >/dev/null 2>&1 && node -v 2>/dev/null | grep -q '^v20\.'; then
    echo "Node.js $(node -v) already installed, skipping NodeSource repo."
    return 0
  fi
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y --no-install-recommends nodejs
}

do_install_postgres() {
  if command -v psql >/dev/null 2>&1; then
    echo "PostgreSQL already installed, skipping PGDG repo."
    return 0
  fi
  install -d /usr/share/keyrings
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg
  CODENAME="$(lsb_release -cs)"
  echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt ${CODENAME}-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list
  apt-get update -qq
  apt-get install -y --no-install-recommends postgresql-16
}

do_start_postgres() {
  systemctl enable postgresql >/dev/null 2>&1 || true
  systemctl start  postgresql >/dev/null 2>&1 || true
  # Wait for PG to accept local connections. pg_isready has a dedicated
  # exit-code contract for exactly this probe.
  for i in {1..30}; do
    if pg_isready -q -h /var/run/postgresql -U postgres >/dev/null 2>&1; then
      echo "PostgreSQL ready after ${i}s."
      return 0
    fi
    sleep 1
  done
  echo "PostgreSQL didn't become ready within 30s." >&2
  return 1
}

do_git_auth() {
  case "$FH_AUTH" in
    public)
      echo "Public repo — no credentials needed."
      ;;
    pat)
      [[ -s "$TOKEN_FILE" ]] || { echo "FH_AUTH=pat but $TOKEN_FILE missing/empty." >&2; return 1; }
      TOKEN="$(cat "$TOKEN_FILE")"
      git config --global credential.helper "store --file=/root/.git-credentials"
      umask 077
      echo "https://x-access-token:${TOKEN}@github.com" > /root/.git-credentials
      chmod 600 /root/.git-credentials
      unset TOKEN
      echo "PAT stored at /root/.git-credentials (mode 600)."
      ;;
    ssh)
      [[ -f /root/.ssh/id_ed25519 ]] || { echo "FH_AUTH=ssh but /root/.ssh/id_ed25519 missing." >&2; return 1; }
      mkdir -p /root/.ssh && chmod 700 /root/.ssh
      ssh-keyscan -H github.com >> /root/.ssh/known_hosts 2>/dev/null
      sort -u /root/.ssh/known_hosts -o /root/.ssh/known_hosts
      chmod 600 /root/.ssh/known_hosts /root/.ssh/id_ed25519
      echo "SSH key in place."
      ;;
    *)
      echo "Unknown FH_AUTH value: $FH_AUTH" >&2
      return 1
      ;;
  esac
}

do_clone_repo() {
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    git -C "$INSTALL_DIR" remote set-url origin "$FH_REPO"
    git -C "$INSTALL_DIR" fetch --all --prune
    git -C "$INSTALL_DIR" checkout "$FH_BRANCH"
    git -C "$INSTALL_DIR" pull --ff-only
    return 0
  fi
  rm -rf "$INSTALL_DIR"
  if ! git clone --branch "$FH_BRANCH" --depth 1 "$FH_REPO" "$INSTALL_DIR"; then
    case "$FH_AUTH" in
      pat) echo "Clone failed. Token wrong, expired, or missing Contents:Read." >&2 ;;
      ssh) echo "Clone failed. Did you add the deploy key to the repo?" >&2 ;;
      *)   echo "Clone failed. If the repo is private, re-run and pick 'pat' or 'ssh'." >&2 ;;
    esac
    return 1
  fi
}

do_create_service_user() {
  if id -u "$SERVICE_USER" >/dev/null 2>&1; then
    echo "Service user $SERVICE_USER already exists."
    return 0
  fi
  adduser --system --group --home "$INSTALL_DIR" \
    --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
}

do_create_db_and_env() {
  if [[ -f "$INSTALL_DIR/.env" ]]; then
    echo ".env already exists, preserving. DB password unchanged."
    return 0
  fi
  local pg_pw auth_secret
  pg_pw="$(openssl rand -hex 24)"
  auth_secret="$(openssl rand -base64 48 | tr -d '\n')"

  # Role + DB are idempotent so re-runs stay safe.
  sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='familyhub') THEN
    CREATE ROLE familyhub LOGIN PASSWORD '${pg_pw}';
  ELSE
    ALTER ROLE familyhub WITH LOGIN PASSWORD '${pg_pw}';
  END IF;
END
\$\$;
SQL
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='familyhub'" | grep -q 1; then
    sudo -u postgres createdb -O familyhub familyhub
  fi

  cat > "$INSTALL_DIR/.env" <<EOF
# Auto-generated by Family-Hub-LXC native installer on $(date -Is)

# --- Native-install DB (PostgreSQL 16, local) ---
POSTGRES_USER=familyhub
POSTGRES_PASSWORD=${pg_pw}
POSTGRES_DB=familyhub
DATABASE_URL=postgresql://familyhub:${pg_pw}@localhost:5432/familyhub

# --- Web app ---
WEB_PORT=3000
NODE_ENV=production
NEXT_TELEMETRY_DISABLED=1
AUTH_SECRET=${auth_secret}
UPLOADS_DIR=${WEB_DIR}/uploads

# Set to "true" ONLY when serving over HTTPS (e.g. behind Caddy / Nginx /
# Cloudflare). Leave blank on a plain-HTTP LAN deployment — otherwise the
# browser silently drops the session cookie and login will bounce back to
# the login screen.
COOKIE_SECURE=

# --- Bootstrap parent account (only used if no users exist) ---
# First login with these defaults triggers a one-time setup page where you
# replace them with your real email / name / password.
SEED_PARENT_EMAIL=parent@example.com
SEED_PARENT_PASSWORD=changeme
SEED_PARENT_NAME=Parent

# --- Branding (leave blank for "Family Hub") ---
APP_NAME=${APP_NAME}
NEXT_PUBLIC_APP_NAME=${APP_NAME}
EOF
  chmod 640 "$INSTALL_DIR/.env"
}

do_npm_install() {
  cd "$WEB_DIR"
  # --include=dev is load-bearing: we're about to source .env which exports
  # NODE_ENV=production, and with that set npm silently skips devDeps
  # (typescript, tailwindcss, postcss, prisma CLI, @types/*). The Next.js
  # build then fails with "Module not found: @/components/*" because
  # tsconfig `paths` can't be honoured without TypeScript present.
  npm install --no-audit --no-fund --include=dev
}

do_prisma_generate() {
  cd "$WEB_DIR"
  npx prisma generate
}

do_prisma_push() {
  cd "$WEB_DIR"
  npx prisma db push --skip-generate
}

do_next_build() {
  cd "$WEB_DIR"
  NEXT_TELEMETRY_DISABLED=1 npm run build
}

do_set_permissions() {
  install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 755 "${WEB_DIR}/uploads/photos"
  chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
  # .env stays root:familyhub — root can edit, service user can read.
  chown root:"$SERVICE_USER" "$INSTALL_DIR/.env"
  chmod 640 "$INSTALL_DIR/.env"
}

do_seed_user() {
  sudo -u "$SERVICE_USER" bash -lc "
    set -a
    . $INSTALL_DIR/.env
    set +a
    cd $WEB_DIR
    node prisma/seed.cjs
  "
}

do_write_systemd() {
  cat > "$SYSTEMD_UNIT" <<UNIT
[Unit]
Description=Family Hub (Next.js app)
Documentation=https://github.com/Reece-OG/Family-Hub
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${WEB_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
Environment=PORT=3000
Environment=HOSTNAME=0.0.0.0
# Mirror docker-entrypoint.sh: ensure schema is up to date before boot.
ExecStartPre=/usr/bin/npx --prefix ${WEB_DIR} prisma db push --skip-generate
ExecStart=/usr/bin/node ${WEB_DIR}/node_modules/next/dist/bin/next start -p 3000 -H 0.0.0.0
Restart=on-failure
RestartSec=5
# Hardening.
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${WEB_DIR}/uploads

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable family-hub >/dev/null
  systemctl restart family-hub
}

do_wait_for_service() {
  for i in {1..30}; do
    if curl -fsS "http://127.0.0.1:3000" >/dev/null 2>&1; then
      echo "Web app responded on :3000 after ${i} tries."
      return 0
    fi
    sleep 2
  done
  # Not fatal — service might still come up, but flag it so the operator
  # knows to check journalctl.
  echo "Web app didn't respond on :3000 within ~60s." >&2
  return 1
}

do_write_update_helper() {
  cat > "$INSTALL_DIR/update.sh" <<'UPDATE'
#!/usr/bin/env bash
# =============================================================================
#  Family Hub - in-place updater
# =============================================================================
#  Pulls the latest commit, rebuilds the Next.js app, applies any new Prisma
#  migrations, and restarts the systemd service. Uses the same step-based
#  checklist UX as the installer so the screen stays readable; all raw
#  output is appended to /var/log/family-hub-update.log for post-mortem.
#
#  Run as root:
#      update
#  or directly:
#      /opt/family-hub/update.sh
# =============================================================================
set -euo pipefail

INSTALL_DIR=/opt/family-hub
WEB_DIR=${INSTALL_DIR}/web
SERVICE_USER=familyhub
LOG_FILE=/var/log/family-hub-update.log

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[0;33m'; BLU=$'\033[0;34m'
DIM=$'\033[2m';    BLD=$'\033[1m';    RST=$'\033[0m'
section() { printf "\n${BLU}==>${RST} ${BLD}%s${RST}\n" "$*"; }
note()    { printf "  ${DIM}%s${RST}\n" "$*"; }
die()     { printf "${RED}[x]${RST} %s\n" "$*" >&2; exit 1; }

step() {
  local label="$1"; shift
  printf "  [ ] %s..." "$label"
  if "$@" >>"$LOG_FILE" 2>&1; then
    printf "\r  ${GRN}[\xe2\x9c\x93]${RST} %s        \n" "$label"
    return 0
  else
    local rc=$?
    printf "\r  ${RED}[\xe2\x9c\x97]${RST} %s        \n" "$label"
    echo
    echo "${RED}---- Last 40 lines of ${LOG_FILE} ----${RST}"
    tail -40 "$LOG_FILE" || true
    echo "${RED}---- end of log (full log: ${LOG_FILE}) ----${RST}"
    exit "$rc"
  fi
}

[[ $EUID -eq 0 ]] || die "update must run as root (try: sudo update)."
[[ -d "$INSTALL_DIR/.git" ]] || die "Install directory $INSTALL_DIR is not a git checkout."
[[ -f "$INSTALL_DIR/.env"   ]] || die "No .env at $INSTALL_DIR/.env — was the installer interrupted?"

: >"$LOG_FILE"
echo "=== Family Hub update log - $(date -Is) ===" >>"$LOG_FILE"

# Load the service's env so sudo -u familyhub inherits the right DATABASE_URL,
# APP_NAME, NEXT_PUBLIC_APP_NAME, etc. (rebuilds need all three.)
set -a
# shellcheck disable=SC1091
. "$INSTALL_DIR/.env"
set +a

do_git_pull()       { sudo -u "$SERVICE_USER" git -C "$INSTALL_DIR" pull --ff-only; }
do_npm_install()    { sudo -u "$SERVICE_USER" bash -lc "cd $WEB_DIR && npm install --no-audit --no-fund --include=dev"; }
do_prisma_gen()     { sudo -u "$SERVICE_USER" --preserve-env=DATABASE_URL,NODE_ENV bash -lc "cd $WEB_DIR && npx prisma generate >/dev/null"; }
do_prisma_push()    { sudo -u "$SERVICE_USER" --preserve-env=DATABASE_URL,NODE_ENV bash -lc "cd $WEB_DIR && npx prisma db push --skip-generate"; }
do_next_build()     { sudo -u "$SERVICE_USER" --preserve-env=DATABASE_URL,NODE_ENV,NEXT_TELEMETRY_DISABLED,NEXT_PUBLIC_APP_NAME,APP_NAME bash -lc "cd $WEB_DIR && NEXT_TELEMETRY_DISABLED=1 npm run build"; }
do_restart()        { systemctl restart family-hub; }
do_wait_up() {
  for i in {1..30}; do
    if curl -fsS "http://127.0.0.1:3000" >/dev/null 2>&1; then
      echo "Web app back up on :3000 after ${i} tries."
      return 0
    fi
    sleep 2
  done
  echo "Web app didn't respond on :3000 within ~60s." >&2
  return 1
}

section "Updating Family Hub"
step "Pulling latest commit"               do_git_pull
step "Installing npm deps"                 do_npm_install
step "Regenerating Prisma client"          do_prisma_gen
step "Applying Prisma schema"              do_prisma_push
step "Rebuilding Next.js (~3 min)"         do_next_build
step "Restarting service"                  do_restart
step "Waiting for web app on :3000"        do_wait_up

echo
printf "${GRN}${BLD}Family Hub updated.${RST}\n"
note "Update log: $LOG_FILE"
note "Status:     systemctl status family-hub"
UPDATE
  chmod +x "$INSTALL_DIR/update.sh"
}

# Install `/usr/local/bin/update` as a thin shim so root can just type
# `update` at the LXC prompt to pull + rebuild. Keeps the real logic in
# $INSTALL_DIR/update.sh (easy to edit, versions with the repo).
do_install_update_command() {
  cat > /usr/local/bin/update <<'SHIM'
#!/usr/bin/env bash
# Family Hub update shortcut — delegates to /opt/family-hub/update.sh.
# Lives in /usr/local/bin so logging into the LXC as root and typing
# `update` triggers an in-place pull + rebuild.
exec /opt/family-hub/update.sh "$@"
SHIM
  chmod 755 /usr/local/bin/update
}

do_install_update_system() {
  # The in-app "Check for updates / Update now" feature is a privilege-
  # separated pipeline:
  #   web app (familyhub)  --touch-->  trigger file in $STATE_DIR
  #   systemd path unit (root)         family-hub-{check,update}.path
  #     -> oneshot service (root)      family-hub-{check,update}.service
  #     -> state-helper.sh (root)      runs git fetch / update.sh,
  #                                    writes JSON status files the app reads
  # A daily timer also touches the trigger file so the UI stays fresh
  # without any user action.

  # 1. State directory, owned by familyhub:familyhub so the web app can
  #    create trigger files and read version.json / update-status.json.
  install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 775 "$STATE_DIR"

  # 2. Move the privileged helper into place.
  [[ -f "$STATE_HELPER_SRC" ]] || { echo "Missing $STATE_HELPER_SRC (install.sh should have pushed it)." >&2; return 1; }
  install -o root -g root -m 755 "$STATE_HELPER_SRC" "$STATE_HELPER"

  # 3. systemd path + service pair: check.
  cat > /etc/systemd/system/family-hub-check.path <<'UNIT'
[Unit]
Description=Watch for Family Hub update-check requests
Documentation=https://github.com/Reece-OG/Family-Hub

[Path]
# Any touch/create of this file fires the service below.
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
# If git fetch is slow, keep going — the helper writes an error.json we'll
# surface in the UI.
TimeoutStartSec=120
UNIT

  # 4. systemd path + service pair: update.
  cat > /etc/systemd/system/family-hub-update.path <<'UNIT'
[Unit]
Description=Watch for Family Hub update requests
Documentation=https://github.com/Reece-OG/Family-Hub

[Path]
PathChanged=/var/lib/family-hub/state/update-requested

[Install]
WantedBy=multi-user.target
UNIT

  cat > /etc/systemd/system/family-hub-update.service <<UNIT
[Unit]
Description=Apply Family Hub update (git pull + rebuild + restart)
Documentation=https://github.com/Reece-OG/Family-Hub
After=network-online.target family-hub.service postgresql.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${STATE_HELPER} update
# A rebuild can take 3-5 minutes on a low-end CT. Give it 15.
TimeoutStartSec=15min
UNIT

  # 5. Daily auto-check timer.
  cat > /etc/systemd/system/family-hub-auto-check.timer <<'UNIT'
[Unit]
Description=Daily automatic Family Hub update check

[Timer]
OnCalendar=daily
# Spread the load across a 1-hour window so every install doesn't hammer
# GitHub at midnight UTC.
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
# Deliberately uses /usr/bin/touch so this unit doesn't need to know where
# state-helper.sh lives — the path unit watching the trigger file picks up
# the rest.
ExecStart=/usr/bin/touch /var/lib/family-hub/state/check-requested
UNIT

  # Run check once now so the UI has a version.json to read from first boot.
  "$STATE_HELPER" check >/dev/null 2>&1 || true

  systemctl daemon-reload
  systemctl enable --now family-hub-check.path family-hub-update.path family-hub-auto-check.timer >/dev/null
}

do_cleanup_token() {
  [[ "$FH_AUTH" == "pat" && -f "$TOKEN_FILE" ]] || return 0
  shred -u "$TOKEN_FILE" 2>/dev/null || rm -f "$TOKEN_FILE"
}

do_unattended_upgrades() {
  apt-get install -y --no-install-recommends unattended-upgrades >/dev/null 2>&1 || true
  dpkg-reconfigure -f noninteractive -plow unattended-upgrades >/dev/null 2>&1 || true
}

# =============================================================================
#  Main pipeline
# =============================================================================

section "Preparing system"
step "Refreshing apt index"                  do_apt_update
step "Installing base tools"                 do_install_base_tools
step "Setting timezone (${TIMEZONE})"        do_set_timezone
step "Installing Node.js 20"                 do_install_node
step "Installing PostgreSQL 16"              do_install_postgres
step "Starting PostgreSQL + waiting"         do_start_postgres

section "Fetching Family Hub"
step "Configuring git auth (${FH_AUTH})"     do_git_auth
step "Cloning ${FH_REPO} (${FH_BRANCH})"     do_clone_repo
step "Creating service user (${SERVICE_USER})" do_create_service_user
step "Creating database + writing .env"      do_create_db_and_env

# ---------- build --------------------------------------------------------------
# Load env for the build (NEXT_PUBLIC_APP_NAME is inlined at build time).
set -a
# shellcheck disable=SC1091
. "$INSTALL_DIR/.env"
set +a

section "Building app"
step "Installing npm deps (~2 min)"          do_npm_install
step "Generating Prisma client"              do_prisma_generate
step "Applying Prisma schema to Postgres"    do_prisma_push
step "Building Next.js (~3 min)"             do_next_build

section "Finalising"
step "Setting ownership + uploads dir"       do_set_permissions
step "Seeding bootstrap parent (idempotent)" do_seed_user
step "Writing systemd unit + starting"       do_write_systemd
step "Waiting for web app on :3000"          do_wait_for_service
step "Writing update helper"                 do_write_update_helper
step "Installing 'update' shortcut"          do_install_update_command
step "Wiring in-app update flow + daily check" do_install_update_system
step "Cleaning up transient PAT file"        do_cleanup_token
step "Enabling unattended security updates"  do_unattended_upgrades

# ---------- summary ------------------------------------------------------------
echo
printf "${GRN}${BLD}Family Hub (native) install complete.${RST}\n"
note "Install log:   $LOG_FILE"
note "Service:       systemctl status family-hub"
note "Update helper: type 'update' as root (or run $INSTALL_DIR/update.sh)"
note "First login:   open http://<this-ct>:3000 → parent@example.com / changeme"
note "              → you'll be prompted to pick your own email / name / password."
