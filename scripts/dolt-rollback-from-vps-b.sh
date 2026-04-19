#!/usr/bin/env bash
# dolt-rollback-from-vps-b.sh — Reverse the VPS-B Dolt migration.
#
# When to use:
#   - Canary phase of the migrate runbook failed (bd not working against VPS-B).
#   - Post-migration ops discovered an unworkable latency / correctness issue
#     within the ~1-week cold-backup window.
#   - VPS-B went offline and we need local Dolt back up RIGHT NOW.
#
# This script is the mirror image of dolt-migrate-to-vps-b.sh:
#   1. Stop remote Dolt on VPS-B (so there is exactly one source of truth).
#   2. Thaw the local cold-backup copy (chmod u+w).
#   3. (Optional) rsync any deltas from VPS-B back to local — OFF by default
#      because we assume the local copy is the authoritative "old world" and
#      only a short maintenance window elapsed. Enable with --reverse-rsync
#      if VPS-B ran long enough to matter.
#   4. Start local Dolt (`gt dolt start`).
#   5. Revert the per-rig metadata.json commits (if they were pushed) OR reset
#      the pushed main pointer back one commit.
#   6. Unset GT_DOLT_HOST in the operator's shells.
#   7. Restart the gt daemon.
#   8. Verify bd works locally.
#
# ⚠ HUMAN-OPERATED SCRIPT. Do NOT run from a polecat session — killing remote
#   Dolt hangs bd/mail until local comes up.
#
# Usage:
#   scripts/dolt-rollback-from-vps-b.sh --dry-run
#   scripts/dolt-rollback-from-vps-b.sh
#   scripts/dolt-rollback-from-vps-b.sh --reverse-rsync

set -euo pipefail

# --------------------------------------------------------------------------- #
# CONFIG (keep in sync with dolt-migrate-to-vps-b.sh)
# --------------------------------------------------------------------------- #
VPSB_HOST="${VPSB_HOST:-10.10.0.3}"
VPSB_PORT="${VPSB_PORT:-3307}"
VPSB_SSH_HOST="${VPSB_SSH_HOST:-$VPSB_HOST}"
VPSB_SSH_USER="${VPSB_SSH_USER:-crash}"

LOCAL_DOLT_DATA="${LOCAL_DOLT_DATA:-$HOME/gt/.dolt-data}"
LOCAL_DOLT_BACKUP="${LOCAL_DOLT_BACKUP:-$HOME/gt/.dolt-backup}"
REMOTE_DOLT_DATA="${REMOTE_DOLT_DATA:-/opt/gastown/.dolt-data}"
REMOTE_DOLT_BACKUP="${REMOTE_DOLT_BACKUP:-/opt/gastown/.dolt-backup}"

RIG_METADATA_TARGETS=(
    "hq:$HOME/gt"
    "gastown:$HOME/gt/gastown/polecats/obsidian/gastown"
    "figaro:$HOME/gt/figaro"
    "darkdisco:"
    "trapline:"
)
STAGE_BRANCH_PREFIX="${STAGE_BRANCH_PREFIX:-polecat/obsidian/gt-4ek-meta-dolt-host}"

# `gt daemon` has no explicit `restart` — fall back to stop+start.
GT_DAEMON_RESTART_CMD="${GT_DAEMON_RESTART_CMD:-gt daemon stop && sleep 2 && gt daemon start}"

DRY_RUN=0
REVERSE_RSYNC=0

while (($#)); do
    case "$1" in
        --dry-run)        DRY_RUN=1; shift ;;
        --reverse-rsync)  REVERSE_RSYNC=1; shift ;;
        -h|--help) sed -n '1,35p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

run() {
    if ((DRY_RUN)); then
        printf '  [dry-run] %s\n' "$*"
    else
        eval "$@"
    fi
}

fail() { echo "✖ $*" >&2; exit 1; }
ok()   { echo "✓ $*"; }

echo "=============================================================="
echo "ROLLBACK: Dolt VPS-B → local"
echo "  VPS-B    $VPSB_HOST:$VPSB_PORT"
echo "  Local    $LOCAL_DOLT_DATA"
echo "=============================================================="

# --------------------------------------------------------------------------- #
# 1. Stop remote Dolt
# --------------------------------------------------------------------------- #
echo
echo "▶ Stopping remote Dolt on VPS-B"
if ssh -o BatchMode=yes -o ConnectTimeout=5 \
      "$VPSB_SSH_USER@$VPSB_SSH_HOST" 'echo ok' >/dev/null 2>&1; then
    run "ssh \"$VPSB_SSH_USER@$VPSB_SSH_HOST\" 'sudo systemctl stop dolt.service'"
    # Wait for port to close.
    for _ in $(seq 1 30); do
        ssh "$VPSB_SSH_USER@$VPSB_SSH_HOST" \
            "ss -tln '( sport = :$VPSB_PORT )' | grep -q :$VPSB_PORT" \
            2>/dev/null || break
        sleep 1
    done
    ok "Remote Dolt stopped"
else
    echo "  ⚠ VPS-B unreachable. Assuming it is already down."
fi

