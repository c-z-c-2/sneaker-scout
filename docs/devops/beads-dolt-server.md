# Beads / Dolt — External Server Mode Runbook

How the beads issue tracker's Dolt database is hosted for Sneaker Scout, why it
is set up this way, and how to operate / recover / rebuild it.

- **Configured:** 2026-06-05 (migrated from embedded mode)
- **Host:** macOS (Apple Silicon, arm64), Docker Desktop
- **Versions at setup:** `dolt 2.1.2` (Homebrew), `bd 1.0.4`
- **Authoritative quick-reference:** repo-root `CLAUDE.md` →
  "Beads Dolt Setup (external server mode)". This file is the long-form runbook.

---

## 1. Architecture

One `dolt sql-server` runs **on the macOS host**, owned by a launchd agent,
bound to `0.0.0.0:3307`. The host shell and the VS Code dev container both
connect to it as **pure MySQL clients** — neither starts its own server.

```
macOS host
│
├── launchd agent  com.beads.dolt.sneaker-scout
│       └── /opt/homebrew/bin/dolt sql-server --host 0.0.0.0 --port 3307
│             cwd / data-dir: ~/Projects/sneaker-scout/.beads/dolt/
│             KeepAlive + RunAtLoad  → restarts on crash, logout, reboot
│
├── host  bd  ──TCP──▶ 127.0.0.1:3307            (env in ~/.zshrc)
│
└── Docker Desktop VM
        └── dev container
              └── container bd ──TCP──▶ host.docker.internal:3307
                    (env in .devcontainer/devcontainer.json + devcontainer.env)
```

**Why this shape**

- *Server on the host, not the container.* The container is ephemeral
  (rebuilt often). Keeping the server + data on the host means issues survive
  container rebuilds and the container needs neither the `dolt` binary nor a
  copy of the data.
- *External server, not `bd dolt start`.* bd's auto-started ("managed") server
  historically launched from a `/tmp/beads-dolt` data-dir that did **not**
  contain the `sneaker_scout` database, so `bd list` failed with
  "database not found". An explicitly-owned launchd server removes that class
  of bug. `BEADS_DOLT_AUTO_START=0` disables the managed path on both sides.
