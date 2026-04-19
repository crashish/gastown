# Dolt migration — plugin & CLI audit (gt-4ek)

This audit answers: for each Dolt-adjacent plugin and `gt dolt` subcommand,
does it work the same way after Dolt moves from local host to VPS-B
(`10.10.0.3:3307`)? Where it breaks, note whether the fix is "move the plugin
to VPS-B", "fix the code", or "document a new invocation pattern".

Scope is Phase 1 only: Dolt server on VPS-B, everything else (gt/bd binaries,
tmux sessions) stays local. Anything that requires `/opt/gastown/.dolt-data`
on the Dolt host is affected.

Terminology:

- **Host-bound** — must run on the same machine as the Dolt data dir because
  it reads/writes `.dolt-data/` directly (filesystem access, not SQL).
- **Client-side** — only talks to Dolt over the SQL port; can run anywhere
  that can reach `10.10.0.3:3307`.

## Summary

| Plugin / command | Side | Post-migration status | Action |
|------------------|------|-----------------------|--------|
| `plugins/dolt-snapshots/` | Host-bound | **Broken** as-is | Move schedule to VPS-B or rework to use SQL |
| `plugins/dolt-log-rotate/` | Host-bound | **Broken** as-is | Move schedule to VPS-B |
| `plugins/dolt-backup/` | Host-bound | **Broken** as-is | Move schedule to VPS-B |
| `plugins/dolt-archive/` | Host-bound | **Broken** as-is | Move schedule to VPS-B |
| `plugins/compactor-dog/` | Host-bound | **Broken** as-is | Move schedule to VPS-B (file follow-up bead) |
| `gt dolt start` | Host-bound | No-op locally | Document; mayor escalates if invoked |
| `gt dolt stop` | Host-bound | No-op locally | Document; rollback script uses `ssh … systemctl` instead |
| `gt dolt restart` | Host-bound | No-op locally | Document |
| `gt dolt kill-imposters` | Host-bound | No-op locally | Document (not relevant remotely anyway) |
| `gt dolt status` | Client-side | Works | Verify in canary |
| `gt dolt logs` | Host-bound | **Broken** | `ssh VPS-B sudo journalctl -u dolt -f` instead |
| `gt dolt dump` | Host-bound | **Dangerous locally** (SIGQUITs stray PID), **broken** remotely | ⚠ Make it fail fast. File follow-up bead. |
| `gt dolt sql` | Client-side | Works | No change |
| `gt dolt cleanup` | Client-side | Works | Verify — runs DROP DATABASE via SQL |
| `bd` CLI (all rigs) | Client-side | Works | Requires `GT_DOLT_HOST=10.10.0.3` in env |
| Dolt server itself | Host-bound | Runs on VPS-B | Managed by `mesh/dolt.service` |

"Broken as-is" does not mean catastrophic — it means invoking the command on
the *local* host no longer touches the real Dolt. For most plugins, that's a
silent no-op (they operate on a `.dolt-data/` dir that still exists as a cold
backup). The fix is to schedule them on VPS-B going forward.

## Per-plugin findings

### `plugins/dolt-snapshots/`

- **What it does:** walks `.dolt-data/<db>/.dolt/noms`, hardlinks pack files
  into timestamped snapshot dirs for cheap restore points.
- **Host dependency:** reads `.dolt-data` via the filesystem. No SQL calls.
- **Post-migration state:** runs locally → walks the stale cold-backup copy.
  Output is meaningless until the schedule is moved to VPS-B.
- **Fix:** install + schedule this plugin on VPS-B. The binary is Go, so it
  cross-compiles clean; deploy via the same path the migrate runbook uses for
  the dolt binary. Until that happens, disable the local schedule so we don't
  generate misleading snapshots of a frozen tree.
- **Flag discovered:** `main.go:50` already accepts `--host` and defaults to
  `127.0.0.1` via `main.go:118`. So the *SQL-using* paths in this plugin
  (if any) are already remote-ready; only the filesystem walker is stuck.

### `plugins/dolt-log-rotate/`

- **What it does:** rotates `daemon/dolt.log` on size threshold, keeps N gzip
  backups.
- **Host dependency:** reads + truncates a file path under `${GT_TOWN_ROOT}/daemon/dolt.log`.
- **Post-migration state:** after migration, Dolt writes to journald on VPS-B,
  not `/home/crash/gt/daemon/dolt.log`. The plugin will keep rotating an empty
  stale file.
- **Fix (short-term):** disable the local schedule for this plugin. The new
  systemd unit on VPS-B delegates log rotation to journald's built-in cap
  (`MaxFileSec`, `SystemMaxUse`) — no plugin needed. Document in
  `docs/dolt-on-vps-b.md`.
- **Follow-up bead needed?** Yes: "Remove dolt-log-rotate from the local
  schedule once migration lands; keep code for rollback."

### `plugins/dolt-backup/`

- **What it does:** per-database `dolt backup sync <db>-backup` into
  `$HOME/gt/.dolt-backup/`. Tracks HEAD hash to skip unchanged DBs.
- **Host dependency:** calls `dolt log` + `dolt backup sync` with `cwd` = the
  per-db directory under `.dolt-data/`. Requires filesystem access to both
  `.dolt-data` and `.dolt-backup`.
- **Post-migration state:** local run sees a frozen `.dolt-data`; hashes never
  change; every run silently "skips all dbs". No real backups produced.
