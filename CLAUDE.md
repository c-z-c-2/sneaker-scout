# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Sneaker Scout is a sneaker price tracking app for Australian retailers. It has two independent sub-projects (each with its own git repo):

- **`sneaker-scout-backend/`** — Python scrapers that extract sneaker data from retailer websites and upload it to Supabase
- **`aussie-kicks-tracker/`** — React frontend (originally scaffolded via Lovable) that displays sneaker data from Supabase

## Living documents

These files describe surfaces that drift fast and break things silently when out of date. Treat keeping them current as part of the change, not a follow-up:

- **`aussie-kicks-tracker/SITEMAP.md`** — catalogue of every routable page, its URL params, and what data it loads. **MANDATORY:** any change to `aussie-kicks-tracker/src/App.tsx` routes or any file under `aussie-kicks-tracker/src/pages/` must update SITEMAP.md in the **same commit**. This includes: adding/removing routes, renaming a page component, changing accepted URL search params, changing auth gating, or changing which hooks/queries the page invokes. If your diff touches those paths and SITEMAP.md isn't in the diff, the change is incomplete.
- **`spec.yaml`** (repo root) — OpenAPI spec for the Supabase REST surface the frontend consumes plus the backend scraper CLI invocations. Update when: adding/removing a Supabase table the frontend reads, changing the columns in a `select(...)` call in a way that affects the response shape, adding a new scraper entrypoint, or changing the auth flow. Examples in the spec should round-trip — if you change a query, update the example.

## Commands

### Frontend (`aussie-kicks-tracker/`)

```bash
npm run dev      # Dev server on port 8080
npm run build    # Production build
npm run lint     # ESLint
npm run preview  # Preview production build
```

Uses `@` path alias mapped to `./src/`.

### Backend (`sneaker-scout-backend/`)

The pipeline is two stages: a per-retailer scraper writes JSON to `jsons/`, then `data_upload/run_update.py` upserts that JSON into Supabase. All scraper packages (`salomon/`, `hypedc/`, `platypus/`, `footlocker/`, `jdsports/`) use **relative intra-package imports** (`from . import …`), so they can be invoked via either:

- `python -m <retailer>.pagination_scraper` from inside `sneaker-scout-backend/` (local dev), or
- `python -m backend.<retailer>.pagination_scraper` from anywhere `backend/` is on `PYTHONPATH` (the Docker layout).

#### Run locally (recommended for dev)

```bash
cd sneaker-scout-backend

# Stage 1 — scrape (produces jsons/<retailer>_products.json)
python -m salomon.pagination_scraper
python -m hypedc.pagination_scraper
python -m platypus.pagination_scraper     # PLATYPUS_HEADLESS=false to solve bot challenges in a visible browser
python -m footlocker.pagination_scraper   # FOOTLOCKER_HEADLESS=false if Akamai puts up a challenge
python -m jdsports.pagination_scraper     # JDSPORTS_HEADLESS=false if PerimeterX/DataDome challenges

# Stage 2 — upload (.env must define SUPABASE_URL + SUPABASE_SERVICE_KEY)
python -m data_upload.run_update --file=jsons/salomon_products.json
python -m data_upload.run_update --file=jsons/hypedc_products.json
python -m data_upload.run_update --file=jsons/platypus_products.json
python -m data_upload.run_update --file=jsons/footlocker_products.json
python -m data_upload.run_update --file=jsons/jdsports_products.json
```

Each stage is independent — you can re-run upload against an existing JSON without re-scraping.

#### Run via Docker

```bash
# Periodic loop: scrape + upload every SCRAPE_INTERVAL_HOURS (default 6).
# IMPORTANT: the loop in entrypoint.sh currently runs ONLY salomon. To
# include hypedc on the same cadence, add two more lines to entrypoint.sh
# (one to invoke `python -m backend.hypedc.pagination_scraper`, one to
# upload `backend/jsons/hypedc_products.json`).
docker-compose up backend

# Ad-hoc one-off inside the container — works for any retailer:
docker-compose run --rm backend python -m backend.hypedc.pagination_scraper
docker-compose run --rm backend python -m backend.data_upload.run_update \
    --file=backend/jsons/hypedc_products.json
```

Inside the container `PYTHONPATH=/app` and the package is mounted at `/app/backend/`, so in-container runs must use the `backend.<retailer>.…` form.

Requires a `.env` file in `sneaker-scout-backend/` (copy from `.env.example`) with `SUPABASE_URL` and `SUPABASE_SERVICE_KEY`. Optional: `CHROMEDRIVER_PATH` to override the Chrome/Selenium binary.

