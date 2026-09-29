#!/usr/bin/env bash
# stuck-agent-dog/run.sh — Context-aware stuck/crashed agent detection.
#
# SCOPE: Only polecats and deacon. NEVER touches crew, mayor, witness, or refinery.
# The daemon detects; this plugin inspects context before acting.

set -euo pipefail

TOWN_ROOT="${GT_TOWN_ROOT:-$(gt town root 2>/dev/null)}"
RIGS_JSON_PATH="${TOWN_ROOT}/mayor/rigs.json"

log() { echo "[stuck-agent-dog] $*"; }

heartbeat_epoch() {
  local file="$1"
  local ts=""

  ts=$(jq -r '(.timestamp // empty) | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // empty' "$file" 2>/dev/null || true)
  if [ -n "$ts" ]; then
    echo "$ts"
    return 0
  fi

  # Fallback for malformed legacy files: use mtime rather than failing open.
  stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null
}

has_in_progress_work() {
  local locations=("$TOWN_ROOT")
  local rig=""
  local prefix=""
  local loc=""
  local output=""
  local count=""

  while IFS='|' read -r rig prefix; do
    [ -z "$rig" ] && continue
    [ -d "$TOWN_ROOT/$rig" ] && locations+=("$TOWN_ROOT/$rig")
  done <<< "$RIG_PREFIX_MAP"

  for loc in "${locations[@]}"; do
    output=$(cd "$loc" && bd list --status=in_progress --json --limit=1 2>/dev/null) || return 0
    count=$(printf '%s' "$output" | jq 'length' 2>/dev/null || echo 1)
    if [ "${count:-1}" -gt 0 ]; then
      return 0
    fi
  done

  return 1
}

# 2nd witness for the deacon stale-heartbeat check. The heartbeat file is written
# only at turn boundaries, so a Deacon in a long turn legitimately goes >20m
# without a beat while actively working. A freshly-written transcript proves it
# is progressing, not hung — which heartbeat age + has_in_progress_work alone
# cannot tell apart (both read "possibly stuck"). Fresh transcript => alive, skip;
# stale transcript AND stale heartbeat => escalate. (tr: killed a wave of false
# stuck_heartbeat escalations on a live, mid-turn Deacon burning 63% CPU.)
deacon_transcript_fresh() {
  local dir latest age
  dir=$(ls -dt "$HOME"/.claude/projects/*deacon 2>/dev/null | grep -viE 'dog|boot' | head -1)
  [ -n "$dir" ] || return 1
  latest=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1)
  [ -n "$latest" ] || return 1
  age=$(( $(date +%s) - $(stat -c %Y "$latest" 2>/dev/null || echo 0) ))
  [ "$age" -lt "${DEACON_TRANSCRIPT_FRESH_S:-900}" ]
}

# Ground-truth Dolt liveness, bypassing the gt/bd client layer. `gt dolt status`,
# `gt hook show` and `bd` all time out under load (bd-hydration N+1) while the
# server itself answers instantly — so a client timeout is NOT a server outage.
# A direct `select 1` on the SQL port is the only signal that distinguishes a
# real Dolt problem from client-side slowness. Escalations that blame Dolt for a
# gt/bd timeout MUST be gated on this returning non-zero. (tr: killed a wave of
# false "Dolt unresponsive / server under load-saturation" escalations.)
dolt_server_healthy() {
  timeout 10 dolt --host "${GT_DOLT_HOST:-127.0.0.1}" --port "${GT_DOLT_PORT:-3307}" \
    --user root --no-tls -p '' sql -q "select 1 as ok" 2>/dev/null | grep -q '\b1\b'
}

# --- Enumerate agents ---------------------------------------------------------

log "=== Checking agent health ==="

if [ ! -f "$RIGS_JSON_PATH" ]; then
  log "SKIP: rigs.json not found"
  exit 0
fi

# Build rig_name|prefix mapping
RIG_PREFIX_MAP=$(jq -r '.rigs | to_entries[] | "\(.key)|\(.value.beads.prefix // .key)"' "$RIGS_JSON_PATH" 2>/dev/null)
if [ -z "$RIG_PREFIX_MAP" ]; then
  log "SKIP: no rigs in rigs.json"
  exit 0
fi

# --- Check polecat health ----------------------------------------------------

CRASHED=()
STUCK=()
HEALTHY=0

while IFS='|' read -r RIG PREFIX; do
  [ -z "$RIG" ] && continue
  POLECAT_DIR="$TOWN_ROOT/$RIG/polecats"
  [ -d "$POLECAT_DIR" ] || continue

  for PCAT_PATH in "$POLECAT_DIR"/*/; do
    [ -d "$PCAT_PATH" ] || continue
    PCAT_NAME=$(basename "$PCAT_PATH")
    SESSION_NAME="${PREFIX}-${PCAT_NAME}"

    if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
      # Session dead — check hook
      HOOK_OUTPUT=$(gt hook show "$RIG/polecats/$PCAT_NAME" 2>/dev/null | head -1)
      HOOK_BEAD=$(echo "$HOOK_OUTPUT" | grep -v '(empty)' | awk '{print $2}' || true)

      if [ -n "$HOOK_BEAD" ]; then
        # Check agent_state
        AGENT_STATE=$(bd show "$HOOK_BEAD" --json 2>/dev/null \
          | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0].get('status',''))" 2>/dev/null || echo "")

        case "$AGENT_STATE" in
          closed) log "  SKIP $SESSION_NAME: bead closed (completed normally)"; continue ;;
        esac

        CRASHED+=("$SESSION_NAME|$RIG|$PCAT_NAME|$HOOK_BEAD")
        log "  CRASHED: $SESSION_NAME (hook=$HOOK_BEAD)"
      fi
    else
      # Session alive — check process
      PANE_PID=$(tmux list-panes -t "$SESSION_NAME" -F '#{pane_pid}' 2>/dev/null | head -1)
      if [ -n "$PANE_PID" ]; then
        PROC_COMM=$(ps -o comm= -p "$PANE_PID" 2>/dev/null)
        if [ -z "$PROC_COMM" ]; then
          # Zombie: process dead, session alive
          HOOK_OUTPUT=$(gt hook show "$RIG/polecats/$PCAT_NAME" 2>/dev/null | head -1)
          HOOK_BEAD=$(echo "$HOOK_OUTPUT" | grep -v '(empty)' | awk '{print $2}' || true)
          if [ -n "$HOOK_BEAD" ]; then
            STUCK+=("$SESSION_NAME|$RIG|$PCAT_NAME|$HOOK_BEAD|agent_dead")
            log "  ZOMBIE: $SESSION_NAME (pid=$PANE_PID dead, hook=$HOOK_BEAD)"
          fi
        else
          HEALTHY=$((HEALTHY + 1))
        fi
      else
        HEALTHY=$((HEALTHY + 1))
      fi
    fi
  done
