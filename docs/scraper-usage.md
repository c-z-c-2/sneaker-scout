# Scraper usage — pagination & search

How to run the two backend scraping modes:

- **Pagination scrapers** (`pagination_scraper.py`) — scrape a retailer's
  listing pages, either the canonical category or any custom `--url`.
- **Search scrapers** (`search_scraper.py`) — drive the site's on-page search
  bar for one or many sneaker names (e.g. every name in a Hype DC scrape).

Both produce JSON in `jsons/` that `data_upload/run_update.py` upserts into
Supabase. Retailers: `hypedc`, `footlocker`, `jdsports`, `platypus`,
`salomon`.

## Prerequisites

- Run from inside `sneaker-scout-backend/`.
- Dependencies are managed with **uv** — invoke via `uv run` (it syncs the
  locked env automatically; no `source .venv/bin/activate` needed).
- For upload, `.env` must define `SUPABASE_URL` + `SUPABASE_SERVICE_KEY`.
- **HypeDC must run headed** (`HYPEDC_HEADLESS=false`) — DataDome blocks
  headless Chrome. Solve any CAPTCHA in the window, press Enter to continue.
- If Chrome version auto-detection fails ("Couldn't detect Chrome version"),
  override per-retailer with `<RETAILER>_CHROME_VERSION=<major>`
  (e.g. `PLATYPUS_CHROME_VERSION=148`).

---

## Pagination scrapers (listing pages)

### Canonical category run

```bash
cd sneaker-scout-backend

# Each retailer, per gender
uv run python -m salomon.pagination_scraper    --gender=mens
uv run python -m platypus.pagination_scraper   --gender=mens
uv run python -m footlocker.pagination_scraper --gender=mens
uv run python -m jdsports.pagination_scraper   --gender=mens
HYPEDC_HEADLESS=false uv run python -m hypedc.pagination_scraper --gender=mens
# repeat each with --gender=womens
```

Output: `jsons/<retailer>_<gender>_products.json`.

### Custom starting URL

Every `pagination_scraper.py` accepts `--url <listing-url>` to scrape any
listing (brand page, filtered search, sale page, etc.). `--gender` is still
required — it tags `colorway.gender`.

```bash
cd sneaker-scout-backend
uv run python -m salomon.pagination_scraper    --gender=mens   --url='https://salomon.com.au/collections/mens/trail-running-shoes'
uv run python -m hypedc.pagination_scraper     --gender=mens   --url='https://www.hypedc.com/au/categories/mens/footwear/sneakers?brand=nike'
uv run python -m platypus.pagination_scraper   --gender=womens --url='https://www.platypusshoes.com.au/shop/womens/brands/asics'
uv run python -m footlocker.pagination_scraper --gender=mens   --url='https://www.footlocker.com.au/en/category/brands/on'
uv run python -m jdsports.pagination_scraper   --gender=mens   --url='https://www.jdsports.com.au/men/trainers/brand/nike/'
```

- Inbound paging params (`?page=N` hypedc, `?from=N` jdsports) are stripped
  automatically; filters and sort params survive.
- `--url` runs in **strict mode**: setup/listing/empty/PDP failures raise
  rather than fall back or skip (empty listings dump HTML to
  `diag/<retailer>_listing_dump.html`).
- Output: `jsons/<retailer>_<gender>_custom_products.json` (override `--out`).

---

## Search scrapers (drive the search bar)

Given one or more sneaker names, the search scraper types each into the
retailer's on-page search bar **human-like** (char-by-char with jitter,
~6s/search, ~100 names in ~10 min), reads the search-results URL, and scrapes
**every** result via that retailer's strict-mode `scrape_all_pages`. Results
across all searches are merged + de-duped (by `sneaker.product_url`) into one
JSON per retailer.

Intended bulk use: feed it a Hype DC scrape output with `--names-from` to
cover the other retailers' versions of Hype's catalogue without hand-supplying
URLs.

All commands run from `sneaker-scout-backend/`. Always run headed (`HEADLESS=false`) so you can watch the browser and catch stalls early. The `--limit=3` flag caps the bulk name list to 3 searches for smoke-testing.

### JD Sports

