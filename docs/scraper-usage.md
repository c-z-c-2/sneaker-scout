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

```bash
cd sneaker-scout-backend

# Smoke-test a single name (headed, so you can watch the search)
PLATYPUS_HEADLESS=false uv run python -m platypus.search_scraper \
    --name "Samba OG" --max-pages=1

# Bulk: search every name auto-extracted from a Hype DC scrape (intended use)
uv run python -m platypus.search_scraper \
    --names-from=jsons/hypedc_mens_products.json --gender=mens
uv run python -m platypus.search_scraper \
    --names-from=jsons/hypedc_womens_products.json --gender=womens
```

### Flags

| Flag | Meaning |
|------|---------|
| `--name "<text>"` | Search a single name. Mutually exclusive with `--names-from`; one required. |
| `--names-from=<path>` | Auto-extract names from a Hype DC scrape JSON and search each. |
| `--gender=mens\|womens` | Tags scraped rows and sets the output filename suffix (default `mens`). |
| `--limit=N` | Only search the first N names from the list (quick smoke test of a bulk run). |
| `--max-pages=N` | Pages of results to scrape per search term (default 3). |
| `--out=<path>` | Override the output path. |

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

The navigation + orchestration + de-dupe are implemented and unit-tested, but
the search mode is **not yet verified working end-to-end on live sites**.
Known open issues from live Platypus debugging:

1. **Search-results card parsing** — Platypus's search-results cards have a
   different DOM than its category cards (image-anchor with the name in the
   `<img alt>` / href query string and no price text-block), so the listing
   parser can extract 0 products. Needs a search-card extractor.
2. **Fuzzy relevance** — free-text search drifts: searching "Samba OG"
   returned Gazelle products. "Scrape all results as-is" would import the
   wrong shoes, so a name-match relevance filter is likely needed.

Treat search bulk runs as tests, not trusted data pulls, until a smoke run is
confirmed to return correct, parsed products for the searched name.

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