done <<< "$RIG_PREFIX_MAP"

log ""
log "Polecat health: ${#CRASHED[@]} crashed, ${#STUCK[@]} stuck, $HEALTHY healthy"

# --- Check deacon health -----------------------------------------------------

log ""
log "=== Deacon Health ==="

DEACON_SESSION="hq-deacon"
DEACON_ISSUE=""
DEACON_PROCESS_ALIVE=0

if ! tmux has-session -t "$DEACON_SESSION" 2>/dev/null; then
  log "  CRASHED: Deacon session is dead"
  DEACON_ISSUE="crashed"
else
  DEACON_PID=$(tmux list-panes -t "$DEACON_SESSION" -F '#{pane_pid}' 2>/dev/null | head -1)
  DEACON_COMM=$(ps -o comm= -p "$DEACON_PID" 2>/dev/null)
  if [ -z "$DEACON_COMM" ]; then
    log "  ZOMBIE: Deacon process dead (pid=$DEACON_PID), session alive"
    DEACON_ISSUE="zombie"
  else
    log "  Process alive: pid=$DEACON_PID comm=$DEACON_COMM"
    DEACON_PROCESS_ALIVE=1
  fi

  HEARTBEAT_FILE="$TOWN_ROOT/deacon/heartbeat.json"
  if [ -z "$DEACON_ISSUE" ] && [ -f "$HEARTBEAT_FILE" ]; then
    HEARTBEAT_TIME=$(heartbeat_epoch "$HEARTBEAT_FILE" || true)
    NOW=$(date +%s)
    HEARTBEAT_AGE=$(( NOW - ${HEARTBEAT_TIME:-0} ))

    if [ "$HEARTBEAT_AGE" -gt 1200 ]; then
      if [ "$DEACON_PROCESS_ALIVE" -eq 1 ] && { ! has_in_progress_work || deacon_transcript_fresh; }; then
        log "  SKIP: Deacon heartbeat stale (${HEARTBEAT_AGE}s old) but process is alive and either idle or transcript is fresh (actively working, not hung)"
      else
        log "  STUCK: Deacon heartbeat stale (${HEARTBEAT_AGE}s old, >20m) AND transcript also stale — genuinely hung"
        DEACON_ISSUE="stuck_heartbeat_${HEARTBEAT_AGE}s"
      fi
    else
      log "  OK: Deacon heartbeat ${HEARTBEAT_AGE}s old"
    fi
  fi
