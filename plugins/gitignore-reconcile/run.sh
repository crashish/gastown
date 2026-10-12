#!/usr/bin/env bash
# gitignore-reconcile/run.sh — REPORT tracked files now matched by .gitignore
#
# Scans all rig repos for tracked files that match an active .gitignore rule and
# reports them as a chore bead. ADVISORY ONLY (2026-10-12): it does not untrack,
# commit, or push — that auto-mutation of rig repos was removed. A human untracks
# intentionally. Also fixed: rig-repo path resolution (was resolving under the
# plugin dir and silently no-op'ing while reporting success).

set -euo pipefail

log() { echo "[gitignore-reconcile] $*"; }

# --- Step 1: Enumerate rig repos ---------------------------------------------

# Get rig names from gt rig list
RIG_JSON=$(gt rig list --json 2>/dev/null || true)
if [ -z "$RIG_JSON" ]; then
  log "SKIP: could not get rig list"
  exit 0
fi

RIG_NAMES=$(echo "$RIG_JSON" | jq -r '.[].name' 2>/dev/null || true)
if [ -z "$RIG_NAMES" ]; then
  log "SKIP: no rigs found"
  exit 0
fi

# Find the town root. GT_TOWN_ROOT is the source of truth (same as the other
# plugins use); `gt prime --field workspace` returns empty in plugin context and
# the old `|| pwd` fallback resolved rig paths under the PLUGIN directory, so
# every repo SKIPped as "not a git repo" while the run still reported success.
WORKSPACE_ROOT="${GT_TOWN_ROOT:-$(gt town root 2>/dev/null)}"
[ -d "$WORKSPACE_ROOT" ] || WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# A rig's git repo is not at <root>/<rig> — it lives at <root>/<rig>/mayor/rig
# in this town (darkdisco, trapline, gastown all do). Probe both layouts and
# take the first that is actually a git repo, so a layout change can't silently
# make this a no-op again.
RIG_PATHS=""
while IFS= read -r RIG_NAME; do
  [ -z "$RIG_NAME" ] && continue
  for CAND in "$WORKSPACE_ROOT/$RIG_NAME/mayor/rig" "$WORKSPACE_ROOT/$RIG_NAME"; do
    if git -C "$CAND" rev-parse --git-dir >/dev/null 2>&1; then
      RIG_PATHS="${RIG_PATHS:+$RIG_PATHS$'\n'}$CAND"
      break
    fi
  done
done <<< "$RIG_NAMES"

if [ -z "$RIG_PATHS" ]; then
  log "SKIP: no rig paths could be resolved"
  exit 0
fi

RIG_COUNT=$(echo "$RIG_PATHS" | wc -l | tr -d ' ')
log "Checking $RIG_COUNT rig repo(s) for tracked+ignored files"

# --- Step 2: Process each rig -----------------------------------------------

TOTAL_UNTRACKED=0
TOTAL_BEADS=0

while IFS= read -r REPO_PATH; do
  [ -z "$REPO_PATH" ] && continue

  if ! git -C "$REPO_PATH" rev-parse --git-dir >/dev/null 2>&1; then
    log "SKIP: $REPO_PATH — not a git repo"
    continue
  fi

  log ""
  log "=== $REPO_PATH ==="

  IGNORED_TRACKED=$(git -C "$REPO_PATH" ls-files --ignored --exclude-standard --cached 2>/dev/null || true)
  if [ -z "$IGNORED_TRACKED" ]; then
    log "  Clean"
    continue
  fi

  FILE_COUNT=$(echo "$IGNORED_TRACKED" | wc -l | tr -d ' ')
  log "  Found $FILE_COUNT tracked+ignored file(s)"

  # REPORT-ONLY (2026-10-12): this plugin used to `git rm --cached` + commit +
  # `git push origin main` against each rig repo automatically. That is a real
  # mutation of the rig repos — and gastown's origin is not writable from here —
  # so it is now ADVISORY: it reports the tracked+ignored files as a chore bead
  # and leaves the untracking to a human. Re-enabling auto-untrack is a
  # deliberate decision, not something a janitorial patrol should do unattended.
  REPO_NAME=$(basename "$REPO_PATH")
  CURRENT_BRANCH=$(git -C "$REPO_PATH" branch --show-current 2>/dev/null || true)
  log "  Reporting $FILE_COUNT tracked+ignored file(s) on ${CURRENT_BRANCH:-?} (advisory — no changes made)"
  bd create "gitignore-reconcile: $REPO_NAME has $FILE_COUNT tracked+ignored file(s)" \
    -t chore \
    -l "plugin:gitignore-reconcile,category:git-hygiene" \
    -d "$(printf 'Repo: %s\nBranch: %s\nThese tracked files now match .gitignore. Untrack manually if intended: git -C %s rm --cached <file>\n\n%s' "$REPO_PATH" "${CURRENT_BRANCH:-?}" "$REPO_PATH" "$(echo "$IGNORED_TRACKED" | head -40)")" \
    --silent 2>/dev/null || true
  TOTAL_BEADS=$((TOTAL_BEADS + 1))
done <<< "$RIG_PATHS"

# --- Report ------------------------------------------------------------------

log ""
log "=== Summary ==="
SUMMARY="gitignore-reconcile: $TOTAL_UNTRACKED file(s) untracked, $TOTAL_BEADS chore bead(s) created"
log "$SUMMARY"

bd create "$SUMMARY" -t chore --ephemeral \
  -l "type:plugin-run,plugin:gitignore-reconcile,result:success" \
  -d "$SUMMARY" --silent 2>/dev/null || true

log "Done."
