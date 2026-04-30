#!/usr/bin/env bash
# =============================================================================
#  Family Hub - state helper (privileged update-check + update runner)
# =============================================================================
#  This script is the *privileged* side of the in-app update feature. The
#  unprivileged web app can't run git, docker, systemctl or update.sh on
#  its own; instead it writes a sentinel file into /var/lib/family-hub/state/
#  and the systemd path units installed alongside this helper call back here
#  as root.
#
#  Layout of the state directory (owned by familyhub:familyhub, 755):
#     check-requested      - touched by the app to request a version check
#     update-requested     - touched by the app to request an update
#     version.json         - written by `state-helper.sh check`
#     update-status.json   - written by `state-helper.sh update`
#
#  Wire-up (installed by setup-native.sh / setup-docker.sh):
#     family-hub-check.path       -> family-hub-check.service -> `check`
#     family-hub-update.path      -> family-hub-update.service -> `update`
#     family-hub-auto-check.timer -> family-hub-auto-check.service
#                                      which just touches the trigger file
#
#  The helper itself never talks to the web app; it only reads the trigger
#  files (to clean them up) and writes status files the app can poll.
# =============================================================================
set -euo pipefail

STATE_DIR=/var/lib/family-hub/state
INSTALL_DIR=/opt/family-hub
WEB_DIR=${INSTALL_DIR}/web
SERVICE_USER=familyhub
VERSION_FILE="${STATE_DIR}/version.json"
UPDATE_STATUS_FILE="${STATE_DIR}/update-status.json"
UPDATE_LOG=/var/log/family-hub-update.log

[[ $EUID -eq 0 ]] || { echo "state-helper.sh must run as root" >&2; exit 1; }

mkdir -p "$STATE_DIR"
chgrp "$SERVICE_USER" "$STATE_DIR" 2>/dev/null || true
chmod 775 "$STATE_DIR"

# v4.7.5 — every git command in this script runs as the repo OWNER, not as
# root. Earlier versions ran git as root with safe.directory=$INSTALL_DIR to
# bypass Git 2.35+'s dubious-ownership check, but that left root-owned
# writes inside .git (most visibly .git/FETCH_HEAD). The next time
# update.sh's `do_git_pull` ran as the service user it would fail with
# "cannot open '.git/FETCH_HEAD': Permission denied".
#
# Resolving the owner from the .git directory itself works for both the
# native install (familyhub) and the docker host (root) without hard-coding
# either. If the repo isn't a git checkout yet (fresh clone halted), we
# fall back to root + safe.directory so cmd_check can still emit a
# meaningful version.json error.
GIT_RUN_AS_USER=""
if [[ -d "${INSTALL_DIR}/.git" ]]; then
  GIT_RUN_AS_USER="$(stat -c '%U' "${INSTALL_DIR}/.git" 2>/dev/null || true)"
  if [[ "$GIT_RUN_AS_USER" == "root" ]]; then
    GIT_RUN_AS_USER=""
  fi
fi

# Reclaim any files that prior root-as-git invocations left behind in .git.
# Cheap and idempotent: chown -R only writes when a row's owner differs.
# Without this, a CT that ran on an older state-helper still has root-owned
# FETCH_HEAD / refs from before the upgrade and update.sh would keep
# bouncing off the same permission error.
fix_git_ownership() {
  if [[ -n "$GIT_RUN_AS_USER" ]] && [[ -d "${INSTALL_DIR}/.git" ]]; then
    chown -R "${GIT_RUN_AS_USER}:${GIT_RUN_AS_USER}" "${INSTALL_DIR}/.git" 2>/dev/null || true
  fi
}

git_inst() {
  if [[ -n "$GIT_RUN_AS_USER" ]]; then
    sudo -u "$GIT_RUN_AS_USER" -- git -C "$INSTALL_DIR" "$@"
  else
    git -c safe.directory="$INSTALL_DIR" -C "$INSTALL_DIR" "$@"
  fi
}

# --- Small JSON-writer helpers ------------------------------------------------
# We avoid taking a hard dep on jq: the only user-controlled strings we ever
# embed are short status labels, SHAs (hex), and truncated log tails. For the
# log tail we strip backslashes, double-quotes and newlines so the emitted
# JSON stays valid without needing a full escaper.

json_escape() {
  # Strip the three characters that would break our minimal JSON writer, then
  # collapse whitespace to single spaces. Good enough for a truncated log tail.
  tr -d '"\\' | tr '\r\n\t' '   ' | sed 's/  */ /g'
}

write_file_atomic() {
  # Write stdin to the target file atomically (tmp + rename) and set mode 644,
  # group=familyhub so the web app (running as familyhub) can read it.
  local target="$1"
  local tmp
  tmp="$(mktemp "${STATE_DIR}/.tmp.XXXXXX")"
  cat > "$tmp"
  chmod 644 "$tmp"
  chgrp "$SERVICE_USER" "$tmp" 2>/dev/null || true
  mv "$tmp" "$target"
}

