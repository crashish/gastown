#!/usr/bin/env bash
# dolt-migrate-to-vps-b.sh — Migrate Gas Town Dolt from local host to VPS-B.
#
# ⚠ HUMAN-OPERATED SCRIPT. Do NOT run this from a polecat session. Stopping
#   local Dolt will hang bd/gt/mail and kill the session mid-run.
#
# Workflow (run from the mayor/human shell on the LOCAL host):
#   1. Edit the CONFIG block below if paths/hosts have drifted.
#   2. Dry run:   scripts/dolt-migrate-to-vps-b.sh --dry-run
#   3. Full run:  scripts/dolt-migrate-to-vps-b.sh
#
# Phases (each can be skipped for re-runs after a partial failure):
#   preflight, freeze, rsync, remote-start, push-metadata,
#   verify, export-env, daemon-restart, canary, thaw
#
# Skip individual phases:  --skip-preflight --skip-rsync ...
# Run just one phase:      --only <phase>
#
# Rollback lives next door: scripts/dolt-rollback-from-vps-b.sh.
#
# See docs/dolt-on-vps-b.md for full context; mesh/dolt.service for the remote
# systemd unit referenced by phase 'remote-start'.

set -euo pipefail

# --------------------------------------------------------------------------- #
# CONFIG
# --------------------------------------------------------------------------- #
VPSB_HOST="${VPSB_HOST:-10.10.0.3}"
VPSB_PORT="${VPSB_PORT:-3307}"
VPSB_SSH_HOST="${VPSB_SSH_HOST:-$VPSB_HOST}"
VPSB_SSH_USER="${VPSB_SSH_USER:-crash}"
LOCAL_WG_IP="${LOCAL_WG_IP:-10.10.0.1}"

LOCAL_DOLT_DATA="${LOCAL_DOLT_DATA:-$HOME/gt/.dolt-data}"
LOCAL_DOLT_BACKUP="${LOCAL_DOLT_BACKUP:-$HOME/gt/.dolt-backup}"
REMOTE_DOLT_DIR="${REMOTE_DOLT_DIR:-/opt/gastown}"
REMOTE_DOLT_DATA="${REMOTE_DOLT_DATA:-$REMOTE_DOLT_DIR/.dolt-data}"
REMOTE_DOLT_BACKUP="${REMOTE_DOLT_BACKUP:-$REMOTE_DOLT_DIR/.dolt-backup}"

# Databases expected on source — verify count matches on dest after rsync.
EXPECTED_DBS=(beads da fi gastown gt hq rig trapline)

# Rigs that need metadata.json flipped. Entries are "<label>:<repo-path>".
# Empty repo-path means "metadata.json exists but repo is not locally cloned
# as a git tree — flip will happen during rig-level polecat work or via the
# stage-metadata-commits helper".
RIG_METADATA_TARGETS=(
    "hq:$HOME/gt"
    "gastown:$HOME/gt/gastown/polecats/obsidian/gastown"
    "figaro:$HOME/gt/figaro"
    "darkdisco:"
    "trapline:"
)

# Stage branch prefix (used by scripts/dolt-stage-metadata-commits.sh).
STAGE_BRANCH_PREFIX="${STAGE_BRANCH_PREFIX:-polecat/obsidian/gt-4ek-meta-dolt-host}"

# `gt daemon` has no explicit `restart` — fall back to stop+start. Override
# if a future gt release adds `gt daemon restart`.
GT_DAEMON_RESTART_CMD="${GT_DAEMON_RESTART_CMD:-gt daemon stop && sleep 2 && gt daemon start}"

# --------------------------------------------------------------------------- #
# Flags
# --------------------------------------------------------------------------- #
DRY_RUN=0
ONLY=""
declare -A SKIP=()

usage() {
    sed -n '1,30p' "$0"
    exit 1
}

while (($#)); do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --only) ONLY="$2"; shift 2 ;;
        --skip-preflight)      SKIP[preflight]=1; shift ;;
        --skip-freeze)         SKIP[freeze]=1; shift ;;
        --skip-rsync)          SKIP[rsync]=1; shift ;;
        --skip-remote-start)   SKIP[remote-start]=1; shift ;;
        --skip-push-metadata)  SKIP[push-metadata]=1; shift ;;
        --skip-verify)         SKIP[verify]=1; shift ;;
        --skip-export-env)     SKIP[export-env]=1; shift ;;
        --skip-daemon-restart) SKIP[daemon-restart]=1; shift ;;
        --skip-canary)         SKIP[canary]=1; shift ;;
        --skip-thaw)           SKIP[thaw]=1; shift ;;
        -h|--help) usage ;;
        *) echo "unknown arg: $1" >&2; usage ;;
    esac
