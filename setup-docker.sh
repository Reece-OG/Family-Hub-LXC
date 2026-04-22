#!/usr/bin/env bash
# =============================================================================
#  Family Hub - in-container setup
# =============================================================================
#  Runs INSIDE the LXC created by install.sh. Installs Docker + compose, clones
#  the Family Hub repo (public or private), generates a .env with random
#  secrets, and brings the stack up with `docker compose up -d --build`.
#
#  Expected environment (exported by install.sh via `pct exec ... env ...`):
#    FH_REPO     Git URL of the Family Hub repo
#    FH_BRANCH   Branch to check out
#    FH_AUTH     public | pat | ssh
#    TIMEZONE    tz database name (e.g. Australia/Sydney)
#
#  When FH_AUTH=pat, a plaintext GitHub token is read from /root/.fh-token
#  (mode 600) and written to git's credential store so future pulls work.
#  When FH_AUTH=ssh, /root/.ssh/id_ed25519 is expected to already exist (the
#  installer generated it and had the user paste the public key into the repo's
#  Deploy Keys before re-entering the CT).
# =============================================================================
set -euo pipefail

FH_REPO="${FH_REPO:-https://github.com/Reece-OG/Family-Hub.git}"
FH_BRANCH="${FH_BRANCH:-main}"
FH_AUTH="${FH_AUTH:-public}"
TIMEZONE="${TIMEZONE:-UTC}"
INSTALL_DIR="/opt/family-hub"
TOKEN_FILE="/root/.fh-token"

# ---------- output helpers -----------------------------------------------------
RED=$'\033[0;31m'; GRN=$'\033[0;32m'; BLU=$'\033[0;34m'
BLD=$'\033[1m';    RST=$'\033[0m'
msg()  { echo "${BLU}==>${RST} ${BLD}$*${RST}"; }
ok()   { echo "${GRN}  [ok]${RST} $*"; }
die()  { echo "${RED}[x] $*${RST}" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "setup.sh must run as root inside the container."

# ---------- base system --------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive

msg "Updating apt index + installing base tools..."
apt-get update -qq >/dev/null
apt-get install -y --no-install-recommends \
  ca-certificates curl git openssh-client openssl tzdata gnupg lsb-release >/dev/null
ok "Base tools installed."

if [[ -n "$TIMEZONE" ]]; then
  msg "Setting timezone to ${TIMEZONE}..."
  echo "$TIMEZONE" > /etc/timezone
  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true
fi

# ---------- Docker -------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  msg "Installing Docker Engine (via get.docker.com)..."
  curl -fsSL https://get.docker.com | sh >/dev/null
else
  ok "Docker already present."
fi

systemctl enable docker >/dev/null 2>&1 || true
systemctl start docker  >/dev/null 2>&1 || true

if ! docker compose version >/dev/null 2>&1; then
  die "Docker compose plugin missing after install."
fi
ok "$(docker --version)"
ok "$(docker compose version)"

# ---------- wire up git auth (private-repo modes) -----------------------------
case "$FH_AUTH" in
  public)
    ok "Repo auth: public (no credentials needed)."
    ;;

  pat)
    [[ -s "$TOKEN_FILE" ]] || die "FH_AUTH=pat but $TOKEN_FILE is missing/empty."
    msg "Configuring git credential store from ${TOKEN_FILE}..."
    TOKEN="$(cat "$TOKEN_FILE")"
    chmod 600 "$TOKEN_FILE"

    # Persist credentials for future `git pull` (update.sh) without ever
    # embedding the token in the remote URL.
    git config --global credential.helper "store --file=/root/.git-credentials"
    umask 077
    # The 'x-access-token' user is GitHub's convention for tokens as auth.
    echo "https://x-access-token:${TOKEN}@github.com" > /root/.git-credentials
    chmod 600 /root/.git-credentials
    unset TOKEN
    ok "PAT stored for future git operations (/root/.git-credentials, mode 600)."
    ;;

  ssh)
    [[ -f /root/.ssh/id_ed25519 ]] || die "FH_AUTH=ssh but /root/.ssh/id_ed25519 is missing - installer should have generated it."
    msg "Priming known_hosts with github.com fingerprints..."
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    ssh-keyscan -H github.com >> /root/.ssh/known_hosts 2>/dev/null
    sort -u /root/.ssh/known_hosts -o /root/.ssh/known_hosts
    chmod 600 /root/.ssh/known_hosts /root/.ssh/id_ed25519
    ok "SSH deploy key in place."
    ;;

  *)
    die "Unknown FH_AUTH value: $FH_AUTH (expected public, pat, or ssh)."
    ;;
