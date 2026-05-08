# Beads Dolt Setup — Troubleshooting Notes

## What went wrong and how it was fixed

### The core problem

`bd dolt start` always starts its managed dolt server from `/tmp/beads-dolt/` as the data directory.
The actual beads database (`sneaker_scout`) lives at `/workspace/.beads/embeddeddolt/sneaker_scout/`.
These two directories are completely separate — the server in `/tmp/beads-dolt` has no databases.

### Why `bd list` kept failing

Every `bd list` command hit this sequence:
1. bd checks for a running dolt server (reads `.beads/dolt-server.pid`)
2. bd auto-starts the server via `bd dolt start` if not running
3. `bd dolt start` launches dolt with data_dir = `/tmp/beads-dolt`
4. That directory has no `sneaker_scout` database → `database not found` error

### What made things worse

- `dolt-server.pid` and `dolt-server.port` were owned by root (created when dolt was previously run as root)
- Deleting those files caused the port to change on each restart
- `bd bootstrap` kept saying "nothing to commit" — this is because the tables were already created in the embedded dolt, but the running server was pointing at the wrong directory (so bd tried to re-create them in the wrong place and got confused)

### The fix

**Step 1:** Start the dolt server MANUALLY from the directory that contains the actual database:

```bash
cd /workspace/.beads/embeddeddolt
dolt sql-server --host=127.0.0.1 --port=7878 > /tmp/dolt-manual.log 2>&1 &
sleep 5
```

This works because `/workspace/.beads/embeddeddolt/` is the correct data_dir. The `sneaker_scout` subdirectory is a valid dolt repo (has `.dolt/` inside it) and is served as the `sneaker_scout` database.

**Step 2:** Pin the port in beads config so bd connects to the right server:

```bash
bd config set dolt.port 7878
```

This writes `dolt.port: 7878` to `.beads/config.yaml` and stops bd from auto-starting its own server on a random port.

**Step 3 (optional):** Also edit `/tmp/beads-dolt/config.yaml` and set:
```yaml
data_dir: /workspace/.beads/embeddeddolt
```
This makes it so if bd's managed server IS started, it points at the right place. (This alone wasn't enough — the server still didn't pick up the database, possibly a dolt multi-db config issue.)

### Database structure

```
/workspace/.beads/
├── embeddeddolt/          ← data_dir for dolt sql-server
│   ├── .dolt/             ← dolt metadata for the parent repo
│   ├── .doltcfg/
│   ├── config.yaml        ← optional: copy of server config
│   └── sneaker_scout/     ← the actual beads database (a dolt repo)
│       └── .dolt/         ← MUST exist for server to recognize as a database
└── config.yaml            ← bd config; has dolt.port: 7878
```

### Restoring beads after a session restart

If the dolt server is not running (e.g. after container restart), run:

```bash
cd /workspace/.beads/embeddeddolt
dolt sql-server --host=127.0.0.1 --port=7878 > /tmp/dolt-manual.log 2>&1 &
sleep 5
bd list   # verify it works
```

Do NOT run `bd dolt start` — it starts from the wrong directory.

### What NOT to do

- **Don't run `bd dolt start`** — it starts from `/tmp/beads-dolt` and can't find `sneaker_scout`
- **Don't run `bd bootstrap`** if the server is already up and working — it will fail with "nothing to commit" (harmless but confusing)
- **Don't delete `/tmp/beads-dolt/`** — bd uses it for its managed server config and lock files
- **Don't run `bd init --force`** without first confirming dolt is pointing at the right directory; it will reinit the schema but still can't commit if the server is wrong
- **Don't trust `bd dolt status` Data: line** — it shows `/tmp/beads-dolt` even when the real data is elsewhere