```bash
# 3-search smoke test
JDSPORTS_HEADLESS=false uv run python -m jdsports.search_scraper \
    --names-from=jsons/hypedc_products.json --gender=mens --limit=3

# Full run (~83 names from the Hype DC file, ~10–15 min)
JDSPORTS_HEADLESS=false uv run python -m jdsports.search_scraper \
    --names-from=jsons/hypedc_products.json --gender=mens
# output: jsons/jdsports_mens_search_products.json
```

### Footlocker

```bash
# 3-search smoke test
FOOTLOCKER_HEADLESS=false uv run python -m footlocker.search_scraper \
    --names-from=jsons/hypedc_products.json --gender=mens --limit=3

# Full run
FOOTLOCKER_HEADLESS=false uv run python -m footlocker.search_scraper \
    --names-from=jsons/hypedc_products.json --gender=mens
# output: jsons/footlocker_mens_search_products.json
```

### Platypus

```bash
# 3-search smoke test
PLATYPUS_HEADLESS=false uv run python -m platypus.search_scraper \
    --names-from=jsons/hypedc_products.json --gender=mens --limit=3

# Full run
PLATYPUS_HEADLESS=false uv run python -m platypus.search_scraper \
    --names-from=jsons/hypedc_products.json --gender=mens
# output: jsons/platypus_mens_search_products.json
```

### Salomon

```bash
# 3-search smoke test
SALOMON_HEADLESS=false uv run python -m salomon.search_scraper \
    --names-from=jsons/hypedc_products.json --gender=mens --limit=3

# Full run
SALOMON_HEADLESS=false uv run python -m salomon.search_scraper \
    --names-from=jsons/hypedc_products.json --gender=mens
# output: jsons/salomon_mens_search_products.json
```

### HypeDC

Requires headed Chrome and a manual CAPTCHA solve. Skip until the other retailers are confirmed working.

```bash
# 3-search smoke test
HYPEDC_HEADLESS=false uv run python -m hypedc.search_scraper \
    --names-from=jsons/hypedc_products.json --gender=mens --limit=3

# Full run
HYPEDC_HEADLESS=false uv run python -m hypedc.search_scraper \
    --names-from=jsons/hypedc_products.json --gender=mens
# output: jsons/hypedc_mens_search_products.json
```

### Flags

#### Input / output

| Flag | Default | Meaning |
|------|---------|---------|
| `--name "<text>"` | — | Search a single name. Mutually exclusive with `--names-from`; one is required. |
| `--names-from=<path>` | — | Extract sneaker names from a Hype DC scrape JSON and search each. |
| `--gender=mens\|womens` | `mens` | Tags every scraped row's `colorway.gender` and sets the output filename suffix. |
| `--out=<path>` | `jsons/<retailer>_<gender>_search_products.json` | Override the output path. The default keeps mens/womens runs from overwriting each other. |

#### Controlling how many names are searched

| Flag | Default | Meaning |
|------|---------|---------|
| `--limit=N` | all names | Take only the first N unique names from `--names-from`. Each name becomes **one search bar interaction** (type the name, press Enter, scrape the results page). So `--limit=3` means 3 searches — not 3 products. Each of those 3 searches can still yield many pages of results with many products each. Has no effect with `--name`. |

> **`--limit` vs `--max-products`:** `--limit=3` controls how many *times you search* (3 browser interactions, potentially hundreds of products). `--max-products=3` controls how many *products you keep per search* (all searches run, but each result is trimmed to 3). They are orthogonal. Example with an 83-name Hype DC file:
>
> | Flags | Searches run | Products kept |
> |-------|-------------|---------------|
> | *(none)* | 83 | all (~60/search typical) |
> | `--limit=3` | 3 | all from those 3 searches |
> | `--max-products=3` | 83 | up to 3 per search (≤249 total) |
> | `--limit=3 --max-products=3` | 3 | up to 3 per search (≤9 total) |

#### Controlling how much is scraped per search result

Each search term resolves to a results page (e.g. `?q=Nike+Air+Max+90`). The following flags control how deeply that results page is scraped.

