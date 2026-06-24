# Names-viewer CLI — Design

**Date:** 2026-06-24
**Status:** Approved (pending spec review)

## Problem

The search scrapers drive each retailer's search bar using a list of sneaker
names extracted from a Hype DC scrape JSON (`utils.hype_names.extract_names`,
fed via `--names-from`). Today that list is never materialised — it's derived
on the fly inside each search run. A human has no easy way to *see* the full
list of names that would be searched.

## Goal

A read-only CLI to print all unique sneaker names from a Hype DC scrape so the
user can eyeball them. **Purely a viewer** — it does not change the search
pipeline, and the search scrapers do not consume any new artifact.

## Non-goals

- Aggregating names across multiple retailers / Supabase (source stays Hype DC).
- Wiring any generated file back into `--names-from` (scrapers keep their
  current behaviour, reading the Hype DC JSON directly).
- Writing a names file to disk by default (stdout is the interface; the user
  can redirect if they want a file).

## Design

New module `sneaker-scout-backend/utils/show_names.py`, runnable as
`python -m utils.show_names` (via `uv run`).

It reuses the existing, proven `extract_names()` — no new parsing logic — so it
stays correct if the search scrapers' name-extraction ever changes.

### CLI

```bash
uv run python -m utils.show_names                       # jsons/hypedc_products.json
uv run python -m utils.show_names --include-brand       # "Nike Air Max 90"
uv run python -m utils.show_names --names-from=<path> --limit=N
```

| Flag | Default | Maps to |
|------|---------|---------|
| `--names-from` | `jsons/hypedc_products.json` | `extract_names(path=...)` |
| `--include-brand` | off | `extract_names(include_brand=True)` |
| `--limit` | none | `extract_names(limit=...)` |

### Behaviour

- Calls `extract_names(names_from, limit=limit, include_brand=include_brand)`.
- Prints **one name per line to stdout** (pipe/grep/redirect friendly).
- Prints a `N unique names` summary line to **stderr** (kept off stdout so a
  redirected list stays clean).
- Missing input file: let the underlying `FileNotFoundError` surface (clear,
  standard); no bespoke error handling needed for a dev viewer.

## Testing

A small unit test (`tests/test_show_names.py`) that runs the module's `main`
against a tiny fixture JSON and asserts the stdout lines equal the expected
names and that the count goes to stderr. Reuses the `--names-from` plumbing
pattern already covered by `tests/test_search_scraper_cli.py`.

## Files touched

- `sneaker-scout-backend/utils/show_names.py` (new)
- `sneaker-scout-backend/tests/test_show_names.py` (new)