Python dependencies: `selenium`, `webdriver-manager`, `beautifulsoup4`, `supabase`, `python-dotenv`, `pandas`, `pydantic>=2.0`.

### Docker (full stack)

```bash
docker-compose up                        # Production build (frontend on :8080)
docker-compose -f docker-compose.dev.yml up  # Dev with hot-reload (src/ volume-mounted)
```

The backend container runs a scrape→upload pipeline every `SCRAPE_INTERVAL_HOURS` (default 6). **Today the loop only runs the salomon scraper** — see the note above for adding hypedc to the same cadence. Scraped JSON and upload logs are persisted in named volumes.

## Architecture

### Database (Supabase)

The Supabase schema is the contract between backend and frontend. Key tables and relationships:

```
brands → sneakers → colorways → prices        (per retailer)
                             → sneaker_sizes   (per retailer, per size)
                             → price_history   (tracks price changes over time)
sizes (lookup table: uk_size, us_size, eu_size)
retailers
profiles, user_favorites (auth-related)
```

- `prices` links a colorway to a retailer with current/original price and availability
- `sneaker_sizes` links a colorway + size + retailer with `is_available` flag
- `price_history` is append-only, written when `update_supabase_daily.py` detects a price change
- All IDs are UUIDs; currency is AUD

The generated types live at `aussie-kicks-tracker/src/integrations/supabase/types.ts`.

### Backend Scraper Architecture

Each retailer has its own directory (`salomon/`, `hypedc/`) with site-specific scrapers. Shared utilities are in `utils/`:

- `utils/models.py` — `Product`, `ProductSize`, `DetailedProduct` dataclasses
- `utils/driver_utils.py` — Selenium WebDriver initialization with anti-detection measures
- `utils/single_product_scraping_utils.py`, `utils/list_of_product_scraping_utils.py` — shared scraping helpers

**Scraper flow:** `pagination_scraper.py` iterates listing pages → calls `single_product_page_scraper.py` per product → combines basic + detailed info → saves to JSON. Then `data_upload/update_supabase_daily.py` reads that JSON and upserts into Supabase (brands, sneakers, colorways, retailers, prices, sizes, sneaker_sizes, price_history).

The backend imports use `backend.` prefix (e.g., `from backend.salomon.single_product_page_scraper import extract_detailed_info`). In Docker, `sneaker-scout-backend/` is copied into the image as `/app/backend/`, making the package name resolve correctly.

**Known data-format bug:** `combine_product_info()` in `pagination_scraper.py` writes JSON keys `sneakers`, `brands`, `retailers` (plural), but `update_supabase_daily.py` reads `sneaker`, `brand`, `retailer` (singular). Running the scraper then immediately uploading its output will raise `KeyError`. The JSON files in `jsons/` were produced by an older scraper and use the singular format the uploader expects.

### Frontend Architecture

React + TypeScript + Vite + Tailwind + shadcn/ui.

- **Routing** (react-router-dom): `/` (Index), `/auth`, `/favorites`, `/sneaker/:id` (SneakerDetail), `/test`
- **Data fetching**: `@tanstack/react-query` hooks in `src/hooks/useSneakers.tsx`; query functions in `src/lib/sneakerQueries.ts`
- **Auth**: Supabase Auth via `src/hooks/useAuth.tsx` (context provider wraps the app)
- **Favorites**: `src/hooks/useFavorites.tsx` backed by `user_favorites` table
- **UI components**: shadcn/ui primitives in `src/components/ui/`; app components (`SneakerCard`, `FilterSidebar`, `Header`, `PriceChart`) at `src/components/`

**Mock data in list view:** `useSneakers` in `useSneakers.tsx` uses random mock values for `lowest_price`, `price_change`, and `in_stock`. The real implementation (`fetchAllSneakers` in `src/lib/sneakerQueries.ts`) already queries live prices, stock, and price history from Supabase but is not wired up to the hook. The detail view (`useSneaker`) fetches real data.


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Beads Dolt Setup

### The core problem

`bd dolt start` always starts its managed dolt server from `/tmp/beads-dolt/` as the data directory. The actual beads database (`sneaker_scout`) lives at `/workspace/.beads/embeddeddolt/sneaker_scout/`. These two directories are separate — the server in `/tmp/beads-dolt` has no databases, so `bd list` fails with "database not found".

### Restoring beads after a session restart

If the dolt server is not running (e.g. after container restart), run:

```bash
cd /workspace/.beads/embeddeddolt
dolt sql-server --host=127.0.0.1 --port=7878 > /tmp/dolt-manual.log 2>&1 &
sleep 5
bd list   # verify it works
```

