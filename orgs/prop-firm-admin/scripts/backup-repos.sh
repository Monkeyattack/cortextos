#!/usr/bin/env bash
# backup-repos.sh — restic backup for /home/claude-dev/repos
#
# STATUS: DRAFT, INERT. Chief gave a PARTIAL GO on 2026-08-12: draft the config,
# hold the target for Chris. This script therefore refuses to run until both
# (a) restic is installed and (b) a target is configured. It is safe to leave
# on disk and safe to schedule early — it fails closed rather than silently
# backing up to nowhere.
#
# WHY THIS EXISTS: audit 2026-08-03, re-confirmed live 2026-08-12 — /home/claude-dev/repos
# has NO backup of any kind. No restic, borg or duplicity installed; no backup cron;
# no systemd timer. Several repos have no git remote at all, so for those the disk
# is the only copy in existence.
#
# WHAT CHRIS STILL HAS TO DECIDE (do not guess this):
#   RESTIC_REPOSITORY — an off-box target. s3:/r2:, sftp:user@host:/path, or a volume.
#   RESTIC_PASSWORD   — repo encryption key. Belongs in Vault at secret/restic, NOT here.
# Losing the password means losing the backup; restic cannot recover it.

set -euo pipefail

REPO_SRC="/home/claude-dev/repos"
VAULT_PATH="secret/restic"
LOG_PREFIX="[backup-repos]"

log() { echo "${LOG_PREFIX} $(date -u +%Y-%m-%dT%H:%M:%SZ)  $*"; }
die() { log "REFUSING TO RUN: $*"; exit 1; }

# ── Preflight. Every one of these is a fail-closed gate. ────────────────────
command -v restic >/dev/null 2>&1 \
  || die "restic is not installed. See the [HUMAN] task: sudo apt-get install -y restic"

[[ -d "${REPO_SRC}" ]] || die "source ${REPO_SRC} does not exist"

# Credentials come from Vault, never from this file and never from a literal.
if [[ -z "${RESTIC_REPOSITORY:-}" ]]; then
  RESTIC_REPOSITORY="$(vault kv get -field=repository "${VAULT_PATH}" 2>/dev/null || true)"
fi
if [[ -z "${RESTIC_PASSWORD:-}" ]]; then
  RESTIC_PASSWORD="$(vault kv get -field=password "${VAULT_PATH}" 2>/dev/null || true)"
fi
export RESTIC_REPOSITORY RESTIC_PASSWORD

[[ -n "${RESTIC_REPOSITORY}" ]] \
  || die "no target configured. Chris has not chosen one yet — this is the held decision, not a bug."
[[ -n "${RESTIC_PASSWORD}" ]] \
  || die "no repo password at ${VAULT_PATH}. Refusing to create an unencrypted or unrecoverable repo."

# ── Exclusions ──────────────────────────────────────────────────────────────
# Backing up node_modules and build output would multiply size for content that
# is reproducible from a lockfile. Everything excluded here must be derivable.
EXCLUDES=(
  --exclude "node_modules"
  --exclude ".next"
  --exclude "dist"
  --exclude "build"
  --exclude "venv"
  --exclude "__pycache__"
  --exclude "*.pyc"
  --exclude ".cache"
)

# ── Run ─────────────────────────────────────────────────────────────────────
if ! restic snapshots >/dev/null 2>&1; then
  log "target has no restic repo yet — initialising"
  restic init
fi

log "backing up ${REPO_SRC}"
restic backup "${REPO_SRC}" "${EXCLUDES[@]}" --tag repos --tag automated

# Keep a window long enough to survive an undetected corruption, not just an
# accidental delete. Daily-for-a-week catches "I broke it yesterday"; monthly
# catches "this has been wrong for a while and nobody noticed".
log "pruning old snapshots"
restic forget --tag repos --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

# A backup nobody has restored is a hypothesis. check --read-data-subset
# actually reads a slice back off the target and verifies it, rather than
# trusting the index.
log "verifying (1% read-back)"
restic check --read-data-subset=1%

log "done"
