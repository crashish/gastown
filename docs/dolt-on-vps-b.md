# Dolt on VPS-B — operational guide (post-migration)

After gt-4ek ships and the cutover runs, Gas Town's Dolt SQL server lives on
**VPS-B (`10.10.0.3:3307`)** instead of the local host. This document is the
reference for where it lives, how to talk to it, how to back it up, and how to
recover it if VPS-B goes offline.

Companion artifacts (all merged with this doc):

- `scripts/dolt-migrate-to-vps-b.sh` — one-shot cutover runbook (human-run).
- `scripts/dolt-rollback-from-vps-b.sh` — mirror; use if VPS-B becomes
  unworkable within the one-week cold-backup window.
- `scripts/dolt-stage-metadata-commits.sh` — pre-stages the per-rig
  `.beads/metadata.json` updates before the cutover window.
- `mesh/dolt.service` — systemd unit installed on VPS-B.
- `mesh/dolt-server.yaml` — Dolt server config installed on VPS-B, bound to
  the WG interface only.
- `docs/dolt-migration-plugin-audit.md` — per-plugin / per-command breakdown
  of what still works and what needs follow-up.

## Topology

```
                 ┌──────────────────────┐
                 │ local host (wg 10.10.0.1)
                 │  ┌──────────┐
                 │  │ gt daemon│──┐  GT_DOLT_HOST=10.10.0.3
                 │  │ bd / gt  │  │  BEADS_DOLT_SERVER_HOST=10.10.0.3
                 │  │ polecats │  │
                 │  └──────────┘  │
                 │                │ WG (tcp/3307)
                 └────────────────┼─────┘
                                  │
                 ┌────────────────┼─────┐
                 │ VPS-B  10.10.0.3     │
                 │  ┌──────────────┐    │
                 │  │ dolt.service │────┘ binds 10.10.0.3:3307 only
                 │  └──────────────┘
                 │    data: /opt/gastown/.dolt-data
                 │    bkup: /opt/gastown/.dolt-backup
                 │    logs: journald (journalctl -u dolt)
                 │
                 │  (coexists with trapline-elasticsearch)
                 └──────────────────────┘
```

The local `$HOME/gt/.dolt-data/` and `$HOME/gt/.dolt-backup/` are **retained
as cold backup for at least one week**. Do not `rm -rf` them.

## Deployment layout on VPS-B

```
/opt/gastown/
├── .dolt-data/              # owned by dolt:dolt, 0750
│   ├── config.yaml          # from mesh/dolt-server.yaml
│   ├── <per-db dirs>
│   └── privileges.db
└── .dolt-backup/            # owned by dolt:dolt, 0750

/etc/systemd/system/
└── dolt.service             # from mesh/dolt.service

/usr/local/bin/
└── dolt                     # Gas Town SIGQUIT-safe build (NOT stock dolt)
```

System user:
```
sudo useradd --system --home /opt/gastown --shell /usr/sbin/nologin dolt
```

## Connecting

From anywhere on the WG mesh:

```bash
# env vars (set in ~/.bashrc by the migrate runbook)
export GT_DOLT_HOST=10.10.0.3
export GT_DOLT_PORT=3307
# BEADS_DOLT_SERVER_HOST / BEADS_DOLT_PORT are auto-translated by bd (see
# internal/beads/beads.go translateDoltPort).

# SQL shell
gt dolt sql

# direct
dolt sql-client --host 10.10.0.3 --port 3307 --user root

# list DBs
dolt sql-client --host 10.10.0.3 --port 3307 --user root -q 'SHOW DATABASES;'
```

## Day-2 operations

### Server lifecycle

All server lifecycle is systemd on VPS-B, not `gt dolt start/stop`:

```bash
# status
ssh crash@10.10.0.3 'systemctl status dolt.service'

# restart
ssh crash@10.10.0.3 'sudo systemctl restart dolt.service'

# tail logs (journald, NOT ~/gt/daemon/dolt.log anymore)
ssh crash@10.10.0.3 'sudo journalctl -u dolt -f'

# last 1000 lines
ssh crash@10.10.0.3 'sudo journalctl -u dolt -n 1000'
```

**Do not run `gt dolt start/stop/restart` locally after migration.** Those
commands still exist but operate on a local PID file that no longer
corresponds to anything. See `docs/dolt-migration-plugin-audit.md` for the
planned fix.

### Backups

Two layers:

1. **Dolt's native `dolt backup sync`** runs on VPS-B via a systemd timer
   (install as part of the plugin port — see follow-up beads). Writes to
   `/opt/gastown/.dolt-backup/`.
2. **Off-host copy** — the `plugins/dolt-backup/` plugin, re-deployed to
   VPS-B, syncs the `.dolt-backup/` dir to an iCloud mount that's still
   available on the local host (see `backup` skill).

Verify backup health with:

```bash
ssh crash@10.10.0.3 'ls -la /opt/gastown/.dolt-backup/'
ssh crash@10.10.0.3 'sudo -u dolt dolt backup list'
```

### Status / health

```bash
gt dolt status          # prints VPS-B host:port, latency, orphan count
bd list --limit 1       # smoke test: bd goes through dolt
```

If `gt dolt status` hangs:

```bash
# 1. Is VPS-B up?
ping -c2 10.10.0.3

# 2. Is dolt.service running?
ssh crash@10.10.0.3 'systemctl is-active dolt.service'

# 3. Is the port listening on the WG interface?
ssh crash@10.10.0.3 "ss -tln '( sport = :3307 )'"

# 4. Journald first
ssh crash@10.10.0.3 'sudo journalctl -u dolt -n 200 --no-pager'
```