now_iso() { date -Is; }

# --- check --------------------------------------------------------------------
# Fetches origin/<current-branch> and compares to HEAD. Writes version.json
# with localSha / remoteSha / updateAvailable / commitsBehind. Never throws —
# on failure we write a version.json with error=... so the UI can show it.

cmd_check() {
  local started
  started="$(now_iso)"
  local err=""
  local branch local_sha remote_sha commits_behind pkg_version

  # First-thing: reclaim any root-owned .git artefacts a prior version of
  # this helper may have left behind, so the about-to-run fetch (as the
  # repo owner) can write FETCH_HEAD without bouncing off EACCES.
  fix_git_ownership

  if ! branch="$(git_inst rev-parse --abbrev-ref HEAD 2>/dev/null)"; then
    err="not a git checkout at $INSTALL_DIR"
    branch="main"
  fi

  # Fetch without pulling. Credential store at /root/.git-credentials or the
  # deploy key at /root/.ssh/id_ed25519 is picked up automatically for root.
  if [[ -z "$err" ]]; then
    if ! git_inst fetch --quiet origin "$branch" 2>>"$UPDATE_LOG"; then
      err="git fetch failed (see $UPDATE_LOG)"
    fi
  fi

  local_sha="$(git_inst rev-parse HEAD 2>/dev/null || echo '')"
  remote_sha=""
  commits_behind=0
  if [[ -z "$err" ]]; then
    remote_sha="$(git_inst rev-parse "origin/${branch}" 2>/dev/null || echo '')"
    if [[ -n "$local_sha" ]] && [[ -n "$remote_sha" ]]; then
      commits_behind="$(git_inst rev-list --count "HEAD..origin/${branch}" 2>/dev/null || echo 0)"
    fi
  fi

  pkg_version="$(node -p "require('${WEB_DIR}/package.json').version" 2>/dev/null || echo '')"

  local update_available=false
  if [[ "${commits_behind:-0}" -gt 0 ]]; then update_available=true; fi

  local err_field="null"
  if [[ -n "$err" ]]; then
    err_field="\"$(printf '%s' "$err" | json_escape)\""
  fi

  write_file_atomic "$VERSION_FILE" <<JSON
{
  "branch": "${branch}",
  "localSha": "${local_sha}",
  "localShaShort": "${local_sha:0:7}",
  "remoteSha": "${remote_sha}",
  "remoteShaShort": "${remote_sha:0:7}",
  "version": "${pkg_version}",
  "updateAvailable": ${update_available},
  "commitsBehind": ${commits_behind:-0},
  "checkedAt": "${started}",
  "error": ${err_field}
}
JSON
}

# --- update -------------------------------------------------------------------
# Writes update-status.json=running, shells out to /opt/family-hub/update.sh
# (the in-place updater written by setup-*.sh), then writes success|failed.
# We intentionally don't duplicate update.sh's logic — the shell updater is
# already battle-tested and used manually from `pct exec ... update`.

cmd_update() {
  local started
  started="$(now_iso)"

  # Same defensive ownership reclaim as cmd_check — update.sh will run git
  # as the service user and fall over if root-owned files are still in .git.
  fix_git_ownership

  write_file_atomic "$UPDATE_STATUS_FILE" <<JSON
{"state":"running","startedAt":"${started}","finishedAt":null,"error":null}
JSON

  # Tee to the log so `journalctl -u family-hub-update` and tail the log file
  # both work for post-mortems.
  local rc=0
  if ! "${INSTALL_DIR}/update.sh" >>"$UPDATE_LOG" 2>&1; then
    rc=$?
  fi

  local finished
  finished="$(now_iso)"
  if [[ $rc -eq 0 ]]; then
    write_file_atomic "$UPDATE_STATUS_FILE" <<JSON
{"state":"success","startedAt":"${started}","finishedAt":"${finished}","error":null}
JSON
  else
    local tail_err
    tail_err="$(tail -20 "$UPDATE_LOG" 2>/dev/null | json_escape)"
    write_file_atomic "$UPDATE_STATUS_FILE" <<JSON
{"state":"failed","startedAt":"${started}","finishedAt":"${finished}","error":"${tail_err}"}
JSON
  fi

  # After a successful update, re-run check so the UI flips from "Update
  # available" to "Up to date" without waiting for the next daily timer.
  if [[ $rc -eq 0 ]]; then
    cmd_check || true
  fi
}

case "${1:-}" in
  check)
    cmd_check
    rm -f "${STATE_DIR}/check-requested"
    ;;
  update)
    cmd_update
    rm -f "${STATE_DIR}/update-requested"
    ;;
  *)
    echo "Usage: $0 {check|update}" >&2
    exit 2
    ;;
esac