- **Fix:** install on VPS-B, schedule via systemd timer on the Dolt host. The
  script is bash + `dolt` CLI + `bd create` — `bd` needs `GT_DOLT_HOST=127.0.0.1`
  on VPS-B (i.e., talk to the local Dolt), or we need a `bd` deployment on
  VPS-B. Simpler alternative: run the backup as a plain script (no `bd create`
  telemetry) and file the summary bead from the local host on a cron.

### `plugins/dolt-archive/`

- **What it does:** calls `dolt archive` against each db to compact chunk
  files into archive format.
- **Host dependency:** same as dolt-backup — cwd into each db dir.
- **Post-migration state:** same failure mode; local runs are no-ops on stale
  data.
- **Fix:** move to VPS-B schedule.

### `plugins/compactor-dog/`

- Also touches `.dolt-data/<db>` directly (per the grep hit). Same story.
  Move to VPS-B schedule.

## Per-command findings (`gt dolt …`)

Source: `internal/cmd/dolt.go`, `internal/doltserver/doltserver.go`.

### `gt dolt start` / `stop` / `restart` / `kill-imposters`

- **Lifecycle commands — all host-bound.** They `exec dolt sql-server` /
  read PID files / kill local PIDs. After migration, Dolt doesn't run locally;
  these commands will either hang (trying to start a server on a port that's
  advertised as remote) or appear to succeed while doing nothing useful.
- **Recommendation:** make them detect `GT_DOLT_HOST != 127.0.0.1 && != localhost`
  and refuse with a clear error, something like:
  > Dolt is configured to run on $GT_DOLT_HOST:$GT_DOLT_PORT.
  > Use `ssh $GT_DOLT_HOST sudo systemctl {start,stop,restart} dolt.service`
  > instead. See docs/dolt-on-vps-b.md.
- **Follow-up bead:** yes. File as a Phase-1 polish item; not blocking because
  the runbook uses `ssh systemctl` directly.

### `gt dolt status`

- Connects via Dolt SQL client to `GT_DOLT_HOST:GT_DOLT_PORT` and issues
  status queries. **Client-side; works remote.**
- Canary step in the runbook verifies this.

### `gt dolt logs`

- Reads `/home/crash/gt/daemon/dolt.log`. **Host-bound; broken after migration.**
- After migration the authoritative log is VPS-B journald.
- **Fix:** either teach `gt dolt logs` to ssh to VPS-B and run `journalctl`,
  or document the new incantation. Short-term: document. File a polish bead.

### `gt dolt dump`

- Sends SIGQUIT to the *local* Dolt PID. **⚠ Two problems:**
  1. Per CLAUDE.md (`feedback_dolt_sigquit_unsafe.md`, gt-96b, gt-frg), our
     custom Dolt catches SIGQUIT and does NOT crash — but **stock Dolt
     crashes**. If someone ever installs stock dolt on VPS-B by mistake, a
     `gt dolt dump` would take it down.
  2. Post-migration, there's no local Dolt PID, so the command either no-ops
     or, worse, SIGQUITs a stray `dolt` process that belongs to a test.
- **Recommendation:** hard-disable `gt dolt dump` when `GT_DOLT_HOST` is not
  local. Point users at journald instead — stack dumps from our custom build
  end up in the journal too.
- **Follow-up bead:** yes, P1 — this is the class of command that causes the
  "cure then relapse" doom loop.

### `gt dolt cleanup`

- Removes orphan test databases (testdb_*, beads_t*, doctest_*) via
  `DROP DATABASE` SQL calls. **Client-side; works remote.**
- Verify in the canary phase by running `gt dolt cleanup --dry-run` and
  confirming the list matches what we see on VPS-B's data dir.

### `gt dolt sql`

- Opens an interactive SQL shell pointed at `GT_DOLT_HOST:GT_DOLT_PORT`.
  **Client-side; works remote.** No change.

## Operational consequences (roll-forward checklist)

1. Disable local schedules for all host-bound plugins above **at cutover**;
   re-enable on VPS-B once deployed there.
2. Update the mayor/witness weekly cron job to ssh into VPS-B for
   `dolt-backup` / `dolt-snapshots` / `dolt-archive`.
3. File follow-up beads for the `gt dolt {start,stop,restart,kill-imposters,
   dump,logs}` fast-fail-when-remote polish. Prefix `gt-` (gastown source).
4. Run the canary phase of the migrate runbook to confirm `gt dolt status`,
   `gt dolt cleanup --dry-run`, and `bd list` all succeed against VPS-B.
5. Keep the local `.dolt-data` dir as cold backup for **at least one week**.
   Do not `rm -rf`.

## Follow-up beads to file (after migration prep MR lands)

The bead description explicitly says "don't block this bead" on these, so
file them as separate work:

- `gt-<new>`: Teach `gt dolt start/stop/restart/kill-imposters` to fast-fail
  when `GT_DOLT_HOST` is remote, with a pointer to `systemctl` on VPS-B.
- `gt-<new>`: Rewrite `gt dolt dump` to forward to `ssh VPS-B sudo journalctl`
  (or refuse when remote) — this is the SIGQUIT class-of-doom.
- `gt-<new>`: Rewrite `gt dolt logs` to pull journald from VPS-B.
- `gt-<new>`: Port `dolt-snapshots`, `dolt-backup`, `dolt-archive`,
  `compactor-dog`, `dolt-log-rotate` to VPS-B deployment (or retire
  `dolt-log-rotate` entirely in favor of journald).