**Never `kill -QUIT` the Dolt PID** — our build tolerates it, but the
muscle-memory is dangerous because stock dolt crashes on it.

### Restarting the gt daemon after a config change

The daemon caches `GT_DOLT_HOST` at spawn time. If you change the env var,
restart the daemon:

```bash
gt daemon restart
# verify
pgrep -af 'gt daemon' | head -1
grep -z GT_DOLT_HOST /proc/$(pgrep -f 'gt daemon' | head -1)/environ
```

## Disaster recovery

### VPS-B is up but Dolt is wedged

```bash
# 1. Collect evidence
ssh crash@10.10.0.3 'sudo journalctl -u dolt -n 500 --no-pager' > /tmp/dolt-evid.log
ssh crash@10.10.0.3 'systemctl status dolt.service'

# 2. Try a graceful restart — systemd sends SIGTERM, waits 90s
ssh crash@10.10.0.3 'sudo systemctl restart dolt.service'

# 3. If still wedged: escalate
gt escalate -s HIGH 'Dolt: wedged on VPS-B — evidence at /tmp/dolt-evid.log'
```

### VPS-B is offline / unreachable

If VPS-B is down for longer than we can tolerate (budget: a few minutes before
the town grinds to a halt), fall back to the local cold backup:

```bash
scripts/dolt-rollback-from-vps-b.sh
# If VPS-B accepted writes since the cutover and you want those
# changes before falling back, use:
scripts/dolt-rollback-from-vps-b.sh --reverse-rsync
```

This thaws `~/gt/.dolt-data/`, starts local Dolt, reverts the metadata
commits, unsets `GT_DOLT_HOST`, and restarts the gt daemon. Expect ~2-5
minutes downtime for the rollback.

### VPS-B disk fills up

`MemoryMax=10G` and `LimitNOFILE=524288` are set in `mesh/dolt.service` but
there's no direct disk quota. Watch free space:

```bash
ssh crash@10.10.0.3 'df -h /opt'
```

If disk fills, the immediate remediation is to run `dolt gc` per database:

```bash
ssh crash@10.10.0.3 'sudo -iu dolt bash -c "for d in /opt/gastown/.dolt-data/*/; do (cd \$d && dolt gc --shallow); done"'
```

File a bead for the long-term fix (provision more disk, or offload
`.dolt-backup/` to iCloud-only with no on-host retention).

## Cutover checklist (for the human running it)

This is the short version; see `scripts/dolt-migrate-to-vps-b.sh` for the
canonical sequence. Work through it linearly — do not skip steps without
understanding what they gate.

- [ ] Announce maintenance window in `#gastown` or the equivalent channel.
- [ ] Pause dispatch so no new polecats spawn: `gt witness pause` (or set the
      mayor to refuse new sling requests — check the current incantation).
- [ ] Drain in-flight polecats: wait until `tmux list-sessions | grep polecat`
      is empty or only shows agents idling.
- [ ] Install `mesh/dolt.service` + `mesh/dolt-server.yaml` + the custom
      `dolt` binary on VPS-B (once, before first migration attempt).
- [ ] Pre-stage metadata commits:
      `scripts/dolt-stage-metadata-commits.sh --new-host 10.10.0.3 --dry-run`
      then drop `--dry-run`.
- [ ] Dry-run the cutover:
      `scripts/dolt-migrate-to-vps-b.sh --dry-run`
- [ ] Run the cutover: `scripts/dolt-migrate-to-vps-b.sh`
- [ ] Verify canary passed (`bd list` against VPS-B works).
- [ ] Unpause dispatch.
- [ ] Keep local cold backup for ≥ 1 week.
- [ ] File follow-up beads listed in `docs/dolt-migration-plugin-audit.md`.

## Security posture

The systemd unit (`mesh/dolt.service`) hardens the Dolt process:

- **Listener bound to WG IP only** (`10.10.0.3`) — 3307 is not reachable on
  the public NIC. Double-defended by `IPAddressAllow=10.10.0.0/24 127.0.0.0/8`.
- **Runs as dedicated `dolt` user**, not root.
- **Read-only root FS** (`ProtectSystem=strict`); only
  `/opt/gastown/.dolt-data` and `/opt/gastown/.dolt-backup` are writable.
- **Private /tmp, /dev**; `NoNewPrivileges=yes`; `RestrictSUIDSGID=yes`;
  `LockPersonality=yes`.

If we ever need to expose Dolt beyond the WG mesh, **do not just change the
listener host** — update `IPAddressAllow` too, put a proper auth layer in
place, and revisit TLS termination.

## What did not move (Phase 2+ scope)

- `gt` / `bd` binaries and the tmux agent sessions stay local.
- `plugins/dolt-snapshots`, `dolt-backup`, `dolt-archive`, `compactor-dog`,
  `dolt-log-rotate` still point at a local `.dolt-data/` (the cold backup)
  until their schedules are moved to VPS-B. See the plugin audit for the
  rollout plan.
- Trapline postgres (already on VPS-A), darkdisco celery (staying local for
  now), and figaro tooling are unchanged.

## References

- Bead: gt-4ek — "Prepare gastown Dolt migration to VPS-B"
- Related: gt-96b, gt-frg (SIGQUIT doom-loop fix for our Dolt build)
- Related: gt-fnk (smart watchdog that distinguishes wedge from load-saturation)
- Source plumbing: `internal/beads/beads.go` `translateDoltPort` /
  `overrideDoltEnvFromBeadsDir` (the GT_DOLT_HOST → BEADS_DOLT_SERVER_HOST
  translation layer that makes this migration a config-only change).