fi

# --- Mass death check ---------------------------------------------------------

TOTAL_ISSUES=$(( ${#CRASHED[@]} + ${#STUCK[@]} ))
if [ "$TOTAL_ISSUES" -ge 3 ]; then
  # A "mass death" under load is usually a mirage: gt hook show / bd time out
  # (bd-hydration N+1), so live agents read as crashed/stuck. Confirm against
  # ground truth before crying Dolt outage — if the SQL server answers a direct
  # select, the timeouts are client-side and these are not real deaths.
  if dolt_server_healthy; then
    log ""
    log "MASS DEATH SUPPRESSED: $TOTAL_ISSUES agents read as down, but Dolt server answers a direct query — treating as client-side gt/bd slowness under load, not a real outage. Not escalating."
  else
    log ""
    log "MASS DEATH: $TOTAL_ISSUES agents down AND Dolt server does not answer a direct query — escalating instead of restarting"
    gt escalate "Mass agent death: $TOTAL_ISSUES agents down (Dolt SQL server unreachable on direct query)" \
      -s CRITICAL 2>/dev/null || true
  fi
fi

# --- Take action --------------------------------------------------------------

# Crashed polecats: notify witness to restart
# Note: `"${arr[@]:-}"` expands an empty array to a single empty string under
# `set -u`, which would fire a phantom `RESTART_POLECAT: /` notification. The
# `${arr[@]+"${arr[@]}"}` form expands to nothing when the array is empty.
for ENTRY in ${CRASHED[@]+"${CRASHED[@]}"}; do
  IFS='|' read -r SESSION RIG PCAT HOOK <<< "$ENTRY"
  log "Requesting restart for $RIG/polecats/$PCAT (hook=$HOOK)"
  gt mail send "$RIG/witness" -s "RESTART_POLECAT: $RIG/$PCAT" --stdin <<BODY
Polecat $PCAT crash confirmed by stuck-agent-dog plugin.
hook_bead: $HOOK
action: restart requested
BODY
done

# Zombie polecats: kill zombie session, then request restart
for ENTRY in ${STUCK[@]+"${STUCK[@]}"}; do
  IFS='|' read -r SESSION RIG PCAT HOOK REASON <<< "$ENTRY"
  log "Killing zombie session $SESSION and requesting restart"
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  gt mail send "$RIG/witness" -s "RESTART_POLECAT: $RIG/$PCAT (zombie cleared)" --stdin <<BODY
Polecat $PCAT zombie session cleared by stuck-agent-dog plugin.
hook_bead: $HOOK
reason: $REASON
action: restart requested
BODY
done

# Deacon issues: escalate
if [ -n "$DEACON_ISSUE" ]; then
	log "Escalating deacon issue: $DEACON_ISSUE"
	DEACON_SEVERITY="HIGH"
	DEACON_FINGERPRINT="stuck-agent-dog:deacon:$DEACON_ISSUE"
	case "$DEACON_ISSUE" in
		stuck_heartbeat_*)
			DEACON_SEVERITY="MEDIUM"
			DEACON_FINGERPRINT="stuck-agent-dog:deacon:stuck-heartbeat"
			;;
	esac
	gt escalate "Deacon $DEACON_ISSUE detected by stuck-agent-dog" \
		-s "$DEACON_SEVERITY" \
		--source "plugin:stuck-agent-dog" \
		--fingerprint "$DEACON_FINGERPRINT" 2>/dev/null || true
fi

# --- Report -------------------------------------------------------------------

SUMMARY="Agent health: ${#CRASHED[@]} crashed, ${#STUCK[@]} stuck, $HEALTHY healthy"
[ -n "$DEACON_ISSUE" ] && SUMMARY="$SUMMARY, deacon=$DEACON_ISSUE"
log ""
log "=== $SUMMARY ==="

bd create "stuck-agent-dog: $SUMMARY" -t chore --ephemeral \
  -l type:plugin-run,plugin:stuck-agent-dog,result:success \
  -d "$SUMMARY" --silent 2>/dev/null || true