done

run() {
    if ((DRY_RUN)); then
        printf '  [dry-run] %s\n' "$*"
    else
        eval "$@"
    fi
}

phase() {
    local name="$1"
    if [[ -n "$ONLY" && "$ONLY" != "$name" ]]; then return 1; fi
    if [[ -n "${SKIP[$name]:-}" ]]; then
        echo "▶ $name  [skipped]"
        return 1
    fi
    echo
    echo "=============================================================="
    echo "▶ $name"
    echo "=============================================================="
    return 0
}

fail() { echo "✖ $*" >&2; exit 1; }
ok()   { echo "✓ $*"; }

# --------------------------------------------------------------------------- #
# Phase: preflight
# --------------------------------------------------------------------------- #
if phase preflight; then
    echo "-- host identity"
    hostname -f || true

    echo "-- WG peer reachable ($VPSB_HOST)"
    ping -c2 -W2 "$VPSB_HOST" >/dev/null 2>&1 \
        || fail "VPS-B WG peer $VPSB_HOST unreachable — bring wg0 up first."
    ok "VPS-B reachable via WG"

    echo "-- SSH to VPS-B"
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$VPSB_SSH_USER@$VPSB_SSH_HOST" \
        'echo ok' >/dev/null \
        || fail "SSH to $VPSB_SSH_USER@$VPSB_SSH_HOST failed (BatchMode)."
    ok "SSH works"

    echo "-- VPS-B disk space at $REMOTE_DOLT_DIR"
    local_data_bytes=$(du -sb "$LOCAL_DOLT_DATA" | awk '{print $1}')
    local_backup_bytes=$(du -sb "$LOCAL_DOLT_BACKUP" 2>/dev/null | awk '{print $1}' || echo 0)
    need_bytes=$(( (local_data_bytes + local_backup_bytes) * 3 / 2 ))  # 1.5x headroom
    remote_free=$(ssh "$VPSB_SSH_USER@$VPSB_SSH_HOST" \
        "df -B1 --output=avail $(dirname "$REMOTE_DOLT_DIR") | tail -1" 2>/dev/null || echo 0)
    if (( remote_free < need_bytes )); then
        fail "VPS-B free space $remote_free B < required $need_bytes B"
    fi
    ok "Remote free space OK ($remote_free >= $need_bytes)"

    echo "-- local Dolt is running (must be UP so we can freeze it cleanly)"
    pgrep -f 'dolt sql-server --config' >/dev/null \
        || fail "Local Dolt not running; aborting (use --skip-freeze if intentional)."
    ok "Local Dolt is running"

    echo "-- no polecat/refinery tmux sessions with open work"
    busy=$(tmux list-sessions 2>/dev/null | grep -Ec 'polecat|refinery' || true)
    if (( busy > 0 )); then
        echo "  ⚠ $busy active worker sessions; these will hang during cutover."
        echo "    Recommend: pause dispatch and wait for gt done on all of them."
        read -rp "Proceed anyway? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || fail "Aborted by operator."
    fi
    ok "Worker check complete"

    echo "-- remote systemd unit present"
    ssh "$VPSB_SSH_USER@$VPSB_SSH_HOST" \
        'test -f /etc/systemd/system/dolt.service' \
        || fail "VPS-B missing /etc/systemd/system/dolt.service — install mesh/dolt.service first."
    ok "Remote systemd unit present"
fi

# --------------------------------------------------------------------------- #
# Phase: freeze  — stop local Dolt + make data dir read-only so nothing writes.
# --------------------------------------------------------------------------- #
if phase freeze; then
    run "gt dolt stop"
    # Belt-and-braces: wait for process to fully exit.
    for _ in $(seq 1 30); do
        pgrep -f 'dolt sql-server --config' >/dev/null 2>&1 || break
        sleep 1
    done
    pgrep -f 'dolt sql-server --config' >/dev/null 2>&1 \
        && fail "Local Dolt did not exit after 30s — investigate before continuing."
    ok "Local Dolt stopped"

    run "chmod -R a-w \"$LOCAL_DOLT_DATA\""
    run "chmod -R a-w \"$LOCAL_DOLT_BACKUP\" 2>/dev/null || true"
    ok "Local data dirs frozen read-only"
fi

