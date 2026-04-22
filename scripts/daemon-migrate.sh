#!/usr/bin/env bash
# Migrate an existing ab-pty host install to the canonical /opt/ab/ layout.
#
# Canonical paths (v0.1.10+):
#   /opt/ab/ab-pty          (binary)
#   /opt/ab/.jwt-secret     (JWT secret)
#   /opt/ab/data/           (SQLite DB)
#   /opt/ab/backups/        (tarballs of pre-migration state)
#
# Legacy install layouts handled:
#   /opt/nag-daemons/{ab-pty, .jwt-secret, data/}
#   /opt/ab-pty/{ab-pty, .jwt-secret}  +  /opt/data/sessions.db
#   /opt/agent-bridge/{.jwt-secret}
#
# Usage (on the remote host):
#   bash daemon-migrate.sh           # dry-run, prints what it would do
#   bash daemon-migrate.sh --apply   # actually performs the migration
#
# The script is idempotent: running it twice is safe.

set -euo pipefail

APPLY=false
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

log()  { echo "[migrate] $*"; }
run()  {
  if $APPLY; then
    log "RUN: $*"
    eval "$@"
  else
    log "DRY: $*"
  fi
}

CANONICAL_DIR="/opt/ab"
CANONICAL_BIN="${CANONICAL_DIR}/ab-pty"
CANONICAL_SECRET="${CANONICAL_DIR}/.jwt-secret"
CANONICAL_DATA="${CANONICAL_DIR}/data"
BACKUP_DIR="${CANONICAL_DIR}/backups/$(date -u +%Y%m%dT%H%M%SZ)"

# Discover legacy sources (first match wins per category).
find_first_existing() {
  for p in "$@"; do
    [[ -e "$p" ]] && { echo "$p"; return; }
  done
}

LEGACY_BIN="$(find_first_existing \
  /opt/nag-daemons/ab-pty \
  /opt/ab-pty/ab-pty \
  )"

LEGACY_SECRET="$(find_first_existing \
  /opt/agent-bridge/.jwt-secret \
  /opt/nag-daemons/.jwt-secret \
  /opt/ab-pty/.jwt-secret \
  )"

LEGACY_DB="$(find_first_existing \
  /opt/nag-daemons/data/sessions.db \
  /opt/data/sessions.db \
  /opt/ab-pty/data/sessions.db \
  )"

echo
log "Target canonical dir: $CANONICAL_DIR"
log "Found legacy binary:  ${LEGACY_BIN:-<none>}"
log "Found legacy secret:  ${LEGACY_SECRET:-<none>}"
log "Found legacy DB:      ${LEGACY_DB:-<none>}"
log "Backup dir:           $BACKUP_DIR"
echo

if ! $APPLY; then
  log "Dry-run. Re-run with --apply to perform the migration."
  echo
fi

UNIT_NEEDS_REWRITE=false
if [[ -f /etc/systemd/system/ab-pty.service ]] && grep -qE '/opt/(nag-daemons|ab-pty|agent-bridge|data)' /etc/systemd/system/ab-pty.service; then
  UNIT_NEEDS_REWRITE=true
fi

if [[ -f "$CANONICAL_BIN" && -f "$CANONICAL_SECRET" && -f "$CANONICAL_DATA/sessions.db" && "$UNIT_NEEDS_REWRITE" == "false" ]]; then
  log "Canonical layout already present — nothing to do."
  exit 0
fi

# Stop the systemd service if it exists and is active.
if command -v systemctl >/dev/null 2>&1 && systemctl cat ab-pty >/dev/null 2>&1; then
  if systemctl is-active --quiet ab-pty; then
    log "ab-pty service is active — will stop it before moving files."
    run "systemctl stop ab-pty"
  fi
fi

# Create canonical directories.
run "mkdir -p '$CANONICAL_DIR' '$CANONICAL_DATA' '$BACKUP_DIR'"

# Copy legacy files into backup first (always, if they exist).
if [[ -n "$LEGACY_BIN" ]]; then
  run "cp -a '$LEGACY_BIN' '$BACKUP_DIR/ab-pty.old'"
fi
if [[ -n "$LEGACY_SECRET" ]]; then
  run "cp -a '$LEGACY_SECRET' '$BACKUP_DIR/.jwt-secret'"
fi
if [[ -n "$LEGACY_DB" ]]; then
  run "cp -a '$LEGACY_DB' '$BACKUP_DIR/sessions.db'"
fi

# Move into canonical locations if not already there.
if [[ -n "$LEGACY_BIN" && ! -f "$CANONICAL_BIN" ]]; then
  run "cp -a '$LEGACY_BIN' '$CANONICAL_BIN'"
  run "chmod +x '$CANONICAL_BIN'"
fi
if [[ -n "$LEGACY_SECRET" && ! -f "$CANONICAL_SECRET" ]]; then
  run "cp -a '$LEGACY_SECRET' '$CANONICAL_SECRET'"
  run "chmod 600 '$CANONICAL_SECRET'"
fi
if [[ -n "$LEGACY_DB" && ! -f "$CANONICAL_DATA/sessions.db" ]]; then
  run "cp -a '$LEGACY_DB' '$CANONICAL_DATA/sessions.db'"
fi

# Rewrite systemd unit if it references legacy paths.
UNIT_FILE=/etc/systemd/system/ab-pty.service
if [[ -f "$UNIT_FILE" ]] && grep -qE '/opt/(nag-daemons|ab-pty|agent-bridge|data)' "$UNIT_FILE"; then
  run "cp -a '$UNIT_FILE' '$BACKUP_DIR/ab-pty.service'"
  if $APPLY; then
    log "Rewriting $UNIT_FILE ExecStart/WorkingDirectory/AB_PTY_DATABASE to canonical paths."
    sed -i -E "s#ExecStart=/opt/(nag-daemons|ab-pty|agent-bridge)/ab-pty#ExecStart=${CANONICAL_BIN}#g" "$UNIT_FILE"
    sed -i -E "s#WorkingDirectory=/opt/(nag-daemons|ab-pty|agent-bridge)#WorkingDirectory=${CANONICAL_DIR}#g" "$UNIT_FILE"
    sed -i -E "s#AB_PTY_DATABASE=/opt/(nag-daemons|ab-pty|data)(/data)?/sessions\.db#AB_PTY_DATABASE=${CANONICAL_DATA}/sessions.db#g" "$UNIT_FILE"
    systemctl daemon-reload
  else
    log "DRY: would rewrite $UNIT_FILE"
  fi
fi

# Install the short-name `ab` CLI wrapper. Lets the in-session agent run
# `ab sessions list/write/tail/...` instead of spelling out
# `/opt/ab/ab-pty client sessions ...`.
WRAPPER_PATH=/usr/local/bin/ab
WRAPPER_CONTENT='#!/bin/sh
exec /opt/ab/ab-pty client "$@"'
if $APPLY; then
  log "RUN: install $WRAPPER_PATH"
  printf '%s\n' "$WRAPPER_CONTENT" > "$WRAPPER_PATH" && chmod +x "$WRAPPER_PATH"
else
  log "DRY: install $WRAPPER_PATH"
fi

# Start the service again if systemd is available.
if command -v systemctl >/dev/null 2>&1 && systemctl cat ab-pty >/dev/null 2>&1; then
  run "systemctl start ab-pty"
  if $APPLY; then
    sleep 2
    systemctl --no-pager status ab-pty | head -5 || true
  fi
fi

echo
log "Done. Legacy files remain in place; remove them once you've verified the new layout."
log "Backup of pre-migration state: $BACKUP_DIR"