| Flag | Default | Meaning |
|------|---------|---------|
| `--max-pages=N` | `3` | Number of listing pages to fetch per search result. Search-result pages are short (typically 12–24 cards), so 3 pages covers most queries. Raise this if you need exhaustive coverage; lower it for speed. |
| `--limit-per-page=N` | all cards | Maximum products scraped **per listing page**. Applied inside the retailer's own page-scraper before any product detail pages (PDPs) are visited. Useful when combined with `--max-pages` to tightly control how many PDPs are hit in total (e.g. `--max-pages=2 --limit-per-page=5` = at most 10 PDPs across two pages). |
| `--max-products=N` | all | Maximum products **kept per search result**, counted after all pages have been scraped. This is a post-scrape slice: the scraper finishes walking pages normally, then trims the list to N before the merge/de-dupe step. Use this when you want a fixed-size result regardless of how many pages or cards were found (e.g. `--max-products=5` keeps the top 5 results from however many pages). |

**How the three scrape-limit flags interact:**

```
For each search term:
  ┌─ walk up to --max-pages pages ──────────────────────────────────────────┐
  │  for each page:                                                          │
  │    scrape up to --limit-per-page cards  (skips remaining cards on page) │
  │  → produces a list of products                                           │
  │                                                                          │
  │  slice [:--max-products]                (trims the final list)           │
  └──────────────────────────────────────────────────────────────────────────┘
  → result list per term goes into the merge+de-dupe step
```

`--limit-per-page` and `--max-products` are independent: one caps at the page level, the other caps the final per-term total. You can use either, both, or neither.

#### Examples

```bash
cd sneaker-scout-backend

# Single smoke-test — one name, first page only, top 3 results
uv run python -m salomon.search_scraper \
    --name "Salomon XT-6" \
    --max-pages=1 \
    --max-products=3

# Bulk run limited to the first 5 names, 1 page each, at most 5 products per result
# (fast sanity check that the scraper is wired correctly before a full run)
PLATYPUS_HEADLESS=false uv run python -m platypus.search_scraper \
    --names-from=jsons/hypedc_mens_products.json --gender=mens \
    --limit=5 --max-pages=1 --max-products=5

# Full run — all names, default 3 pages, no per-result cap
JDSPORTS_HEADLESS=false uv run python -m jdsports.search_scraper \
    --names-from=jsons/hypedc_mens_products.json --gender=mens

# Full run with a per-result cap — keeps catalogue broad but avoids deep-scraping
# noisy results (e.g. "Nike Air Max 90" returning 60+ products from 3 pages)
FOOTLOCKER_HEADLESS=false uv run python -m footlocker.search_scraper \
    --names-from=jsons/hypedc_mens_products.json --gender=mens \
    --max-products=10

# Tight PDP budget — 2 pages × 4 cards = at most 8 PDPs per search term
# (useful when PDPs are slow or crash-prone, e.g. Footlocker in the container)
FOOTLOCKER_HEADLESS=false uv run python -m footlocker.search_scraper \
    --names-from=jsons/hypedc_mens_products.json --gender=mens \
    --max-pages=2 --limit-per-page=4
```

Environment variables go **before** `uv run`, e.g. headed HypeDC:
`HYPEDC_HEADLESS=false uv run python -m hypedc.search_scraper --name "..."`.

Output: `jsons/<retailer>_<gender>_search_products.json` (the gender suffix
keeps mens/womens runs from overwriting each other; override with `--out`).

### When a search scraper breaks

Edit that retailer's `search_scraper.py` — the `SEARCH_CONFIG`
`search_box_selectors` and `results_ready_selector` are the per-site knobs.
Run headed (`<RETAILER>_HEADLESS=false`) to watch where it stalls. Shared
navigation/orchestration lives in `utils/search_nav.py`; name extraction in
`utils/hype_names.py`; de-dupe in `utils/product_merge.py`.

### Verification status (as of 2026-06-16)