# --------------------------------------------------------------------------- #
# 2. (Optional) pull back any deltas the local copy missed
# --------------------------------------------------------------------------- #
if ((REVERSE_RSYNC)); then
    echo
    echo "▶ Reverse rsync VPS-B → local"
    run "chmod -R u+w \"$LOCAL_DOLT_DATA\""
    run "rsync -aAX --delete --numeric-ids --info=progress2 \
        \"$VPSB_SSH_USER@$VPSB_SSH_HOST:$REMOTE_DOLT_DATA/\" \"$LOCAL_DOLT_DATA/\""
    run "rsync -aAX --delete --numeric-ids --info=progress2 \
        \"$VPSB_SSH_USER@$VPSB_SSH_HOST:$REMOTE_DOLT_BACKUP/\" \"$LOCAL_DOLT_BACKUP/\""
    ok "Deltas pulled back"
fi

# --------------------------------------------------------------------------- #
# 3. Thaw the local cold-backup dirs
# --------------------------------------------------------------------------- #
echo
echo "▶ Thawing local data dirs"
run "chmod -R u+w \"$LOCAL_DOLT_DATA\""
run "chmod -R u+w \"$LOCAL_DOLT_BACKUP\" 2>/dev/null || true"
ok "Local dirs writable"

# --------------------------------------------------------------------------- #
# 4. Unset GT_DOLT_HOST in rc files
# --------------------------------------------------------------------------- #
echo
echo "▶ Removing GT_DOLT_HOST export from shell rc files"
for rc in "$HOME/.bashrc" "$HOME/.profile"; do
    [[ -f "$rc" ]] || continue
    if grep -q '^export GT_DOLT_HOST=' "$rc"; then
        # Remove both the marker comment (from migrate) and the export line.
        run "sed -i '/^# gt-4ek: Dolt moved to VPS-B\$/d' \"$rc\""
        run "sed -i '/^export GT_DOLT_HOST=/d' \"$rc\""
        ok "cleaned $rc"
    fi
done
# Unset in-process so subsequent phases in THIS shell talk to local.
unset GT_DOLT_HOST

# --------------------------------------------------------------------------- #
# 5. Start local Dolt
# --------------------------------------------------------------------------- #
echo
echo "▶ Starting local Dolt"
run "gt dolt start"
for i in $(seq 1 30); do
    if ss -tln '( sport = :3307 )' | grep -q ':3307'; then
        ok "Local Dolt listening on :3307 (after ${i}s)"
        break
    fi
    sleep 1
    (( i == 30 )) && fail "Local Dolt did not start listening in 30s."
done

# --------------------------------------------------------------------------- #
# 6. Revert or reset the per-rig metadata commits
# --------------------------------------------------------------------------- #
echo
echo "▶ Reverting metadata.json commits"
for entry in "${RIG_METADATA_TARGETS[@]}"; do
    label="${entry%%:*}"
    repo="${entry#*:}"
    branch="${STAGE_BRANCH_PREFIX}-${label}"
    if [[ -z "$repo" || ! -d "$repo/.git" ]]; then
        echo "  $label: no local git tree — revert metadata.json in-place instead."
        echo "    If it was edited, restore dolt_server_host=127.0.0.1 and remove"
        echo "    dolt_server_port if it was added."
        continue
    fi
    (
        cd "$repo"
        # Did the metadata branch land on main? If yes, create a revert commit.
        default_branch=main
        git show-ref --verify --quiet refs/heads/main || default_branch=master
        run "git fetch --quiet origin $default_branch || true"

        if [[ -n "$(git log --format=%H "origin/$default_branch" \
                --grep "flip $label dolt_server_host" 2>/dev/null || true)" ]]; then
            # Landed — create a revert commit on a new branch.
            merged_sha=$(git log --format=%H "origin/$default_branch" \
                --grep "flip $label dolt_server_host" | head -1)
            revert_branch="${branch}-revert"
            run "git checkout -q -b \"$revert_branch\" \"origin/$default_branch\""
            run "git revert --no-edit \"$merged_sha\""
            echo "  $label: revert branch created at $revert_branch — push + MR it."
        elif git rev-parse --verify "$branch" >/dev/null 2>&1; then
            # Not landed, just local. Delete the local branch.
            run "git branch -qD \"$branch\""
            ok "$label: deleted unmerged staging branch $branch"
        else
            echo "  $label: no metadata commit found — nothing to revert."
        fi
    )
done

# --------------------------------------------------------------------------- #
# 7. Restart gt daemon
# --------------------------------------------------------------------------- #
echo
echo "▶ Restarting gt daemon"
run "$GT_DAEMON_RESTART_CMD"

daemon_pid=$(pgrep -f 'gt daemon' | head -1 || echo '')
if [[ -n "$daemon_pid" ]] && \
    grep -qz 'GT_DOLT_HOST=' "/proc/$daemon_pid/environ" 2>/dev/null; then
    fail "gt daemon still has GT_DOLT_HOST set — investigate before continuing."
fi
ok "Daemon restarted, GT_DOLT_HOST unset"

# --------------------------------------------------------------------------- #
# 8. Verify local bd works
# --------------------------------------------------------------------------- #
echo
echo "▶ Canary: bd list against local Dolt"
if bd list --status=open --limit=1 >/dev/null 2>&1; then
    ok "bd works locally"
else
    fail "bd list failed — check daemon logs and /home/crash/gt/daemon/dolt.log"
fi

echo
echo "=============================================================="
echo "✓ Rollback complete. Dolt is running locally again."
echo "  Reopen your shells (or run 'exec \$SHELL') so GT_DOLT_HOST clears."
echo "=============================================================="