Do **NOT** run `bd dolt start` — it starts from the wrong directory.

### Database structure

```
/workspace/.beads/
├── embeddeddolt/          ← correct data_dir for dolt sql-server
│   ├── .dolt/
│   └── sneaker_scout/     ← the actual beads database (a dolt repo)
│       └── .dolt/         ← must exist for server to recognise it
└── config.yaml            ← has dolt.port: 7878 (pinned)
```

### What NOT to do

- **Don't run `bd dolt start`** — starts from `/tmp/beads-dolt`, can't find `sneaker_scout`
- **Don't run `bd bootstrap`** if the server is already up — fails with "nothing to commit" (harmless but confusing)
- **Don't delete `/tmp/beads-dolt/`** — bd uses it for managed server config and lock files
- **Don't trust `bd dolt status` Data: line** — shows `/tmp/beads-dolt` even when real data is elsewhere

---

## Superpowers — required workflow

Two superpowers skills are **mandatory** on this project, not optional:

- **`superpowers:writing-plans`** — Always invoke before writing implementation code for any non-trivial task (anything more than a one-line fix). The plan is the alignment artifact between you and the user; skipping it produces work that drifts from intent. Plans live under `docs/superpowers/plans/`.
- **`superpowers:subagent-driven-development`** — Always use this mode to *execute* a written plan. Step-by-step subagent dispatch keeps each implementation slice isolated, testable, and reviewable. Do NOT execute multi-task plans inline in the main session — spawn subagents per task as the skill prescribes.

Sequence: brainstorming (when scoping is open) → writing-plans (always before code) → subagent-driven-development (always for execution). Skipping either step requires an explicit user override.

## Context Management

**Clear context when you cross ~300k tokens.** Long sessions on this repo accumulate scraper logs, JSON dumps, and full test suites — once context climbs past ~300k the model starts losing fidelity on details from earlier turns, and cache misses get expensive.

When you cross the threshold (or sense degradation — repeated questions, forgetting prior decisions, summaries diverging from actual code):

1. Finish the in-flight beads issue: run quality gates, `bd close`, commit per the Per-Issue Commit Protocol below.
2. Run `bd remember "<insight>"` for anything from this session that future sessions need (decisions, gotchas, non-obvious findings — NOT the work itself, which is in commits).
3. Tell the user you're hitting the context budget and recommend `/clear`. Hand off with a 3-line summary: what just shipped, what's next, where to resume from (`bd ready` is usually enough).
4. Do NOT continue spawning new work in the same context after the threshold — close out cleanly first.

The goal is to never lose work to context decay. Commits + bd issues + `bd remember` are the durable handoff; the conversation transcript is not.

---

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->

## Per-Issue Commit Protocol

**Every time a beads issue is closed, you MUST create a git commit for the work that closed it.** Do not batch multiple closed issues into one commit unless they share a single coherent change. The goal is one commit per `bd close`, scoped to that issue's work.

### Workflow

Immediately after `bd close <id>`:

1. `git status` and `git diff` to see what changed for this issue
2. Stage only the files relevant to that issue (`git add <paths>` — avoid `git add -A`)
3. Commit using the format below

### Commit message format

- **Subject line** (≤72 chars): `<type>(<id>): <imperative summary>`
  - `type` is one of: `feat`, `fix`, `refactor`, `chore`, `docs`, `test`
  - `id` is the beads ID in lowercase (e.g. `sneaker_scout-t2b`)
  - Summary is imperative and specific — describe the user-visible change, not the file edited
- **Blank line**
- **Body**: 1–3 short paragraphs / bullets explaining the *why* — the problem, the approach, and any trade-offs. Reference the bd issue title.
- **Trailer**: `Closes: <bd-id>` so the commit is greppable from the issue ID

### Example

```
feat(sneaker_scout-t2b): wire retailer filter to listing query

The FilterSidebar checkboxes were rendering retailers but not affecting
the result set. Added a FilterContext that syncs selected retailer IDs
to the URL (`?retailers=...`), and updated useSneakers to filter via a
PostgREST inner join on colorways.prices with is_available=true.

Closes: sneaker_scout-t2b
```

### Rules

- One bd close → one commit. If the work for an issue spans multiple commits during development, squash before closing or note that in the body.
- Reference the bd ID in BOTH the subject and the `Closes:` trailer — the subject makes it visible in `git log --oneline`, the trailer makes it parseable.
- Do not push per-issue — push at session end per the Session Completion workflow above.
- If `bd close` is run for an issue where the work was already committed (e.g. closing a duplicate or an already-shipped fix), skip the commit but note this in the close reason: `bd close <id> --reason="already shipped in <sha>"`.