| Retailer | Search → URL | PDP scraping | Upload to staging | Notes |
|----------|-------------|--------------|-------------------|-------|
| **JD Sports** | ✓ | ✓ | ✓ | Fully verified |
| **Salomon** | ✓ | ✓ | ✗ not yet run | Selectors verified (sneaker_scout-bgk closed after 1-product smoke test); bulk scrape + upload runbook not completed — see sneaker_scout-0ul |
| **Footlocker** | ✓ | ⚠ crashes in container | not yet run | PDP loop hits Chrome memory limit after ~7 PDPs in headless container; works on macOS |
| **Platypus** | ✓ | ✓ | not yet run | Verified in an earlier session (sneaker_scout-0fm) |
| **HypeDC** | not tested | — | — | Requires headed Chrome + CAPTCHA solve; skip until other retailers confirmed |

**Known selector fixes applied** (do not revert):

- `jdsports/search_scraper.py` — box selector corrected to `input#srchInput`
  (was `input#searchTerm`, which never existed on jd-sports.com.au).
- `footlocker/search_scraper.py` — box selector corrected to
  `input#HeaderSearch--desktop_search_query`; added `results_url_marker="/search"`
  and `reload_after_url_marker=True`. Footlocker's search form uses SPA pushState
  navigation, so the product grid never renders in headless Chrome without a
  forced `driver.get()` reload after the URL flips.
- `utils/search_nav.py` — `_clear_box()` helper falls back to JS
  (`arguments[0].value = ''`) when Selenium's native `.clear()` raises
  `InvalidElementStateException`. Needed for Salomon's SearchSpring autocomplete
  input.

**Open issues (Platypus, from live debugging):**

1. **Search-results card parsing** — Platypus search-results cards have a
   different DOM than its category cards, so the listing parser can extract 0
   products on some search terms. May need a search-card extractor.
2. **Fuzzy relevance** — free-text search drifts (e.g. "Samba OG" returns
   Gazelle products). "Scrape all results as-is" can import the wrong shoes;
   a name-match relevance filter may be needed.

For JD Sports and Salomon, bulk `--names-from` runs are ready to go. For
Footlocker, run from macOS (not the dev container) to avoid the tab crash.

---

## Upload

Both modes feed the same uploader:

```bash
cd sneaker-scout-backend
uv run python -m data_upload.run_update --file=jsons/platypus_mens_products.json
uv run python -m data_upload.run_update --file=jsons/platypus_mens_search_products.json
```

---

## Upload validation runbook (agent-readable)

Use these steps to validate a scraped JSON file before promoting to production.
The steps below use jdsports as the example; substitute the retailer name and
JSON filename as needed.

### What `run_update` does

- Entrypoint: `uv run python -m data_upload.run_update --file=<json>`. Default
  path is bulk upsert (`bulk_upload.py`) — one upsert per table, ~7–10 round
  trips total. `--per-row` switches to the legacy `update_supabase_daily` loop
  (first-write-wins-on-name; slower) — use it only for bisecting a regression.
- Needs `.env` at `sneaker-scout-backend/.env` with `SUPABASE_URL` +
  `SUPABASE_SERVICE_KEY`. If missing, prints an error and returns `False`.
- One file = one retailer. The retailer is read from `data[0]["retailer"]` only
  — every item in the file is assumed to be the same retailer.
- Upsert order (FK-dependency order, each with a natural-key conflict target):
  `retailers (name)` → `brands (name)` → `sizes (us_size)` →
  `sneakers (brand_id, lookup_key)` → `colorways (sneaker_id, lookup_key)` →
  `prices (colorway_id, retailer_id)` → `price_history (append-only)` →
  `sneaker_sizes (colorway_id, size_id, retailer_id)`.
- Idempotent on identity; last-write-wins on display fields in bulk mode.
- `price_history` is append-only and conditional: a row is inserted only when
  the existing `prices` row has a different price than the new scrape.
- Non-US sizes are silently dropped; prices are regex-parsed from currency strings.
- Colorway collisions (same `colorway_lookup_key`, different display name, not
  in the registry) are queued to `jsons/pending_review.jsonl` with a WARNING —
  not auto-merged.

### Step 0 — confirm staging target

**Confirm `.env` points at the staging Supabase project** (the current project
in `sneaker-scout-backend/.env` is staging). Verify `SUPABASE_URL` before
running — this is a hard-to-reverse outward-facing write. Only promote to
production after staging validates cleanly.

