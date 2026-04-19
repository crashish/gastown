#!/usr/bin/env bash
# dolt-stage-metadata-commits.sh — Create (but do NOT push) per-rig branches
# that flip `dolt_server_host` in each rig's .beads/metadata.json.
#
# Run this BEFORE the cutover window while Dolt is still up and shells still
# have working `bd`. The branches are pushed by the migrate runbook during
# the 'push-metadata' phase.
#
# Usage:
#   scripts/dolt-stage-metadata-commits.sh --new-host 10.10.0.3
#   scripts/dolt-stage-metadata-commits.sh --new-host 10.10.0.3 --dry-run
#
# Rigs are discovered from /home/crash/gt/rigs.json; the town ('hq') is always
# added. Any rig whose root dir is not a git tree is skipped with a warning —
# for those, the metadata flip happens in-place during the cutover via the
# rig-specific polecat (or manual edit), documented in docs/dolt-on-vps-b.md.

set -euo pipefail

NEW_HOST=""
NEW_PORT="3307"
OLD_HOST_DEFAULT="127.0.0.1"
DRY_RUN=0
BRANCH_PREFIX="${STAGE_BRANCH_PREFIX:-polecat/obsidian/gt-4ek-meta-dolt-host}"
TOWN_ROOT="${GT_ROOT:-$HOME/gt}"
RIGS_JSON="$TOWN_ROOT/rigs.json"

usage() {
    sed -n '1,20p' "$0"
    exit 1
}

while (($#)); do
    case "$1" in
        --new-host) NEW_HOST="$2"; shift 2 ;;
        --new-port) NEW_PORT="$2"; shift 2 ;;
        --prefix)   BRANCH_PREFIX="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=1; shift ;;
        -h|--help)  usage ;;
        *) echo "unknown arg: $1" >&2; usage ;;
    esac
done

[[ -n "$NEW_HOST" ]] || { echo "--new-host required" >&2; usage; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }

run() {
    if ((DRY_RUN)); then
        printf '  [dry-run] %s\n' "$*"
    else
        eval "$@"
    fi
}

stage_one() {
    local label="$1" repo="$2"
    local branch="${BRANCH_PREFIX}-${label}"
    local metadata="$repo/.beads/metadata.json"

    echo
    echo "── $label ($repo)"
    if [[ ! -d "$repo/.git" ]]; then
        echo "  ⚠ not a git tree — skipping. Edit $metadata in-place at cutover."
        return 0
    fi
    if [[ ! -f "$metadata" ]]; then
        echo "  ⚠ $metadata missing — skipping."
        return 0
    fi

    # Read current host so we can report the diff.
    current=$(jq -r '.dolt_server_host // ""' "$metadata")
    if [[ "$current" == "$NEW_HOST" ]]; then
        echo "  ✓ already set to $NEW_HOST; nothing to stage."
        return 0
    fi

    # Branch from main (or master, whichever exists).
    (
        cd "$repo"
        # Capture current ref so we can check it out again after staging.
        start_ref=$(git rev-parse --abbrev-ref HEAD)
        base=main
        git show-ref --verify --quiet refs/heads/main || base=master
        run "git fetch --quiet origin $base || true"

        if git rev-parse --verify "$branch" >/dev/null 2>&1; then
            echo "  ⚠ branch $branch already exists — leaving untouched."
            return 0
        fi

        run "git checkout -q -b \"$branch\" \"origin/$base\""

        # jq with -S sorts keys; we keep insertion order via --argjson.
        tmp=$(mktemp)
        jq --arg h "$NEW_HOST" --argjson p "$NEW_PORT" \
            '.dolt_server_host = $h | .dolt_server_port = $p' \
            "$metadata" > "$tmp"
        if ((DRY_RUN)); then
            diff -u "$metadata" "$tmp" || true
            rm -f "$tmp"
        else
            mv "$tmp" "$metadata"
        fi

        run "git add .beads/metadata.json"
        run "git commit -q -m 'chore(dolt): flip $label dolt_server_host to $NEW_HOST (gt-4ek)'"
        run "git checkout -q \"$start_ref\""
        echo "  ✓ staged $branch"
    )
}

# --- discover rigs --------------------------------------------------------- #
declare -a TARGETS=()

# HQ / town root — always included.
TARGETS+=("hq:$TOWN_ROOT")

# This-repo gastown worktree — the committing polecat lives here.
# Stage a branch in the current worktree (we're IN it) so metadata flip flows
# through the same merge queue as the runbook itself.
TARGETS+=("gastown:$PWD")

# Figaro + any other locally-cloned rigs from rigs.json.
if [[ -f "$RIGS_JSON" ]]; then
    while read -r label; do
        [[ -z "$label" || "$label" == "gastown" ]] && continue
        rig_root="$TOWN_ROOT/$label"
        TARGETS+=("$label:$rig_root")
    done < <(jq -r '.rigs | keys[]' "$RIGS_JSON")
fi

for entry in "${TARGETS[@]}"; do
    label="${entry%%:*}"
    repo="${entry#*:}"
    stage_one "$label" "$repo"
done

echo
echo "Done. Pre-staged branches (if any) are ready for the migrate runbook's"
echo "push-metadata phase. Inspect with:"
echo "  git -C <repo> log --oneline \"${BRANCH_PREFIX}-<label>\" -1"