- *Bound `0.0.0.0`, not `127.0.0.1`.* On Docker Desktop for Mac the container
  reaches the host via `host.docker.internal`; a `127.0.0.1`-only bind is not
  reachable from the VM. There is no host-side `docker0` bridge to bind to on
  macOS (that's Linux-only), so `0.0.0.0` is required.
- *Password required.* Because `0.0.0.0` exposes the port to the LAN, the
  `root` user requires a password — the port is reachable but the DB is not
  readable without credentials.

---

## 2. Connection settings (per environment)

Connection details come from `BEADS_DOLT_*` env vars, which **override**
`.beads/config.yaml`. Only the environment-invariant `dolt.port: 3307` lives in
the shared config; host / mode / password are per-environment env vars and are
never committed.

| var | host (`~/.zshrc`) | container (`devcontainer.json`) |
|-----|-------------------|----------------------------------|
| `BEADS_DOLT_SERVER_MODE` | `1` | `1` |
| `BEADS_DOLT_SERVER_HOST` | `127.0.0.1` | `host.docker.internal` |
| `BEADS_DOLT_SERVER_PORT` | `3307` | `3307` |
| `BEADS_DOLT_SERVER_DATABASE` | `sneaker_scout` | `sneaker_scout` |
| `BEADS_DOLT_AUTO_START` | `0` | `0` |
| `BEADS_DOLT_PASSWORD` | in `~/.zshrc` | in `.devcontainer/devcontainer.env` |

### Where the password lives (two copies, both gitignored / never committed)

- **Host:** `~/.zshrc`, in the `# --- beads dolt (sneaker-scout) ... ---` block.
- **Container:** `.devcontainer/devcontainer.env` (chmod 600, gitignored),
  loaded into the container via `--env-file` in `devcontainer.json`'s
  `runArgs`, then surfaced to bd through
  `"BEADS_DOLT_PASSWORD": "${containerEnv:BEADS_DOLT_PASSWORD}"` in `remoteEnv`.
- **In the database:** as the password hash for `root@'%'` and `root@'localhost'`
  in `.beads/dolt/.doltcfg/privileges.db`.

`--env-file` is used (rather than `${localEnv:BEADS_DOLT_PASSWORD}`) so it works
regardless of how VS Code is launched — a GUI launch does not inherit `~/.zshrc`.

---

## 3. How it was built (reproduce from scratch)

Run on the **host**, from the repo root unless noted.

### 3.1 Install dolt (Homebrew, prebuilt — no Go toolchain needed)

```bash
brew install dolt           # installs /opt/homebrew/bin/dolt
dolt version                # 2.1.2 at time of writing
```

`bd` is installed separately (see `.devcontainer/post-create.sh` for the
container; on the host it's at `~/.local/bin/bd`).

### 3.2 Migrate the data directory (embedded → server layout)

The embedded data lived in `.beads/embeddeddolt/` (a dir containing the
`sneaker_scout` database). Server mode's default data-dir is `.beads/dolt/`.

```bash
cd ~/Projects/sneaker-scout/.beads

# Back up first (full Dolt history + JSONL export)
tar czf ~/Projects/sneaker-scout/beads-embeddeddolt-backup-$(date +%Y%m%d-%H%M%S).tgz \
    embeddeddolt issues.jsonl interactions.jsonl

# Remove stale managed-server lock/pid files, then rename the data dir
rm -f dolt-server.lock dolt-server.pid dolt-server.port embeddeddolt/.lock
mv embeddeddolt dolt
```

`.beads/dolt/` now contains `sneaker_scout/` (the database, a Dolt repo) plus
`.dolt/`, `.doltcfg/` (where `privileges.db` lives), and `config.yaml`.
`.beads/dolt/` is **gitignored** (runtime data, not source).

### 3.3 Set the password and create a remotely-connectable user

Embedded mode only had `root@'localhost'` with no password. Remote clients (the
container) connect from a non-localhost address, so a `root@'%'` user is needed.

```bash
# Start a temporary loopback server to administer users
cd ~/Projects/sneaker-scout/.beads/dolt
dolt sql-server --host 127.0.0.1 --port 3307 &   # temp; kill when done

PW='<a strong random password>'                  # e.g. 32 url-safe chars
dolt sql -q "CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${PW}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${PW}';
FLUSH PRIVILEGES;"

# stop the temp server (it has done its job; launchd owns the real one)
kill %1
```

The credentials persist in `.beads/dolt/.doltcfg/privileges.db`, so the launchd
server (which is started without any `user:` config) enforces them on startup.

### 3.4 Install the launchd agent (owns the long-lived server)

Plist: `~/Library/LaunchAgents/com.beads.dolt.sneaker-scout.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>com.beads.dolt.sneaker-scout</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/dolt</string>
    <string>sql-server</string>
    <string>--host</string> <string>0.0.0.0</string>
    <string>--port</string> <string>3307</string>
  </array>
  <key>WorkingDirectory</key> <string>/Users/chris/Projects/sneaker-scout/.beads/dolt</string>
  <key>RunAtLoad</key>        <true/>
  <key>KeepAlive</key>        <true/>
  <key>StandardOutPath</key>  <string>/Users/chris/Projects/sneaker-scout/.beads/dolt-launchd.out.log</string>
  <key>StandardErrorPath</key><string>/Users/chris/Projects/sneaker-scout/.beads/dolt-launchd.err.log</string>
</dict>
</plist>
```

Load it:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.beads.dolt.sneaker-scout.plist
lsof -nP -iTCP:3307 -sTCP:LISTEN     # expect: dolt ... TCP *:3307 (LISTEN)
```

### 3.5 Point the host shell at it (`~/.zshrc`)

```bash
# --- beads dolt (sneaker-scout) external server mode ---
export BEADS_DOLT_SERVER_MODE=1
export BEADS_DOLT_SERVER_HOST=127.0.0.1
export BEADS_DOLT_SERVER_PORT=3307
export BEADS_DOLT_SERVER_DATABASE=sneaker_scout
export BEADS_DOLT_AUTO_START=0
export BEADS_DOLT_PASSWORD='<the password>'
# --- end beads dolt ---
```

Verify in a fresh shell: `bd dolt show` → "Server connection OK"; `bd ready`
lists issues.

### 3.6 Point the dev container at it (`.devcontainer/`)

`devcontainer.json` (committed):

```jsonc
// no in-container server: client only
"postStartCommand": "bd dolt show >/tmp/bd-conn.log 2>&1 || true",
"runArgs": ["--env-file", "${localWorkspaceFolder}/.devcontainer/devcontainer.env"],
"remoteEnv": {
  // ...existing CHROME_BIN / PYTHONPATH / PATH ...
  "BEADS_DOLT_SERVER_MODE": "1",
  "BEADS_DOLT_SERVER_HOST": "host.docker.internal",
  "BEADS_DOLT_SERVER_PORT": "3307",
  "BEADS_DOLT_SERVER_DATABASE": "sneaker_scout",
  "BEADS_DOLT_AUTO_START": "0",
  "BEADS_DOLT_PASSWORD": "${containerEnv:BEADS_DOLT_PASSWORD}"
}
```

`.devcontainer/devcontainer.env` (gitignored, chmod 600):

```
BEADS_DOLT_PASSWORD=<the password>
```

Then **Dev Containers: Rebuild Container** and verify inside:

```bash
bd dolt show     # host host.docker.internal:3307, connection OK
bd ready         # same issues as the host
```

---

## 4. Operating the server

```bash
# status
launchctl print gui/$(id -u)/com.beads.dolt.sneaker-scout | grep -E 'state|pid'
lsof -nP -iTCP:3307 -sTCP:LISTEN

# restart / stop / start
launchctl kickstart -k gui/$(id -u)/com.beads.dolt.sneaker-scout
launchctl bootout     gui/$(id -u)/com.beads.dolt.sneaker-scout
launchctl bootstrap   gui/$(id -u) ~/Library/LaunchAgents/com.beads.dolt.sneaker-scout.plist

# logs
tail -f ~/Projects/sneaker-scout/.beads/dolt-launchd.err.log

# bd's view + connection test (host)
bd dolt show
```

Editing the plist? `bootout` then `bootstrap` to reload (launchd caches the
loaded definition).

---

## 5. Rotating the password

1. Restart server loopback-only is not required — connect through the running
   server and alter the users:
   ```bash
   cd ~/Projects/sneaker-scout/.beads/dolt
   NEW='<new password>'
   dolt sql -q "ALTER USER 'root'@'%' IDENTIFIED BY '${NEW}';
   ALTER USER 'root'@'localhost' IDENTIFIED BY '${NEW}';
   FLUSH PRIVILEGES;"
   ```
2. Update `BEADS_DOLT_PASSWORD` in **`~/.zshrc`** and in
   **`.devcontainer/devcontainer.env`**.
3. `source ~/.zshrc` (host) and **rebuild the container** (to re-read the env
   file). Verify with `bd dolt show` on both sides.

---

## 6. Disaster recovery

**Server won't start / data looks wrong** — check the launchd error log first
(`.beads/dolt-launchd.err.log`). A stale `.lock` inside `.beads/dolt/` after an
unclean shutdown can block startup; remove it and `kickstart`.

**Restore from the migration backup** (full Dolt history):

```bash
launchctl bootout gui/$(id -u)/com.beads.dolt.sneaker-scout   # stop server
cd ~/Projects/sneaker-scout/.beads
mv dolt dolt.broken
tar xzf ~/Projects/sneaker-scout/beads-embeddeddolt-backup-YYYYMMDD-HHMMSS.tgz
mv embeddeddolt dolt
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.beads.dolt.sneaker-scout.plist
bd ready    # verify
```

Note: the backup predates the `root@'%'` + password step (§3.3), so after a
restore re-run that SQL to recreate the user and set the password.

**Last-resort issue data** — `.beads/issues.jsonl` is a passive export of all
issues (no Dolt history). `bd import` / `bd bootstrap --from-jsonl` can rebuild
a database from it if the Dolt repo is unrecoverable.

There is **no Dolt remote** configured (deliberate — local-only). Off-machine
durability comes from the tarball backup + `issues.jsonl` in git history.

---

## 7. Pitfalls (do NOT do these)

- **Don't run `bd dolt start` / `bd init` inside the container.** It's a pure
  client; starting a server there spawns a competing instance or a stray empty
  database. `BEADS_DOLT_AUTO_START=0` is set to prevent the auto path.
- **Don't commit the password.** Both `~/.zshrc` (host-only) and
  `.devcontainer/devcontainer.env` (gitignored) hold it; neither is in git.
- **Don't put `host` / `mode` / `password` in `.beads/config.yaml`.** That file
  is shared, but `host` differs per environment (`127.0.0.1` vs
  `host.docker.internal`). Only `dolt.port: 3307` belongs there.
- **Don't delete `.beads/dolt/`.** That's the live database.
- **Don't run two process owners.** launchd owns the server; don't also run a
  manual `dolt sql-server` or a tmux loop on 3307 — they'll fight over the port.