### Step 1 — JSON shape preflight

Catches the known plural/singular key trap (`sneakers` vs `sneaker`):

```bash
cd sneaker-scout-backend
uv run python - <<'PY'
import json
d = json.load(open("jsons/jdsports_mens_search_products.json"))
assert d, "empty payload"
item = d[0]
required = {"brand", "sneaker", "colorway", "retailer", "prices"}
missing = required - item.keys()
print("missing keys:", missing or "none")
print("retailers in file:", {x["retailer"]["name"] for x in d})  # expect exactly one
print("sample price:", item["prices"].get("price"), item["prices"].get("original_price"))
PY
```

Keys must be singular (`sneaker`, not `sneakers`). Exactly one retailer name.
If keys are plural, `bulk_upload` raises a `KeyError` — fix the scraper output,
don't patch the uploader.

### Step 2 — run the upload; read the counts

```bash
cd sneaker-scout-backend
uv run python -m data_upload.run_update --file=jsons/jdsports_mens_search_products.json
```

Success prints:
```
Bulk upload complete: {retailers:1, brands:.., sneakers:.., colorways:.., prices:.., price_history:.., sneaker_sizes:..}
```

Sanity check: `sneakers`, `colorways`, and `prices` should all be > 0 and
roughly match the product count in the JSON. `sneaker_sizes: 0` means the
scraper didn't capture sizes — worth flagging but not necessarily fatal.

### Step 3 — idempotency check

Run the exact same file a second time. The returned counts should be the same
shape. Spot-check in Supabase that no new duplicate sneakers/colorways/prices
rows were created. `price_history` must not grow on an unchanged re-run.

### Step 4 — price_history smoke test

Hand-edit one product's price in the JSON, re-upload, and confirm exactly one
new `price_history` row appears for that `(colorway, retailer)` pair (and that
`is_on_sale`/`is_lowest_ever` on the `prices` row updated). This proves the
diff logic works end-to-end.

### Step 5 — spot-check rows in Supabase

For one known product, verify the FK chain in the SQL editor or REST:
`brands` → `sneakers` (correct `brand_id`, `lookup_key`) → `colorways`
(correct `sneaker_id`) → `prices` (links colorway + retailer, has
`product_url`, AUD, `is_available`). Confirm `sneaker_sizes` rows are present
if the scrape carried sizes.

### Step 6 — drain the colorway-collision queue

After the run, check for warnings and the queue file:

```bash
test -s jsons/pending_review.jsonl && wc -l jsons/pending_review.jsonl
uv run python -m data_upload.review_colorways   # interactive: s=same/alias, d=different, x=skip
```

Resolve each item, then commit `data_upload/colorway_overrides.yaml` so future
ingests don't re-flag them. (`pending_review.jsonl` is gitignored — never commit it.)

> **Agent note:** `review_colorways` is interactive and will block a headless
> agent. Surface the queue contents to a human rather than guessing merges.
> Do not attempt to automate this step.

### Step 7 — unit tests

```bash
cd sneaker-scout-backend
uv run python -m pytest tests/test_bulk_upload.py tests/test_canonicalize.py tests/test_sizes.py -q
```

### Definition of done (per retailer file)

- [ ] JSON passes shape preflight (singular keys, single retailer).
- [ ] `run_update` completes with non-zero, sane counts against staging.
- [ ] Re-running the same file creates no duplicates; `price_history` only grows on a real price change.
- [ ] Spot-checked row chain (`brand → sneaker → colorway → price`) is correct in Supabase.
- [ ] `pending_review.jsonl` reviewed; `colorway_overrides.yaml` committed if it changed.
- [ ] `test_bulk_upload` / `test_canonicalize` / `test_sizes` pass.
- [ ] Only then promote/run against production.

## Related docs

- `sneaker-scout-backend/CLAUDE.md` — "Running Scrapers" + "Search-driven
  scraping" sections (full env-var and strict-mode detail).
- `spec.yaml` — `x-scraper-cli.commands`: `search-scrape-local`,
  `search-scrape-bulk-from-hypedc`.
- `docs/superpowers/plans/2026-06-07-search-driven-scraper.md` — search design + plan.
