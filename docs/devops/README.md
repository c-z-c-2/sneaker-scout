# DevOps runbooks

Operational documentation for the infrastructure behind Sneaker Scout — how
host-side services and the dev container are configured, and how to operate,
rotate, and recover them.

| Runbook | Covers |
|---------|--------|
| [beads-dolt-server.md](beads-dolt-server.md) | Beads issue-tracker Dolt database in external server mode: host launchd `dolt sql-server` on `0.0.0.0:3307`, host + dev-container clients, password/auth, build-from-scratch, password rotation, disaster recovery. |

Quick-reference versions of the most-used commands also live in the repo-root
`CLAUDE.md`; these runbooks are the long-form source of truth.
