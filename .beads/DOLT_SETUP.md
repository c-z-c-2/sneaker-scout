# Beads Dolt Setup

**Current setup: external server mode.** A single `dolt sql-server` runs on the
macOS **host** under a launchd agent (`com.beads.dolt.sneaker-scout`), bound to
`0.0.0.0:3307`, serving the database from `~/Projects/sneaker-scout/.beads/dolt/`.
Both the host and the dev container connect as pure MySQL clients via
`BEADS_DOLT_*` env vars. `root@'%'` requires a password.

➡️ **The authoritative docs live in the repo-root `CLAUDE.md` →
"Beads Dolt Setup (external server mode)"** (architecture diagram, the env-var
table, and the launchd management commands). Start there.

Quick reference:

```bash
# host server status / restart (launchd owns it, KeepAlive restarts on crash+reboot)
launchctl print gui/$(id -u)/com.beads.dolt.sneaker-scout | grep -E 'state|pid'
launchctl kickstart -k gui/$(id -u)/com.beads.dolt.sneaker-scout
lsof -nP -iTCP:3307 -sTCP:LISTEN     # expect *:3307
bd dolt show                          # connection test
```

---

## Historical: the old embedded-mode problem (pre-migration)

Before the migration to server mode, beads ran in **embedded mode** with the
data at `.beads/embeddeddolt/sneaker_scout/`, and `bd dolt start` would launch a
managed server from `/tmp/beads-dolt/` (a different, empty data dir) — so
`bd list` failed with "database not found". The workaround was to start
`dolt sql-server` manually from `.beads/embeddeddolt`. The migration replaced all
of that: `embeddeddolt/` was renamed to `dolt/`, a host launchd server now owns
the process on port 3307, and the container connects over `host.docker.internal`.
This section is kept only so old references to the `/tmp/beads-dolt` failure mode
make sense; **do not follow the old steps.**