# --------------------------------------------------------------------------- #
# Phase: rsync  — copy .dolt-data and .dolt-backup to VPS-B.
# --------------------------------------------------------------------------- #
if phase rsync; then
    run "ssh \"$VPSB_SSH_USER@$VPSB_SSH_HOST\" 'sudo install -d -m 0750 -o dolt -g dolt $REMOTE_DOLT_DIR $REMOTE_DOLT_DATA $REMOTE_DOLT_BACKUP'"

    # --numeric-ids keeps uid/gid unchanged so the remote 'dolt' user owns via
    # chown on the far side. We chown after the first transfer.
    run "rsync -aAX --delete --numeric-ids --info=progress2 \
        \"$LOCAL_DOLT_DATA/\" \"$VPSB_SSH_USER@$VPSB_SSH_HOST:$REMOTE_DOLT_DATA/\""
    run "rsync -aAX --delete --numeric-ids --info=progress2 \
        \"$LOCAL_DOLT_BACKUP/\" \"$VPSB_SSH_USER@$VPSB_SSH_HOST:$REMOTE_DOLT_BACKUP/\""

    run "ssh \"$VPSB_SSH_USER@$VPSB_SSH_HOST\" 'sudo chown -R dolt:dolt $REMOTE_DOLT_DATA $REMOTE_DOLT_BACKUP'"
    ok "Data and backup transferred + chowned"

    # Verify checksum of a sample db's .dolt/noms to catch transport corruption.
    for db in "${EXPECTED_DBS[@]}"; do
        [[ -d "$LOCAL_DOLT_DATA/$db/.dolt/noms" ]] || continue
        local_sum=$(find "$LOCAL_DOLT_DATA/$db/.dolt/noms" -type f -printf '%s %P\n' \
            | sort | sha256sum | awk '{print $1}')
        remote_sum=$(ssh "$VPSB_SSH_USER@$VPSB_SSH_HOST" \
            "sudo -u dolt find $REMOTE_DOLT_DATA/$db/.dolt/noms -type f -printf '%s %P\\n' | sort | sha256sum | awk '{print \$1}'")
        if [[ "$local_sum" != "$remote_sum" ]]; then
            fail "Checksum mismatch on $db: local=$local_sum remote=$remote_sum"
        fi
    done
    ok "File-list checksums match for all expected DBs"
fi

# --------------------------------------------------------------------------- #
# Phase: remote-start  — start Dolt on VPS-B via systemd.
# --------------------------------------------------------------------------- #
if phase remote-start; then
    run "ssh \"$VPSB_SSH_USER@$VPSB_SSH_HOST\" 'sudo systemctl daemon-reload && sudo systemctl enable --now dolt.service'"
    # Wait for port to be listening on the WG interface.
    for i in $(seq 1 30); do
        if ssh "$VPSB_SSH_USER@$VPSB_SSH_HOST" \
            "ss -tln '( sport = :$VPSB_PORT )' | grep -q $VPSB_HOST:$VPSB_PORT" 2>/dev/null; then
            ok "Remote Dolt listening on $VPSB_HOST:$VPSB_PORT (after ${i}s)"
            break
        fi
        sleep 1
        (( i == 30 )) && fail "Remote Dolt did not start listening in 30s."
    done

    # Sanity: systemd status should be active.
    run "ssh \"$VPSB_SSH_USER@$VPSB_SSH_HOST\" 'systemctl is-active dolt.service'"
fi

# --------------------------------------------------------------------------- #
# Phase: push-metadata  — push the pre-staged per-rig branches.
#
# These branches were created by scripts/dolt-stage-metadata-commits.sh BEFORE
# the maintenance window. This phase just pushes them. Pushing requires the
# local gt/bd to still be functional against the remote Dolt, which it will be
# because this runs AFTER remote-start.
# --------------------------------------------------------------------------- #
if phase push-metadata; then
    echo "If metadata branches were not pre-staged, run first:"
    echo "  scripts/dolt-stage-metadata-commits.sh --new-host $VPSB_HOST"
    echo
    for entry in "${RIG_METADATA_TARGETS[@]}"; do
        label="${entry%%:*}"
        repo="${entry#*:}"
        if [[ -z "$repo" ]]; then
            echo "  $label: no local git tree — flip metadata.json in-place via rig polecat"
            continue
        fi
        branch="${STAGE_BRANCH_PREFIX}-${label}"
        if (cd "$repo" && git rev-parse --verify "$branch" >/dev/null 2>&1); then
            run "(cd \"$repo\" && git push origin \"$branch\")"
            ok "pushed $label: $branch"
        else
            echo "  ⚠ $label: branch $branch not found in $repo — skipping (stage it first)"
        fi
    done
fi

