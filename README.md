# Family Hub - Proxmox VE LXC installer

One-shot installer that spins up an unprivileged LXC container on a Proxmox VE host, installs Docker + compose inside, clones [Family Hub](https://github.com/Reece-OG/Family-Hub), and brings the stack up with `docker compose`.

Tested on **Proxmox VE 9.1** (Debian 13 / trixie). Also works on PVE 8.x (Debian 12 / bookworm) - the installer picks whichever template is available.

**Two install methods.** The wizard asks which one you want:

- **`docker`** (upstream default) - installs Docker + compose, runs `docker compose up -d`. Mirrors the dev flow in the Family Hub repo exactly. The LXC needs `nesting=1,keyctl=1`.
- **`native`** (recommended for an LXC) - installs Node 20 + PostgreSQL 16 directly, builds the Next.js app from source, runs it under systemd as a dedicated `familyhub` service user. Lower RAM, faster boot, simpler `pg_dump` backups, plain unprivileged LXC with no nesting required.

**Private Family Hub repo?** The installer supports both a fine-grained GitHub PAT and an auto-generated SSH deploy key - see [Private repo access](#private-repo-access). No secret is ever committed to this installer repo.

## Quick install

From a root shell on the Proxmox host:

```bash
bash -c "$(wget -qLO - https://github.com/Reece-OG/Family-Hub-LXC/raw/main/install.sh)"
```

A whiptail wizard will ask for:

- **Install method**: `docker` or `native`
- Container ID (defaults to the next free ID)
- Hostname (default `familyhub`)
- CPU cores, memory, disk size
- Storage pool (dropdown of your `rootdir`-capable storages)
- Bridge + DHCP/static networking
- Timezone (defaults to the Proxmox host's `/etc/timezone`)
- Git repo URL + branch (default: `Reece-OG/Family-Hub` on `main`)
- **Repo access mode:** `public`, `pat`, or `ssh`
- Optional custom app name (branding)

When it's done, the access URL `http://<lxc-ip>:3000` is printed, along with handy `pct` commands for managing the container.

## Private repo access

The `Family-Hub` repo is private while the early versions are stabilising, so the installer needs a way to authenticate.

### Option 1 - Fine-grained Personal Access Token (recommended)

1. Go to <https://github.com/settings/personal-access-tokens/new>.
2. Set:
   - **Resource owner:** `Reece-OG`
   - **Repositories:** *Only select repositories* -> tick `Family-Hub`
   - **Permissions -> Repository permissions -> Contents:** `Read-only`
   - **Expiration:** whatever you like. The token sits inside the LXC with mode `600`; future `git pull`s keep working as long as it's valid.
3. Copy the generated token (starts with `github_pat_...`).
4. Run the installer - choose **pat** when prompted and paste it in.

Non-interactive equivalent:

```bash
FH_AUTH=pat FH_TOKEN=github_pat_... \
bash -c "$(wget -qLO - https://github.com/Reece-OG/Family-Hub-LXC/raw/main/install.sh)" -- --default
```

How the token is handled:

- Whiptail collects it in a password field (not echoed).
- The Proxmox host writes it to `/root/.fh-token` *inside the LXC* (mode 600), never to the host fs.
- `setup.sh` reads it, hands it to git's credential store at `/root/.git-credentials` (mode 600), then **shreds the `.fh-token` file**.
- `git` authenticates future pulls via `https://x-access-token:<token>@github.com` - the remote URL in `.git/config` stays clean, so `git remote -v` doesn't leak the secret.

### Option 2 - SSH deploy key (auto-generated, never leaves the LXC)

1. Run the installer, choose **ssh**.
2. The installer generates an `ed25519` keypair inside the LXC (`/root/.ssh/id_ed25519`).
3. It pauses and prints the public key plus a direct link to the repo's **Settings -> Deploy keys** page.
4. Paste the public key there (leave "Allow write access" unticked). Save.
5. Press Enter in the installer. It switches the repo URL to `git@github.com:...` form and clones.

Non-interactive SSH mode still pauses for the manual key-add step - there's no way around that without giving the installer repo-admin credentials, which we don't want.

### When to rotate

- **PAT** expiry: create a new PAT with the same scope, then inside the LXC:
  ```bash
  echo 'https://x-access-token:<new_pat>@github.com' > /root/.git-credentials
  chmod 600 /root/.git-credentials
  ```
- **SSH key** compromise: delete the deploy key in GitHub, delete `/root/.ssh/id_ed25519*` in the LXC, re-run the wizard with `ssh`.

## Non-interactive install

Pre-seed everything through environment variables and pass `--default` to skip the wizard. Don't forget `FH_METHOD`:

```bash
FH_METHOD=native \
CTID=200 HOSTNAME=familyhub CORES=2 MEMORY=2048 DISK_GB=32 \
STORAGE=local-lvm BRIDGE=vmbr0 NET=dhcp TIMEZONE=Australia/Sydney \
FH_AUTH=pat FH_TOKEN=github_pat_... \
bash -c "$(wget -qLO - https://github.com/Reece-OG/Family-Hub-LXC/raw/main/install.sh)" -- --default
```

Omit `FH_METHOD` (or set it to `docker`) to get the Docker stack instead.

Optional extras:

- `DISK_GB` — defaults to **32 GB** to leave room for the photo gallery, recipes and Postgres dumps. Override up or down as needed.
- `DNS` — leave unset/blank to inherit the Proxmox host's `/etc/resolv.conf` (recommended). Set to a space-separated list (`DNS="1.1.1.1 8.8.8.8"`) to override.
- `FH_IPV6` — defaults to **no**. Most home networks advertise IPv6 via SLAAC but don't route it upstream, which causes Node's `fetch` to hang on AAAA records (the weather widget is the first thing to break). The installer adds `ip6=none` to the CT's net config *and* drops a sysctl file inside the CT to fully disable v6 on `eth0`. Set `FH_IPV6=yes` only if your LAN actually routes IPv6 end-to-end.
- `CT_PASSWORD` — optional root password for the container. Leave unset to skip; you can always shell in with `pct enter <CTID>` from the host.

For a static IP instead of DHCP:

```bash
NET="192.168.1.50/24,gw=192.168.1.1" ... --default
```

## What the installer does

On the Proxmox host (shared by both methods):

1. Checks it's running as root on a real Proxmox VE node.
2. Installs `whiptail` if missing.
3. Runs the wizard (or reads env vars + `--default`).
4. Downloads the newest Debian 13 LXC template (falls back to Debian 12).
5. Creates an **unprivileged** CT. `docker` method adds `features=nesting=1,keyctl=1`; `native` method skips them.
6. Starts the CT and waits for DNS.
7. If `FH_AUTH=ssh`, generates a deploy key inside the CT and pauses for you to paste the public key into the GitHub repo's deploy-keys page.
8. If `FH_AUTH=pat`, transfers the token to `/root/.fh-token` in the CT with mode 600.
9. Pushes the method-specific setup script into the CT and runs it.

### Docker method (`setup-docker.sh`)

1. `apt update`, installs `curl git openssh-client openssl tzdata` + the Docker convenience script.
2. Enables the Docker service.
3. Stores git auth (PAT or SSH) for future pulls.
4. Clones the Family Hub repo to `/opt/family-hub`.
5. Writes `/opt/family-hub/.env` with a freshly-generated random `POSTGRES_PASSWORD` and `AUTH_SECRET`.
6. `docker compose up -d --build` to pull Postgres 16 and build the web image.
7. Writes `/opt/family-hub/update.sh` for in-place upgrades (`git pull && docker compose build && docker compose up -d`).
8. Enables `unattended-upgrades`.

The container's root disk holds the Docker images + compose volumes (Postgres data + uploaded photos), so backing up the LXC through Proxmox's normal snapshot/backup flow captures everything.

### Native method (`setup-native.sh`)

1. `apt update`, installs `build-essential python3 pkg-config libssl-dev` + dev tools.
2. Installs **Node.js 20** from NodeSource and **PostgreSQL 16** from PGDG (so the DB version matches the Docker flow's `postgres:16-alpine`).
3. Creates a `familyhub` Postgres role + `familyhub` database with a random password.
4. Creates a `familyhub` system user (no login shell) to run the app.
5. Clones the Family Hub repo to `/opt/family-hub`.
6. Writes `/opt/family-hub/.env` with `DATABASE_URL`, `AUTH_SECRET`, `NEXT_PUBLIC_APP_NAME`, uploads dir, etc.
7. `npm install` inside `web/`, then `npx prisma generate`, `npx prisma db push`, `npm run build` (Next.js standalone output).
8. Seeds the bootstrap parent user via `node prisma/seed.cjs` (idempotent - skipped if users already exist).
9. Installs a systemd unit `/etc/systemd/system/family-hub.service` that:
   - depends on `postgresql.service`,
   - runs as `familyhub:familyhub`,
   - runs `prisma db push --skip-generate` as `ExecStartPre` (mirrors `docker-entrypoint.sh`),
   - then `node next/dist/bin/next start -p 3000 -H 0.0.0.0`,
   - with hardening (`ProtectSystem=full`, `PrivateTmp=true`, restricted `ReadWritePaths`).
10. Writes `/opt/family-hub/update.sh` for in-place upgrades (`git pull && npm install && prisma db push && npm run build && systemctl restart family-hub`).
11. Enables `unattended-upgrades`.

Backups are even simpler than the Docker flow: `pg_dump -U familyhub familyhub > backup.sql` plus `/opt/family-hub/web/uploads/` covers the whole app state.

## After install

Bootstrap login (shown on first launch, only if no users exist yet):

- Email: `parent@example.com`
- Password: `changeme`

Change either of these *before* first boot by editing `/opt/family-hub/.env` and running `docker compose up -d` again, or just log in and change them in-app.

### Useful commands

```bash
# Shell inside the LXC
pct enter 200

# Pull latest and rebuild (both methods)
pct exec 200 -- /opt/family-hub/update.sh

# Full destroy (wipes Postgres + photos)
pct stop 200 && pct destroy 200 --purge
```

Method-specific log/restart commands:

```bash
# Docker method
pct exec 200 -- bash -c "cd /opt/family-hub && docker compose logs -f web"
pct exec 200 -- bash -c "cd /opt/family-hub && docker compose restart"

# Native method
pct exec 200 -- journalctl -u family-hub -f
pct exec 200 -- systemctl restart family-hub
pct exec 200 -- systemctl status family-hub
```

## Upgrading

Family Hub ships new versions as commits on its `main` branch. There are two ways to pull them in.

### Option 1 — from inside the app (parents only)

Log in as a parent, open **Settings**, scroll to the **System** card:

- **Check for updates** compares the local `HEAD` with `origin/main` and shows whether a newer commit is available.
- **Update now** asks for a second confirmation, then pulls + rebuilds + restarts the app. The card shows a live "Updating…" state while the systemd unit is working and flips to "Update successful" or "Update failed" when it finishes. A rebuild usually takes 3-5 minutes on a low-end CT.

A daily background timer also runs the check automatically (with a 1-hour random jitter so every install doesn't hit GitHub at midnight UTC), so the System card is normally already up-to-date when you open Settings.

**How it works under the hood.** The web app runs unprivileged (as `familyhub` in the native install, as the `nextjs` user inside the container in the Docker install), so it can't run `git`, `docker` or `systemctl` directly. Instead it writes a one-byte trigger file into `/var/lib/family-hub/state/`, and a pair of systemd `.path` units on the LXC host fire the privileged `state-helper.sh` in response. The helper runs `git fetch` / `/opt/family-hub/update.sh` as root and writes JSON status files that the app polls.

- `family-hub-check.path`  — watches `check-requested`, runs `state-helper.sh check`
- `family-hub-update.path` — watches `update-requested`, runs `state-helper.sh update`
- `family-hub-auto-check.timer` — touches `check-requested` once a day

Useful commands:

```bash
# Manual check from the host
pct exec 200 -- /opt/family-hub/state-helper.sh check
cat /var/lib/family-hub/state/version.json

# Watch the update log live
pct exec 200 -- journalctl -u family-hub-update -f

# Disable the daily auto-check if you'd rather drive it manually
pct exec 200 -- systemctl disable --now family-hub-auto-check.timer
```

### Option 2 — from the LXC shell

Both methods still ship the classic CLI updater:

```bash
pct exec 200 -- update
# or directly:
pct exec 200 -- /opt/family-hub/update.sh
```

This is the same script the in-app button invokes, and it's safe to run while the container is live — Docker Compose only recreates containers whose images changed, and the Postgres + uploads volumes are unaffected.

### Retrofitting the in-app updater onto an older install

The in-app update card was added in v4.7.2. If your CT was created with a v4.7.1 (or earlier) installer, pulling the new code isn't enough — the host-side bits (state directory, `state-helper.sh`, six systemd units) aren't in the app repo and have to be installed on the CT. Run this once as root inside the CT:

```bash
pct exec 200 -- bash -c "$(curl -fsSL https://raw.githubusercontent.com/Reece-OG/Family-Hub-LXC/main/migrate-to-4.7.2.sh)"
```

The script is idempotent — safe to re-run — and auto-detects whether you're on a native or Docker install. After it finishes, reload Settings → System in your browser and the Updates card should light up.

> **If your in-app update fails with `cannot open '.git/FETCH_HEAD': Permission denied`,** re-run the migration command above. The fix lives in `state-helper.sh` (run git as the repo owner instead of root, and reclaim any root-owned files in `.git`); re-running migrate pulls the new helper, repoints the systemd units at it, and restores ownership in one pass. After it finishes hit **Settings → Check for updates → Update now** and the rebuild should complete.

## Troubleshooting

**Clone fails with `Authentication failed` (PAT mode)**
Token expired, or missing `Contents: Read-only` permission on the Family-Hub repo. Regenerate and drop into `/root/.git-credentials` (see *Rotation* above).

**Clone fails with `Permission denied (publickey)` (SSH mode)**
The deploy key wasn't added to the repo before continuing. Inside the CT: `cat /root/.ssh/id_ed25519.pub`, paste into <https://github.com/Reece-OG/Family-Hub/settings/keys>, then re-run `/opt/family-hub/update.sh` or `git clone` manually.

**`pveam download ... 403` / template download fails**
Network from the Proxmox host to `download.proxmox.com` is blocked. Pre-seed the template manually: `pveam update && pveam download local debian-13-standard_13.0-1_amd64.tar.zst`, then re-run the installer.

**`Error: cannot start container - permission denied`**
The host's AppArmor profile may be blocking the nested mounts Docker needs. Make sure the CT has `features: nesting=1,keyctl=1` in `/etc/pve/lxc/<CTID>.conf` - the installer sets this, but a restore from an older backup may not.

**Web container crash-loops right after install**
Almost always a bad `AUTH_SECRET` or `DATABASE_URL`. Inspect with `pct exec <CTID> -- bash -c 'cd /opt/family-hub && docker compose logs web | tail -50'` - if Prisma can't migrate, the Postgres volume got wiped while the app kept old creds. Fix by removing `/opt/family-hub/.env`, deleting the `family-hub_db_data` volume (`docker volume rm family-hub_db_data`), and re-running `/root/setup.sh`.

## Uninstall

```bash
pct stop 200 && pct destroy 200 --purge
```

This removes the container, its rootfs, both Docker volumes (Postgres + photos), **and** the stored PAT / deploy key. There is nothing left behind on the Proxmox host.

## License

MIT - see [LICENSE](LICENSE).