esac

# ---------- clone / update repo -----------------------------------------------
msg "Fetching Family Hub from ${FH_REPO} (${FH_BRANCH})..."
if [[ -d "$INSTALL_DIR/.git" ]]; then
  git -C "$INSTALL_DIR" remote set-url origin "$FH_REPO"
  git -C "$INSTALL_DIR" fetch --all --prune
  git -C "$INSTALL_DIR" checkout "$FH_BRANCH"
  git -C "$INSTALL_DIR" pull --ff-only
  ok "Repo updated."
else
  rm -rf "$INSTALL_DIR"
  if ! git clone --branch "$FH_BRANCH" --depth 1 "$FH_REPO" "$INSTALL_DIR"; then
    case "$FH_AUTH" in
      pat) die "Clone failed. Check the PAT has Contents:Read-only on this repo, and hasn't expired." ;;
      ssh) die "Clone failed. Check the deploy key was pasted into the repo's Settings -> Deploy keys before continuing." ;;
      *)   die "Clone failed. If the repo is private, re-run the installer and pick 'pat' or 'ssh'." ;;
    esac
  fi
  ok "Repo cloned into ${INSTALL_DIR}."
fi

# ---------- .env with random secrets ------------------------------------------
if [[ ! -f "$INSTALL_DIR/.env" ]]; then
  msg "Generating .env with random secrets..."
  PG_PW="$(openssl rand -hex 24)"
  AUTH_SECRET="$(openssl rand -base64 48 | tr -d '\n')"
  cat > "$INSTALL_DIR/.env" <<EOF
# Auto-generated by Family-Hub-LXC installer on $(date -Is)

# Database
POSTGRES_USER=familyhub
POSTGRES_PASSWORD=${PG_PW}
POSTGRES_DB=familyhub

# Web app port on the host (LXC)
WEB_PORT=3000

# Session JWT secret (48 random bytes, base64)
AUTH_SECRET=${AUTH_SECRET}

# Bootstrap parent account created on first boot if no users exist.
# Change these BEFORE first boot, or update them in-app after logging in.
SEED_PARENT_EMAIL=parent@example.com
SEED_PARENT_PASSWORD=changeme
SEED_PARENT_NAME=Parent

# Branding (leave blank for "Family Hub")
APP_NAME=
EOF
  chmod 600 "$INSTALL_DIR/.env"
  ok ".env written (secrets are unique to this install)."
else
  ok ".env already exists - leaving it alone."
fi

# ---------- build + start ------------------------------------------------------
msg "Building + starting Family Hub containers (first run: ~4 minutes)..."
cd "$INSTALL_DIR"
docker compose pull 2>/dev/null || true
docker compose up -d --build

msg "Waiting for web container to report running..."
for i in {1..60}; do
  if docker compose ps --format '{{.Service}} {{.State}}' 2>/dev/null | grep -q '^web running'; then
    ok "Web container is running."
    break
  fi
  sleep 2
done

# ---------- update helper ------------------------------------------------------
msg "Writing update helper at ${INSTALL_DIR}/update.sh..."
cat > "$INSTALL_DIR/update.sh" <<'UPDATE'
#!/usr/bin/env bash
# Pull the latest commit on the current branch and rebuild Family Hub in place.
# Uses the credential store / deploy key that the installer left on disk.
set -euo pipefail
cd /opt/family-hub
echo "==> git pull"
git pull --ff-only
echo "==> docker compose build"
docker compose build
echo "==> docker compose up -d"
docker compose up -d
echo "Done."
UPDATE
chmod +x "$INSTALL_DIR/update.sh"
ok "Update helper ready: /opt/family-hub/update.sh"

# ---------- token cleanup ------------------------------------------------------
# The PAT file we seeded is no longer needed - git has the cred stored now.
if [[ "$FH_AUTH" == "pat" ]] && [[ -f "$TOKEN_FILE" ]]; then
  shred -u "$TOKEN_FILE" 2>/dev/null || rm -f "$TOKEN_FILE"
  ok "Cleaned up transient PAT file."
fi

# ---------- apt auto-updates (quiet) ------------------------------------------
msg "Enabling unattended security updates..."
apt-get install -y --no-install-recommends unattended-upgrades >/dev/null 2>&1 || true
dpkg-reconfigure -f noninteractive -plow unattended-upgrades >/dev/null 2>&1 || true

ok "Family Hub installation complete."