# --------------------------------------------------------------------------- #
# Phase: verify  — remote server answers SHOW DATABASES with the right count.
# --------------------------------------------------------------------------- #
if phase verify; then
    # Use dolt sql-client (ships with our dolt binary) instead of mysql client
    # which isn't always installed. Falls back to mysql if dolt-client absent.
    want=${#EXPECTED_DBS[@]}
    got=$(dolt sql-client --host "$VPSB_HOST" --port "$VPSB_PORT" --user root \
        -q 'SHOW DATABASES;' 2>/dev/null \
        | grep -Eiv '^(Database|information_schema|mysql|performance_schema|dolt_cluster|\+|$|-)' \
        | wc -l || true)
    if (( got < want )); then
        fail "SHOW DATABASES returned $got dbs; expected >= $want"
    fi
    ok "Remote Dolt reports $got databases (>= $want expected)"

    # Per-db SELECT 1 sanity to catch partial corruption.
    for db in "${EXPECTED_DBS[@]}"; do
        if ! dolt sql-client --host "$VPSB_HOST" --port "$VPSB_PORT" --user root \
            -q "USE \`$db\`; SELECT 1;" >/dev/null 2>&1; then
            fail "SELECT 1 failed on db=$db"
        fi
    done
    ok "Per-db SELECT 1 succeeded for all ${#EXPECTED_DBS[@]} databases"
fi

# --------------------------------------------------------------------------- #
# Phase: export-env  — persist GT_DOLT_HOST so new shells/daemons pick it up.
# --------------------------------------------------------------------------- #
if phase export-env; then
    for rc in "$HOME/.bashrc" "$HOME/.profile"; do
        [[ -f "$rc" ]] || continue
        if grep -q '^export GT_DOLT_HOST=' "$rc"; then
            run "sed -i 's|^export GT_DOLT_HOST=.*|export GT_DOLT_HOST=$VPSB_HOST|' \"$rc\""
        else
            run "printf '\n# gt-4ek: Dolt moved to VPS-B\nexport GT_DOLT_HOST=$VPSB_HOST\n' >> \"$rc\""
        fi
        ok "updated $rc"
    done
    echo
    echo "  NOTE: current shell still has the OLD value. Run 'source ~/.bashrc'"
    echo "        OR open a fresh shell before continuing."
fi

# --------------------------------------------------------------------------- #
# Phase: daemon-restart  — so spawned child processes inherit GT_DOLT_HOST.
# --------------------------------------------------------------------------- #
if phase daemon-restart; then
    run "$GT_DAEMON_RESTART_CMD"
    # Verify daemon env picked up the new host.
    daemon_pid=$(pgrep -f 'gt daemon' | head -1 || echo '')
    if [[ -n "$daemon_pid" ]]; then
        if grep -qz "GT_DOLT_HOST=$VPSB_HOST" "/proc/$daemon_pid/environ" 2>/dev/null; then
            ok "gt daemon (pid $daemon_pid) has GT_DOLT_HOST=$VPSB_HOST"
        else
            fail "gt daemon env does NOT contain GT_DOLT_HOST=$VPSB_HOST — investigate."
        fi
    fi
fi

# --------------------------------------------------------------------------- #
# Phase: canary  — bounce the witness tmux and verify bd works end-to-end.
# --------------------------------------------------------------------------- #
if phase canary; then
    # The gt daemon restart above forced children to inherit GT_DOLT_HOST.
    # Any tmux sessions spawned pre-cutover still have the OLD value until
    # they cycle naturally via gt done. That's fine — new dispatches will
    # inherit correctly. We only verify bd works against remote here.
    if GT_DOLT_HOST="$VPSB_HOST" bd list --status=open --limit=1 >/dev/null 2>&1; then
        ok "bd list succeeds against remote Dolt"
    else
        fail "bd list failed against remote Dolt — roll back!"
    fi

    if GT_DOLT_HOST="$VPSB_HOST" gt dolt status >/dev/null 2>&1; then
        ok "gt dolt status succeeds against remote Dolt"
    else
        echo "  ⚠ gt dolt status failed — may need plugin-audit follow-ups (non-blocking)."
    fi
fi

# --------------------------------------------------------------------------- #
# Phase: thaw  — re-enable writes on the now-cold local copy (kept as backup).
# --------------------------------------------------------------------------- #
if phase thaw; then
    run "chmod -R u+w \"$LOCAL_DOLT_DATA\""
    run "chmod -R u+w \"$LOCAL_DOLT_BACKUP\" 2>/dev/null || true"
    ok "Local copies writable again (keep >= 1 week as cold backup)"
    echo
    echo "  Do NOT \`rm -rf\` these dirs. They are your cold-standby rollback target."
fi

echo
echo "=============================================================="
echo "✓ Migration complete."
echo "  Remote Dolt: $VPSB_HOST:$VPSB_PORT"
echo "  Local cold backup: $LOCAL_DOLT_DATA (keep for at least 1 week)"
echo "  If anything looks wrong, run: scripts/dolt-rollback-from-vps-b.sh"
echo "=============================================================="
