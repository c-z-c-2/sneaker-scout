# Beads - AI-Native Issue Tracking

Welcome to Beads! This repository uses **Beads** for issue tracking - a modern, AI-native tool designed to live directly in your codebase alongside your code.

## What is Beads?

Beads is issue tracking that lives in your repo, making it perfect for AI coding agents and developers who want their issues close to their code. No web UI required - everything works through the CLI and integrates seamlessly with git.

**Learn more:** [github.com/steveyegge/beads](https://github.com/steveyegge/beads)

## Quick Start

### Essential Commands

```bash
# Create new issues
bd create "Add user authentication"

# View all issues
bd list

# View issue details
bd show <issue-id>

# Update issue status
bd update <issue-id> --claim
bd update <issue-id> --status done

# Sync with Dolt remote
bd dolt push
```

### Working with Issues

Issues in Beads are:
- **Git-native**: Stored in Dolt database with version control and branching
- **AI-friendly**: CLI-first design works perfectly with AI coding agents
- **Branch-aware**: Issues can follow your branch workflow
- **Always in sync**: Auto-syncs with your commits

## Why Beads?

✨ **AI-Native Design**
- Built specifically for AI-assisted development workflows
- CLI-first interface works seamlessly with AI coding agents
- No context switching to web UIs

🚀 **Developer Focused**
- Issues live in your repo, right next to your code
- Works offline, syncs when you push
- Fast, lightweight, and stays out of your way

🔧 **Git Integration**
- Automatic sync with git commits
- Branch-aware issue tracking
- Dolt-native three-way merge resolution

## Get Started with Beads

Try Beads in your own projects:

```bash
# Install Beads
curl -sSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash

# Initialize in your repo
bd init

# Create your first issue
bd create "Try out Beads"
```

## Learn More

- **Documentation**: [github.com/steveyegge/beads/docs](https://github.com/steveyegge/beads/tree/main/docs)
- **Quick Start Guide**: Run `bd quickstart`
- **Examples**: [github.com/steveyegge/beads/examples](https://github.com/steveyegge/beads/tree/main/examples)

---

## Dev Container Setup (WSL + Docker)

This project runs inside a VS Code dev container. The host WSL environment runs its own dolt server with an exclusive write lock on `.beads/dolt/`. Mounting that directory into the container causes a lock conflict, so the container uses a **separate, container-local dolt data directory** at `/tmp/beads-dolt`.

The `.beads/issues.jsonl` file is still shared via the bind mount, so issue data syncs between host and container. The dolt database is just the query layer on top.

### How it's configured

- `BEADS_DOLT_DATA_DIR=/tmp/beads-dolt` in `.devcontainer/devcontainer.json` (`remoteEnv`) — tells `bd` to use the container-local path instead of `.beads/dolt/`
- `postStartCommand: "bd dolt start 2>/dev/null || true"` — starts the dolt server on each container start

### After a container rebuild or restart

`/tmp` is wiped on each container restart. The canonical database lives in `.beads/embeddeddolt/sneaker_scout` (written by `bd init`). Copy it into the server data directory, then start the server:

```bash
rm -rf /tmp/beads-dolt/sneaker_scout
cp -r /workspace/.beads/embeddeddolt/sneaker_scout /tmp/beads-dolt/sneaker_scout
BEADS_DOLT_DATA_DIR=/tmp/beads-dolt bd dolt start
```

> **Why copy instead of `dolt init`?** A bare `dolt init` creates an empty database with no schema or config (including the `issue_prefix`). The embedded database in `.beads/embeddeddolt/` already has the full schema and config written by `bd init`, so copying it avoids needing to re-bootstrap.

If `bd dolt start` fails with "not supported in embedded mode" when run without the env var prefix, always use the explicit form:

```bash
BEADS_DOLT_DATA_DIR=/tmp/beads-dolt bd dolt start
```

### Verifying the setup

```bash
bd dolt status   # should show Data: /tmp/beads-dolt
bd ready         # should list issues (or "No open issues" if tracker is empty)
```

---

*Beads: Issue tracking that moves at the speed of thought* ⚡
