# Distilled recommendation: Hype DC mirror — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Beads issue:** `sneaker-scout-j26`
**Spec:** `docs/superpowers/specs/2026-05-23-distilled-recommendation-hype-mirror-design.md`

**Goal:** Replace the all-view's alphabetical sort with a burst-then-stripe interleave that mirrors Hype DC's listing order for the first 12 slots, then mixes in non-Hype items (ranked by steepest recent price drop) at every 4th position.

**Architecture:** Capture Hype's listing position during scrape; persist it as `prices.listing_rank` (one column on the existing `(colorway_id, retailer_id)` join table); fetch-all + client-side composite sort + striped interleave in the `useSneakers` hook.

**Tech Stack:** Python 3 / Selenium (scraper), Supabase Postgres (DB), Supabase CLI (migrations), TypeScript / React Query / Supabase JS (frontend), pytest (backend tests).

---

## File Structure

**Created:**
- `aussie-kicks-tracker/supabase/migrations/<timestamp>_add_listing_rank_to_prices.sql` — schema change
- `sneaker-scout-backend/tests/test_hypedc_listing_rank.py` — scraper unit tests
- `sneaker-scout-backend/tests/test_update_supabase_rank_pairs.py` — uploader helper tests
- `aussie-kicks-tracker/src/lib/rankInterleave.ts` — pure interleave function

**Modified:**
- `sneaker-scout-backend/hypedc/pagination_scraper.py` — thread `scrape_rank` through `scrape_all_pages` → `combine_product_info`
- `sneaker-scout-backend/data_upload/update_supabase_daily.py` — clear stale ranks; write `listing_rank` on insert/update
- `aussie-kicks-tracker/src/hooks/useSneakers.tsx` — fetch-all, compute Hype rank per sneaker, call `interleaveStriped`, paginate client-side
- `aussie-kicks-tracker/SITEMAP.md` — only if the Index page's data contract changes user-visibly (it shouldn't)
- `spec.yaml` — only if the `colorways → prices` select shape in useSneakers changes the documented example

---

## Conventions for all tasks

- All backend `python -m` invocations assume CWD = `/workspace/sneaker-scout-backend` with the venv active (`source .venv/bin/activate`). The plan invokes the venv binary directly to avoid shell-state issues.
- Each task ends with a per-issue commit referencing `sneaker-scout-j26` per `/workspace/CLAUDE.md`'s commit protocol.
- Backend tests live under `tests/` and run via `pytest`.
- The sneaker_scout Supabase project ID is `ltjxebklcstqnddspoxr`. Use the Supabase MCP `execute_sql` tool for verification queries; use `supabase` CLI for migrations.

---

## Task 1: DB migration — add `listing_rank` to `prices`

**Files:**
- Create: `aussie-kicks-tracker/supabase/migrations/<timestamp>_add_listing_rank_to_prices.sql`

- [ ] **Step 1: Generate the migration file via the Supabase CLI**

Run from `/workspace/aussie-kicks-tracker`:

```bash
cd /workspace/aussie-kicks-tracker
supabase migration new add_listing_rank_to_prices
```

This creates an empty SQL file at `supabase/migrations/<UTC-timestamp>_add_listing_rank_to_prices.sql`. Note the path it prints — you'll edit it next.

- [ ] **Step 2: Write the migration SQL**

Replace the empty file contents with exactly:

```sql
-- Add listing_rank to prices: the position this (colorway, retailer) occupied
-- in the retailer's listing page during the last scrape. 1 = first item on
-- page 1. NULL when not captured (most retailers; pre-scrape rows).
ALTER TABLE prices ADD COLUMN listing_rank int NULL;

COMMENT ON COLUMN prices.listing_rank IS
  'Position this colorway occupied in the retailer''s listing page on the last scrape (1 = first). NULL when not captured. Refreshed wholesale per (retailer, gender) on every scrape run.';
```

- [ ] **Step 3: Apply the migration to the remote project**

The dev workflow on this repo applies directly via the MCP. From the agent context, call the Supabase MCP `apply_migration` tool with:

```
project_id: ltjxebklcstqnddspoxr
name: add_listing_rank_to_prices
query: <contents of the SQL file from Step 2>
```

If the migration tool isn't available, use the Supabase dashboard SQL editor or `supabase db push` from `/workspace/aussie-kicks-tracker`.

- [ ] **Step 4: Verify the column exists**

Via Supabase MCP `execute_sql`:

```sql
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'prices' AND column_name = 'listing_rank';
```

Expected: one row, `listing_rank`, `integer`, `YES`.

- [ ] **Step 5: Verify no advisor regressions**

Via Supabase MCP `get_advisors` with `type=security`, then `type=performance`. Expected: no new errors. (Adding a nullable column does not change RLS posture and creates no index issues.)

- [ ] **Step 6: Commit**

```bash
cd /workspace/aussie-kicks-tracker
git add supabase/migrations/
git commit -m "$(cat <<'EOF'
feat(sneaker_scout-j26): add listing_rank column to prices

Stores the position a (colorway, retailer) occupied in the retailer's
listing page during the last scrape. Backend will populate from the
Hype DC scraper; useSneakers will sort on it.

Closes: nothing yet — implementation tracked under sneaker_scout-j26
EOF
)"
```

---

## Task 2: Backend — `combine_product_info` accepts `scrape_rank`

**Files:**
- Modify: `/workspace/sneaker-scout-backend/hypedc/pagination_scraper.py` (around lines 286-363)
- Create: `/workspace/sneaker-scout-backend/tests/test_hypedc_listing_rank.py`

- [ ] **Step 1: Write the failing test**

Create `/workspace/sneaker-scout-backend/tests/test_hypedc_listing_rank.py` with:

```python
"""Tests for the listing_rank flow through the Hype DC scraper.

The scraper walks Hype's listing pages in DOM order and we want to
preserve that order downstream as a sortable rank on the prices row.
These tests pin the threading: combine_product_info exposes the rank
on the prices dict, and scrape_all_pages assigns 1..N over the full
product sequence (not per-page-resetting)."""

from hypedc.pagination_scraper import combine_product_info


RETAILER = {
    "name": "Hype DC",
    "website_url": "https://www.hypedc.com/au",
    "logo_url": "https://www.hypedc.com/au/public/icons/favicon.png",
}


def test_combine_product_info_emits_listing_rank_when_provided():
    basic = {
        "url": "https://www.hypedc.com/au/products/example",
        "brand": "New Balance",
        "name": "9060 Black",
        "price": "$239.99",
        "original_price": "$239.99",
        "image_url": "https://media.hypedc.com/example.jpg",
    }
    detailed = {
        "name": "New Balance 9060 Black",
        "model": "9060",
        "brand": {"name": "New Balance", "logo_url": ""},
        "colorway": {
            "name": "Black",
            "color_code": "",
            "image_url": "https://media.hypedc.com/example.jpg",
        },
        "price": "$239.99",
        "original_price": "$239.99",
        "sizes": [],
        "is_available": True,
    }

    combined = combine_product_info(basic, detailed, RETAILER, "mens", scrape_rank=7)

    assert combined["prices"]["listing_rank"] == 7


def test_combine_product_info_omits_listing_rank_when_not_provided():
    """Backwards compatibility: callers that don't pass scrape_rank get
    None in the output, which the uploader will map to a NULL DB value."""
    combined = combine_product_info({}, {}, RETAILER, "mens")
    assert combined["prices"]["listing_rank"] is None
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /workspace/sneaker-scout-backend
/workspace/sneaker-scout-backend/.venv/bin/python -m pytest tests/test_hypedc_listing_rank.py -v
```

Expected: FAIL — `combine_product_info()` doesn't accept `scrape_rank` (TypeError on the first test) and current output has no `listing_rank` key.

- [ ] **Step 3: Update `combine_product_info` signature and output**

In `/workspace/sneaker-scout-backend/hypedc/pagination_scraper.py`, change the function at line 286.

Find:

```python
def combine_product_info(basic, detailed, retailer, gender):
```

Replace with:

```python
def combine_product_info(basic, detailed, retailer, gender, scrape_rank=None):
```

Then in the `"prices": { … }` dict at lines 344-360, add `"listing_rank": scrape_rank,` as the last key before the closing brace. The block should read:

```python
        "prices": {
            "price": price,
            "original_price": original_price,
            "currency": "AUD",
            # If the detail page hydrated and reported availability, trust
            # it. If hydration timed out (no sizes, no detail price) but
            # the listing card surfaced a price, the product exists and
            # has at least one purchasable variant — default True rather
            # than the misleading "out of stock" the listing already
            # disproved.
            "is_available": (
                detailed["is_available"]
                if "is_available" in detailed and (detailed.get("sizes") or detailed.get("price"))
                else bool(price)
            ),
            "product_url": basic.get("url", ""),
            "listing_rank": scrape_rank,
        },
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /workspace/sneaker-scout-backend
/workspace/sneaker-scout-backend/.venv/bin/python -m pytest tests/test_hypedc_listing_rank.py -v
```

Expected: PASS — both tests green.

- [ ] **Step 5: Run the broader hypedc suite to confirm no regression**

```bash
cd /workspace/sneaker-scout-backend
/workspace/sneaker-scout-backend/.venv/bin/python -m pytest tests/test_hypedc_brand_extraction.py tests/test_hypedc_unit_lock.py tests/test_hypedc_listing_rank.py -v
```

Expected: all green. The signature change is backwards-compatible (`scrape_rank` defaults to None).

- [ ] **Step 6: Commit**

```bash
cd /workspace/sneaker-scout-backend
git add hypedc/pagination_scraper.py tests/test_hypedc_listing_rank.py
git commit -m "$(cat <<'EOF'
feat(sneaker_scout-j26): combine_product_info threads listing_rank

Optional scrape_rank kwarg surfaces on prices.listing_rank in the
output JSON. Other retailers' uploaders see None and skip the field
on insert/update.

Closes: nothing yet — implementation tracked under sneaker_scout-j26
EOF
)"
```

---

## Task 3: Backend — `scrape_all_pages` assigns a running rank

**Files:**
- Modify: `/workspace/sneaker-scout-backend/hypedc/pagination_scraper.py` (around lines 422-544)
- Modify: `/workspace/sneaker-scout-backend/tests/test_hypedc_listing_rank.py` (add a new test)

- [ ] **Step 1: Write the failing test**

Append to `/workspace/sneaker-scout-backend/tests/test_hypedc_listing_rank.py`:

```python
def test_scrape_via_static_fallback_assigns_running_ranks(monkeypatch):
    """The dev-time static-fallback path is the only easily-exercisable
    end-to-end slice of scrape_all_pages (no Selenium required). We use
    it as a proxy: the rank counter should start at 1 and increment for
    every product appended, regardless of which fixture page it came from."""
    from hypedc import pagination_scraper as ps

    # Stub the fixtures so we get a deterministic shape: three basic
    # entries, no detail HTML available (so combine_product_info falls
    # back to listing-only data).
    monkeypatch.setattr(ps, "setup_driver", lambda: (_ for _ in ()).throw(RuntimeError("no chrome")))
    monkeypatch.setattr(
        ps.static_fallback, "load_listing_html", lambda: "<html></html>"
    )
    monkeypatch.setattr(
        ps, "parse_listing_page",
        lambda html: [
            {"url": f"https://example.test/p{i}", "brand": "B", "name": f"P{i}",
             "price": "$100", "original_price": "$100", "image_url": ""}
            for i in range(1, 4)
        ],
    )
    monkeypatch.setattr(ps.static_fallback, "load_detail_html_for", lambda url: None)

    products = ps.scrape_all_pages(
        base_url=ps.LISTING_URLS["mens"],
        retailer=RETAILER,
        gender="mens",
        max_pages=1,
        max_products_per_page=999,
        strict_errors=False,
    )

    assert len(products) == 3
    ranks = [p["prices"]["listing_rank"] for p in products]
    assert ranks == [1, 2, 3]
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /workspace/sneaker-scout-backend
/workspace/sneaker-scout-backend/.venv/bin/python -m pytest tests/test_hypedc_listing_rank.py::test_scrape_via_static_fallback_assigns_running_ranks -v
```

Expected: FAIL — every product gets `listing_rank=None` because `scrape_all_pages` and `_scrape_via_static_fallback` don't pass `scrape_rank`.

- [ ] **Step 3: Thread the counter through the live scrape path**

In `/workspace/sneaker-scout-backend/hypedc/pagination_scraper.py`, modify `scrape_all_pages` (around line 422). Find the existing `all_products = []` line (around line 459) and replace the block from there through the inner loop with this — the changes are: introduce `scrape_rank` counter, pass it into `combine_product_info`, increment after each append.

Find:

```python
    all_products = []
    try:
        for page_num in range(1, max_pages + 1):
```

Replace with:

```python
    all_products = []
    scrape_rank = 1  # Position in the running scrape; 1 = first product on page 1.
    try:
        for page_num in range(1, max_pages + 1):
```

Then inside the per-product loop, find this line (around line 532):

```python
                combined = combine_product_info(basic, detailed, retailer, gender)
                all_products.append(combined)
                time.sleep(2)
```

Replace with:

```python
                combined = combine_product_info(
                    basic, detailed, retailer, gender, scrape_rank=scrape_rank
                )
                all_products.append(combined)
                scrape_rank += 1
                time.sleep(2)
```

- [ ] **Step 4: Thread the counter through the static-fallback path**

In the same file, find `_scrape_via_static_fallback` (around line 392) — specifically the inner loop:

```python
    products = []
    for basic in basics[:max_products]:
        product_url = basic.get("url", "")
        detail_html = static_fallback.load_detail_html_for(product_url)
        if not detail_html:
            # No detail fixture — surface what we got from the listing.
            detailed = {}
        else:
            detailed = parse_detail_html(
                detail_html,
                product_url,
                retailer,
                basic_brand_name=basic.get("brand", ""),
            )
        combined = combine_product_info(basic, detailed, retailer, gender)
        products.append(combined)
    return products
```

Replace with:

```python
    products = []
    scrape_rank = 1
    for basic in basics[:max_products]:
        product_url = basic.get("url", "")
        detail_html = static_fallback.load_detail_html_for(product_url)
        if not detail_html:
            # No detail fixture — surface what we got from the listing.
            detailed = {}
        else:
            detailed = parse_detail_html(
                detail_html,
                product_url,
                retailer,
                basic_brand_name=basic.get("brand", ""),
            )
        combined = combine_product_info(
            basic, detailed, retailer, gender, scrape_rank=scrape_rank
        )
        products.append(combined)
        scrape_rank += 1
    return products
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd /workspace/sneaker-scout-backend
/workspace/sneaker-scout-backend/.venv/bin/python -m pytest tests/test_hypedc_listing_rank.py -v
```

Expected: PASS — all three tests in the file green.

- [ ] **Step 6: Run the broader hypedc suite to confirm no regression**

```bash
cd /workspace/sneaker-scout-backend
/workspace/sneaker-scout-backend/.venv/bin/python -m pytest tests/ -k hypedc -v
```

Expected: all hypedc tests green.

- [ ] **Step 7: Commit**

```bash
cd /workspace/sneaker-scout-backend
git add hypedc/pagination_scraper.py tests/test_hypedc_listing_rank.py
git commit -m "$(cat <<'EOF'
feat(sneaker_scout-j26): scrape_all_pages assigns running listing_rank

Counter starts at 1 on page 1 product 1, increments per appended
product. Static-fallback path mirrors the live path so dev runs with
no Chrome still produce a rank-enriched JSON.

Closes: nothing yet — implementation tracked under sneaker_scout-j26
EOF
)"
```

---

## Task 4: Backend — extract `_listing_rank_pairs()` helper

**Files:**
- Modify: `/workspace/sneaker-scout-backend/data_upload/update_supabase_daily.py`
- Create: `/workspace/sneaker-scout-backend/tests/test_update_supabase_rank_pairs.py`

The uploader will need to know which `(retailer_name, gender)` combinations carry ranks in this run — those are the slices it should clear before upserting. Extracting this as a pure helper makes it unit-testable without mocking Supabase.

- [ ] **Step 1: Write the failing test**

Create `/workspace/sneaker-scout-backend/tests/test_update_supabase_rank_pairs.py` with:

```python
"""Unit tests for _listing_rank_pairs(): identifies which (retailer, gender)
slices need their listing_rank cleared before upserting a run's data."""

from data_upload.update_supabase_daily import _listing_rank_pairs


def _item(retailer_name, gender, rank):
    return {
        "retailer": {"name": retailer_name},
        "colorway": {"gender": gender},
        "prices": {"listing_rank": rank},
    }


def test_returns_unique_retailer_gender_pairs_with_ranks():
    data = [
        _item("Hype DC", "mens", 1),
        _item("Hype DC", "mens", 2),
        _item("Hype DC", "mens", 3),
    ]
    assert _listing_rank_pairs(data) == {("Hype DC", "mens")}


def test_handles_multiple_retailers_and_genders():
    data = [
        _item("Hype DC", "mens", 1),
        _item("Hype DC", "womens", 1),
        _item("Foot Locker", "mens", 1),
    ]
    assert _listing_rank_pairs(data) == {
        ("Hype DC", "mens"),
        ("Hype DC", "womens"),
        ("Foot Locker", "mens"),
    }


def test_ignores_items_without_listing_rank():
    """Other retailers' uploads emit listing_rank=None — those slices
    should not be cleared. Returning an empty set means the upload skips
    the reset step entirely."""
    data = [
        _item("Platypus Shoes", "mens", None),
        {"retailer": {"name": "JD Sports"}, "colorway": {"gender": "womens"},
         "prices": {}},  # listing_rank key missing entirely
    ]
    assert _listing_rank_pairs(data) == set()


def test_handles_mixed_ranked_and_unranked_within_one_upload():
    """A defensive shape: even if a Hype run had a parse error on one
    product and emitted no rank, we still want to clear-and-reset the
    Hype/mens slice based on the other ranked items in the same upload."""
    data = [
        _item("Hype DC", "mens", 1),
        _item("Hype DC", "mens", None),
        _item("Hype DC", "mens", 2),
    ]
    assert _listing_rank_pairs(data) == {("Hype DC", "mens")}


def test_empty_input():
    assert _listing_rank_pairs([]) == set()
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /workspace/sneaker-scout-backend
/workspace/sneaker-scout-backend/.venv/bin/python -m pytest tests/test_update_supabase_rank_pairs.py -v
```

Expected: FAIL — `_listing_rank_pairs` is not defined yet (ImportError).

- [ ] **Step 3: Implement the helper**

In `/workspace/sneaker-scout-backend/data_upload/update_supabase_daily.py`, just before the `def insert_or_update_data(supabase, data):` function (around line 168), add:

```python
def _listing_rank_pairs(data):
    """Return the unique (retailer_name, colorway_gender) pairs in this
    upload that carry a non-null listing_rank. The uploader uses this to
    clear stale ranks from previous runs for exactly those slices before
    upserting the new rows. Items without listing_rank are ignored so
    non-Hype retailers don't trigger a reset on tables they don't rank."""
    pairs = set()
    for item in data:
        rank = (item.get("prices") or {}).get("listing_rank")
        if rank is None:
            continue
        retailer_name = (item.get("retailer") or {}).get("name")
        gender = (item.get("colorway") or {}).get("gender")
        if retailer_name and gender:
            pairs.add((retailer_name, gender))
    return pairs
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /workspace/sneaker-scout-backend
/workspace/sneaker-scout-backend/.venv/bin/python -m pytest tests/test_update_supabase_rank_pairs.py -v
```

Expected: all 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
cd /workspace/sneaker-scout-backend
git add data_upload/update_supabase_daily.py tests/test_update_supabase_rank_pairs.py
git commit -m "$(cat <<'EOF'
feat(sneaker_scout-j26): _listing_rank_pairs helper for upload reset

Pure helper that identifies which (retailer, gender) slices in an
upload batch carry listing_rank, so the uploader can clear exactly
those slices before upserting. Other retailers' uploads pass through
unchanged.

Closes: nothing yet — implementation tracked under sneaker_scout-j26
EOF
)"
```

---

## Task 5: Backend — uploader writes `listing_rank` on insert/update

**Files:**
- Modify: `/workspace/sneaker-scout-backend/data_upload/update_supabase_daily.py` (around lines 355-385)

This task adds the column to the SQL writes only — the reset step comes in Task 6. We split them so each commit is a single coherent change.

- [ ] **Step 1: Add `listing_rank` to the prices insert**

In `update_supabase_daily.py`, find the insert at lines 357-368:

```python
            if not price_response.data:
                # Insert new price
                supabase.table("prices").insert({
                    "colorway_id": colorway_id,
                    "retailer_id": retailer_id,
                    "price": decimal_to_float(price),
                    "original_price": decimal_to_float(original_price),
                    "currency": price_data["currency"],
                    "is_available": price_data.get("is_available", True),
                    "product_url": price_data["product_url"]
                }).execute()
                logger.info(f"Inserted price: {price} {price_data['currency']}")
```

Replace with:

```python
            if not price_response.data:
                # Insert new price
                supabase.table("prices").insert({
                    "colorway_id": colorway_id,
                    "retailer_id": retailer_id,
                    "price": decimal_to_float(price),
                    "original_price": decimal_to_float(original_price),
                    "currency": price_data["currency"],
                    "is_available": price_data.get("is_available", True),
                    "product_url": price_data["product_url"],
                    "listing_rank": price_data.get("listing_rank"),
                }).execute()
                logger.info(f"Inserted price: {price} {price_data['currency']}")
```

- [ ] **Step 2: Add `listing_rank` to the prices update**

Find the update block at lines 378-385:

```python
                # Update price
                supabase.table("prices").update({
                    "price": decimal_to_float(price),
                    "original_price": decimal_to_float(original_price),
                    "currency": price_data["currency"],
                    "is_available": price_data.get("is_available", True),
                    "product_url": price_data["product_url"],
                    "last_updated": datetime.now().isoformat()
                }).eq("id", price_id).execute()
```

Replace with:

```python
                # Update price
                supabase.table("prices").update({
                    "price": decimal_to_float(price),
                    "original_price": decimal_to_float(original_price),
                    "currency": price_data["currency"],
                    "is_available": price_data.get("is_available", True),
                    "product_url": price_data["product_url"],
                    "listing_rank": price_data.get("listing_rank"),
                    "last_updated": datetime.now().isoformat()
                }).eq("id", price_id).execute()
```

- [ ] **Step 3: Sanity-check by syntax-importing the module**

This catches typos before we exercise it end-to-end.

```bash
cd /workspace/sneaker-scout-backend
/workspace/sneaker-scout-backend/.venv/bin/python -c "from data_upload import update_supabase_daily; print('ok')"
```

Expected: prints `ok` and exits 0.

- [ ] **Step 4: Run the existing test suite to confirm no regression**

```bash
cd /workspace/sneaker-scout-backend
/workspace/sneaker-scout-backend/.venv/bin/python -m pytest tests/test_update_supabase_rank_pairs.py tests/test_hypedc_listing_rank.py -v
```

Expected: all green.

- [ ] **Step 5: Commit**

```bash
cd /workspace/sneaker-scout-backend
git add data_upload/update_supabase_daily.py
git commit -m "$(cat <<'EOF'
feat(sneaker_scout-j26): uploader writes listing_rank to prices

Threads the scraper's listing_rank value through into both insert
and update paths. Other retailers' uploads pass None, which the DB
stores as NULL (the column default).

Closes: nothing yet — implementation tracked under sneaker_scout-j26
EOF
)"
```

---

## Task 6: Backend — uploader clears stale ranks before upsert

**Files:**
- Modify: `/workspace/sneaker-scout-backend/data_upload/update_supabase_daily.py` (the `main()` function, around lines 511-518)

Without this step, products that fell out of the Hype listing's top N keep their old rank from the previous run and continue dominating the listing — exactly the staleness the spec warns about.

- [ ] **Step 1: Add a `_reset_listing_ranks_for_pairs` function**

In `update_supabase_daily.py`, add this function immediately below the `_listing_rank_pairs` helper from Task 4:

```python
def _reset_listing_ranks_for_pairs(supabase, pairs):
    """For each (retailer_name, gender) in pairs, set listing_rank=NULL on
    every prices row whose retailer matches and whose colorway has that
    gender. Run before upserting the new ranks so products that fell out
    of the listing don't keep stale ranks from the previous run.

    Logs the affected row count per slice. Silently skips a pair if the
    retailer or colorway lookup yields no rows (e.g. first-ever run for
    that retailer)."""
    for retailer_name, gender in pairs:
        retailer_resp = supabase.table("retailers").select("id").eq("name", retailer_name).execute()
        if not retailer_resp.data:
            logger.warning(
                "Listing-rank reset skipped: retailer %r not in DB yet", retailer_name
            )
            continue
        retailer_id = retailer_resp.data[0]["id"]

        cw_resp = supabase.table("colorways").select("id").eq("gender", gender).execute()
        cw_ids = [r["id"] for r in (cw_resp.data or [])]
        if not cw_ids:
            logger.info(
                "Listing-rank reset skipped: no colorways with gender=%r yet", gender
            )
            continue

        # Batch the IN clause — PostgREST has a URL-length cap. 200 IDs
        # per chunk fits comfortably under typical 8KB limits.
        for chunk_start in range(0, len(cw_ids), 200):
            chunk = cw_ids[chunk_start:chunk_start + 200]
            supabase.table("prices").update({"listing_rank": None}) \
                .eq("retailer_id", retailer_id) \
                .in_("colorway_id", chunk) \
                .execute()

        logger.info(
            "Listing-rank reset: retailer=%s gender=%s colorways=%d",
            retailer_name, gender, len(cw_ids),
        )
```

- [ ] **Step 2: Wire the reset into `main()` before `insert_or_update_data`**

Find the section in `main()` around lines 514-517:

```python
        logger.info(f"Loaded {len(data)} products from {json_file_path}")
        
        # Insert or update data in Supabase
        products_processed = insert_or_update_data(supabase, data)
```

Replace with:

```python
        logger.info(f"Loaded {len(data)} products from {json_file_path}")

        # Clear stale listing_ranks for every (retailer, gender) slice this
        # upload is about to repopulate. Without this, products that fell
        # out of the listing's top N keep dominating the all-view forever.
        rank_pairs = _listing_rank_pairs(data)
        if rank_pairs:
            _reset_listing_ranks_for_pairs(supabase, rank_pairs)

        # Insert or update data in Supabase
        products_processed = insert_or_update_data(supabase, data)
```

- [ ] **Step 3: Syntax-import sanity check**

```bash
cd /workspace/sneaker-scout-backend
/workspace/sneaker-scout-backend/.venv/bin/python -c "from data_upload import update_supabase_daily; print('ok')"
```

Expected: prints `ok`.

- [ ] **Step 4: End-to-end verification via a small ranked upload**

We need to actually exercise the reset against the real DB. Use the most recent canonical Hype DC JSON if it exists:

```bash
ls -la /workspace/sneaker-scout-backend/jsons/ | grep hypedc
```

If a recent `hypedc_<gender>_products.json` exists from prior scrapes, the JSON predates the listing_rank field and won't actually exercise the new path. In that case skip ahead to Step 5.

If you want to verify the path end-to-end with a fresh ranked JSON, run a small scrape first (requires Chrome on host — fine in dev, skip in CI):

```bash
cd /workspace/sneaker-scout-backend
HYPEDC_HEADLESS=false /workspace/sneaker-scout-backend/.venv/bin/python -m hypedc.pagination_scraper --gender=mens
```

Then upload:

```bash
cd /workspace/sneaker-scout-backend
/workspace/sneaker-scout-backend/.venv/bin/python -m data_upload.run_update --file=jsons/hypedc_mens_products.json
```

Expected log line: `Listing-rank reset: retailer=Hype DC gender=mens colorways=<N>` before the per-product insert/update lines.

- [ ] **Step 5: Verify ranks landed in the DB**

Via Supabase MCP `execute_sql`:

```sql
SELECT COUNT(*) FILTER (WHERE listing_rank IS NOT NULL) AS ranked,
       COUNT(*) AS total,
       MIN(listing_rank), MAX(listing_rank)
FROM prices p
JOIN retailers r ON r.id = p.retailer_id
JOIN colorways c ON c.id = p.colorway_id
WHERE r.name = 'Hype DC' AND c.gender = 'mens';
```

If you ran the end-to-end scrape+upload in Step 4: expected `ranked > 0`, min=1, max ≈ count of unique products on Hype's first 3 mens pages. If you skipped: expected `ranked = 0` (no Hype upload has run yet against the new schema) — the reset code is exercised on the next live Hype upload.

- [ ] **Step 6: Commit**

```bash
cd /workspace/sneaker-scout-backend
git add data_upload/update_supabase_daily.py
git commit -m "$(cat <<'EOF'
feat(sneaker_scout-j26): clear stale listing_ranks before each upload

main() now computes the (retailer, gender) pairs being upserted and
NULLs their existing listing_rank values first, so products that fell
out of the listing's top N don't keep dominating the all-view.
Batched in chunks of 200 colorway IDs to stay under PostgREST URL caps.

Closes: nothing yet — implementation tracked under sneaker_scout-j26
EOF
)"
```

---

## Task 7: Frontend — pure `interleaveStriped` function

**Files:**
- Create: `/workspace/aussie-kicks-tracker/src/lib/rankInterleave.ts`

This is the testable core. We isolate it from React Query / Supabase so it stays a pure transformation: input is a flat list of `(sneaker, hypeRank, priceChange)` tuples, output is an ordered list of sneakers ready to paginate. Frontend has no test runner today, so we keep the function small, well-named, and well-commented; a follow-up bd issue (filed in Task 10) will add vitest and proper unit tests.

- [ ] **Step 1: Create the file with the function**

Create `/workspace/aussie-kicks-tracker/src/lib/rankInterleave.ts` with:

```typescript
import type { Sneaker } from '@/hooks/useSneakers';

export interface RankedSneaker {
  sneaker: Sneaker;
  /** Hype DC listing rank for the active gender filter, or null if not on Hype. */
  hypeRank: number | null;
  /** Most-recent price delta (latest - previous). Negative = price drop. */
  priceChange: number;
}

export interface InterleaveOptions {
  /** Number of leading slots reserved exclusively for Hype-ranked items. */
  burstSize: number;
  /** After the burst: N Hype items per 1 fallback item. 3 → "3 Hype, 1 fallback". */
  stripeRatio: number;
}

const DEFAULT_OPTIONS: InterleaveOptions = { burstSize: 12, stripeRatio: 3 };

/**
 * Order sneakers so the first `burstSize` slots are pure Hype-ranked
 * items (in Hype's order), then alternate `stripeRatio` Hype items
 * with 1 fallback item until one queue exhausts. The fallback queue
 * is ordered by `priceChange` ascending (most-negative first).
 *
 * When either queue empties mid-stripe, the remaining slots are
 * filled from the other queue — no gaps.
 *
 * Pure function: same inputs always produce the same output. Safe to
 * call from a React Query `select` or inline in the hook.
 */
export function interleaveStriped(
  ranked: RankedSneaker[],
  options: Partial<InterleaveOptions> = {},
): Sneaker[] {
  const { burstSize, stripeRatio } = { ...DEFAULT_OPTIONS, ...options };

  const hype = ranked
    .filter((r) => r.hypeRank !== null)
    .sort((a, b) => (a.hypeRank as number) - (b.hypeRank as number));
  const fallback = ranked
    .filter((r) => r.hypeRank === null)
    .sort((a, b) => a.priceChange - b.priceChange);

  const out: Sneaker[] = [];
  let position = 0;

  while (hype.length > 0 || fallback.length > 0) {
    const inBurst = position < burstSize;
    // After the burst, slot index relative to the start of the stripe
    // cycle. A cycle is (stripeRatio Hype items) + (1 fallback item),
    // so cycle length = stripeRatio + 1.
    const stripeSlot = (position - burstSize) % (stripeRatio + 1);
    const wantFallback = !inBurst && stripeSlot === stripeRatio;

    if (wantFallback && fallback.length > 0) {
      out.push(fallback.shift()!.sneaker);
    } else if (hype.length > 0) {
      out.push(hype.shift()!.sneaker);
    } else if (fallback.length > 0) {
      // Burst slot or stripe-Hype slot but no Hype left — fill from
      // fallback rather than emit a gap.
      out.push(fallback.shift()!.sneaker);
    }
    position += 1;
  }

  return out;
}
```

- [ ] **Step 2: Sanity-check by running tsc through the existing build pipeline**

The project uses Vite which type-checks via tsc as part of `npm run build`. Running a full build is overkill for one file; instead, lean on the editor's tsc or run a targeted typecheck:

```bash
cd /workspace/aussie-kicks-tracker
npx tsc --noEmit -p tsconfig.json 2>&1 | tail -10
```

Expected: no errors mentioning `src/lib/rankInterleave.ts`. (Other parts of the codebase may emit pre-existing warnings; only the new file's lines should be clean.)

- [ ] **Step 3: Spot-check the logic with a quick repl**

Since there's no vitest, do a one-shot inline sanity check. From `/workspace/aussie-kicks-tracker`:

```bash
cd /workspace/aussie-kicks-tracker
npx tsx -e "
import { interleaveStriped } from './src/lib/rankInterleave';
const mk = (id: string, rank: number | null, drop = 0) => ({
  sneaker: { id, name: id } as any,
  hypeRank: rank,
  priceChange: drop,
});
const ranked = [
  ...Array.from({length: 20}, (_, i) => mk('H' + (i+1), i+1)),
  ...Array.from({length: 5}, (_, i) => mk('F' + (i+1), null, -10 * (i+1))),
];
const ordered = interleaveStriped(ranked);
console.log(ordered.map((s: any) => s.id).join(' '));
" 2>&1
```

If `tsx` isn't installed (project hasn't added it), substitute with a one-off node import via the ts-node path or just review the code visually — the function is short. Don't add tsx as a dependency for this one check.

Expected output, with burstSize=12 and stripeRatio=3:

```
H1 H2 H3 H4 H5 H6 H7 H8 H9 H10 H11 H12 H13 H14 H15 F1 H16 H17 H18 F2 H19 H20 ...
```

Reading: slots 1-12 are pure Hype (H1..H12), slot 13 starts the stripe — three Hype then one fallback then three Hype then one fallback, etc. F1 must land at slot 16 (index 15 in 0-based: position 15 = position - burstSize = 3 = stripeRatio, so fallback). F2 at slot 20. F3 at slot 24.

- [ ] **Step 4: Commit**

```bash
cd /workspace/aussie-kicks-tracker
git add src/lib/rankInterleave.ts
git commit -m "$(cat <<'EOF'
feat(sneaker_scout-j26): pure interleaveStriped sort for all-view

Takes [{ sneaker, hypeRank, priceChange }] and returns sneakers in
burst-then-stripe order: first 12 slots are pure Hype-ranked items,
then 3 Hype : 1 fallback. Fallback items ordered by steepest
price drop. Gap-free when either queue exhausts mid-stripe.

Pure transformation — no React or Supabase dependencies; ready to
unit-test once vitest is wired up (follow-up issue).

Closes: nothing yet — implementation tracked under sneaker_scout-j26
EOF
)"
```

---

## Task 8: Frontend — wire `useSneakers` to use `interleaveStriped`

**Files:**
- Modify: `/workspace/aussie-kicks-tracker/src/hooks/useSneakers.tsx` (lines 50-301, the `useSneakers` hook)

The hook currently does server-side `.order('name').range(offset, limit)`. We change to fetch-all + client-side composite sort + paginate-after-sort. The retailer/size/gender filters stay server-side because they actually reduce the row count.

- [ ] **Step 1: Update the embedded select to include `listing_rank` and the Hype retailer ID**

Find the colorway-select construction block in `useSneakers.tsx` (lines 76-87):

```typescript
      let colorwaySelect: string;
      if (hasSizeFilter) {
        colorwaySelect =
          'colorways!inner(id, name, color_code, image_url, gender, sneaker_sizes!inner(retailer_id, is_available, sizes!inner(us_size)))';
      } else if (wantInnerColorways) {
        colorwaySelect =
          'colorways!inner(id, name, color_code, image_url, gender' +
          (hasRetailerFilter ? ', prices!inner(retailer_id, is_available)' : '') +
          ')';
      } else {
        colorwaySelect = 'colorways(id, name, color_code, image_url, gender)';
      }
```

Replace with — note we always embed `prices(retailer_id, listing_rank)` so the client-side sort can read Hype's rank regardless of filter state:

```typescript
      // Always embed prices(retailer_id, listing_rank) — the client-side
      // sort needs it. When a retailer filter is active we still inner-
      // join to reduce the row set, otherwise it's a left-style embed.
      //
      // Caveat: when the active retailer filter excludes Hype DC, the
      // embedded prices rows will not include Hype's listing_rank (inner
      // join filters them out). In that case every sneaker becomes a
      // fallback item and the list sorts by steepest price drop only.
      // This is acceptable: the user has explicitly opted into a non-Hype
      // subset, so applying Hype's curation would be incoherent.
      let colorwaySelect: string;
      if (hasSizeFilter) {
        colorwaySelect =
          'colorways!inner(id, name, color_code, image_url, gender,' +
          ' sneaker_sizes!inner(retailer_id, is_available, sizes!inner(us_size)),' +
          ' prices(retailer_id, listing_rank)' +
          ')';
      } else if (wantInnerColorways) {
        colorwaySelect =
          'colorways!inner(id, name, color_code, image_url, gender,' +
          (hasRetailerFilter
            ? ' prices!inner(retailer_id, is_available, listing_rank)'
            : ' prices(retailer_id, listing_rank)') +
          ')';
      } else {
        colorwaySelect =
          'colorways(id, name, color_code, image_url, gender, prices(retailer_id, listing_rank))';
      }
```

- [ ] **Step 2: Switch from server-side range to fetch-all**

Find lines 89-104 of `useSneakers.tsx`:

```typescript
      let query = supabase
        .from('sneakers')
        .select(
          `
          id,
          name,
          model,
          release_date,
          description,
          brand:brands(id, name, logo_url),
          ${colorwaySelect}
        `,
          { count: 'exact' }
        )
        .order('name')
        .range(offset, offset + limit - 1);
```

Replace with — note we keep `let` because the filter block below this still re-assigns `query` when a retailer/size/gender filter is active:

```typescript
      // Fetch-all + client-side sort: the catalogue is small (<100
      // sneakers) and we sort by a computed composite of (Hype rank,
      // price drop) that PostgREST can't express. Pagination happens
      // after interleaveStriped below.
      let query = supabase
        .from('sneakers')
        .select(
          `
          id,
          name,
          model,
          release_date,
          description,
          brand:brands(id, name, logo_url),
          ${colorwaySelect}
        `,
          { count: 'exact' }
        );
```

`.order('name')` and `.range()` are gone; pagination happens after `interleaveStriped` in Step 5. The `count: 'exact'` option stays but is no longer load-bearing — we recompute `count` from the interleaved array length.

- [ ] **Step 3: Import `interleaveStriped` and `RankedSneaker`**

At the top of `useSneakers.tsx`, find the existing imports (around lines 1-12):

```typescript
import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import type { Gender } from '@/contexts/FilterContext';
import {
  fetchRetailersForSneaker as fetchRetailers,
  fetchPriceHistory as fetchHistory,
  fetchSaleColorways,
  fetchSaleColorwaysCount,
  fetchSaleColorwaysSignalCount,
  type SaleColorway,
  type SaleSignal,
} from '@/lib/sneakerQueries';
```

Add immediately after:

```typescript
import { interleaveStriped, type RankedSneaker } from '@/lib/rankInterleave';
```

- [ ] **Step 4: Add a Hype DC retailer ID constant**

The interleave needs to know which embedded `prices` rows belong to Hype DC. The retailer ID is stable in production. Look it up once via the MCP tool `execute_sql`:

```sql
SELECT id FROM retailers WHERE name = 'Hype DC';
```

Take the returned UUID and add it as a module-level constant near the top of `useSneakers.tsx`, immediately below the imports:

```typescript
// Hype DC's retailer.id — looked up once during j26 implementation.
// Used to identify which embedded prices rows carry the Hype listing
// rank we sort by. Stable in production; if it ever changes, update
// here.
const HYPEDC_RETAILER_ID = '<UUID FROM EXECUTE_SQL>';
```

Replace `<UUID FROM EXECUTE_SQL>` with the actual UUID from the query.

- [ ] **Step 5: Compute per-sneaker Hype rank and rebuild result list**

The `useSneakers` hook currently builds `transformedData` then returns it sliced server-side. We now need to: compute `RankedSneaker[]`, sort+interleave, then slice in JS.

Find the existing `transformedData` block (around lines 274-291):

```typescript
      const transformedData = data.map((sneaker: any) => ({
        ...sneaker,
        brand: sneaker.brand,
        colorways: (sneaker.colorways || []).map((c: any) => ({
          id: c.id,
          name: c.name,
          color_code: c.color_code,
          image_url: c.image_url,
          lowest_price: lowestByColorway[c.id],
          in_stock: inStockColorways.has(c.id),
          retailer_count: retailersByColorway[c.id]?.size ?? 0,
          price_change: priceChangeByColorway[c.id] ?? 0,
        })),
        lowest_price: lowestBySneaker[sneaker.id],
        price_change: priceChangeBySneaker[sneaker.id] ?? 0,
        in_stock: inStockSneakers.has(sneaker.id),
        retailer_count: retailersBySneaker[sneaker.id]?.size ?? 0,
      }));

      return {
        data: transformedData,
        count: count || 0,
        totalPages: Math.ceil((count || 0) / limit),
        currentPage: page,
      };
```

Replace with:

```typescript
      const transformedData = data.map((sneaker: any) => ({
        ...sneaker,
        brand: sneaker.brand,
        colorways: (sneaker.colorways || []).map((c: any) => ({
          id: c.id,
          name: c.name,
          color_code: c.color_code,
          image_url: c.image_url,
          lowest_price: lowestByColorway[c.id],
          in_stock: inStockColorways.has(c.id),
          retailer_count: retailersByColorway[c.id]?.size ?? 0,
          price_change: priceChangeByColorway[c.id] ?? 0,
        })),
        lowest_price: lowestBySneaker[sneaker.id],
        price_change: priceChangeBySneaker[sneaker.id] ?? 0,
        in_stock: inStockSneakers.has(sneaker.id),
        retailer_count: retailersBySneaker[sneaker.id]?.size ?? 0,
      }));

      // Per-sneaker Hype rank from the embedded prices rows. We use the
      // min rank across the sneaker's colorways — and when a specific
      // gender filter is active we constrain to colorways matching that
      // gender (so the user sees mens-listing order when filtering mens).
      const sneakerHypeRank: Record<string, number | null> = {};
      (data as any[]).forEach((sneaker) => {
        let minRank: number | null = null;
        (sneaker.colorways || []).forEach((c: any) => {
          if (hasGenderFilter && c.gender !== gender) return;
          (c.prices || []).forEach((p: any) => {
            if (p.retailer_id !== HYPEDC_RETAILER_ID) return;
            if (typeof p.listing_rank !== 'number') return;
            if (minRank === null || p.listing_rank < minRank) {
              minRank = p.listing_rank;
            }
          });
        });
        sneakerHypeRank[sneaker.id] = minRank;
      });

      const ranked: RankedSneaker[] = transformedData.map((s: any) => ({
        sneaker: s,
        hypeRank: sneakerHypeRank[s.id] ?? null,
        priceChange: priceChangeBySneaker[s.id] ?? 0,
      }));

      const interleaved = interleaveStriped(ranked);
      const totalLen = interleaved.length;
      const pagedSlice = interleaved.slice(offset, offset + limit);

      return {
        data: pagedSlice as Sneaker[],
        count: totalLen,
        totalPages: Math.max(1, Math.ceil(totalLen / limit)),
        currentPage: page,
      };
```

- [ ] **Step 6: Confirm types compile**

```bash
cd /workspace/aussie-kicks-tracker
npx tsc --noEmit -p tsconfig.json 2>&1 | grep -E 'useSneakers|rankInterleave' | head -20
```

Expected: no errors in those files. (Other files may still have pre-existing tsc warnings; ignore.)

- [ ] **Step 7: Smoke-test in the dev server**

```bash
cd /workspace/aussie-kicks-tracker
npm run dev
```

In a browser at `http://localhost:8080/`:
1. Open the network tab; confirm the sneakers query no longer requests a row range (no `Range: 0-19` header on the sneakers fetch).
2. Set gender filter to `mens`. Compare the first 12 sneaker cards to the first 12 cards on `https://www.hypedc.com/au/categories/mens/footwear/sneakers`. They should be the same products in the same order.
3. Scroll to position 13-16. Position 16 should be a non-Hype-stocked item (Salomon, Platypus-only, or similar — whichever has the steepest recent price drop). Position 20 should be another non-Hype item.
4. Toggle gender to `womens`; first 12 should match Hype's womens listing.
5. Toggle gender to `all`; verify the page still renders without errors. Order will be min-rank across genders.

If any of these checks fail, file a bd issue, fix, re-test. Don't proceed to commit until the smoke passes.

- [ ] **Step 8: Check SITEMAP.md and spec.yaml**

```bash
grep -n "Index\|useSneakers\|all-view" /workspace/aussie-kicks-tracker/SITEMAP.md 2>&1 | head -5
grep -n "listing_rank\|prices" /workspace/spec.yaml 2>&1 | head -10
```

The data shape returned by `useSneakers` did not change — same `Sneaker[]` with same fields, just reordered. So SITEMAP.md likely doesn't need an update. The PostgREST select shape DID change (we now embed `prices(retailer_id, listing_rank)` on the all-view query); if `spec.yaml` documents that query with an example, update it. If neither file references the all-view's prices embed, no edit needed — note this in the commit message.

- [ ] **Step 9: Commit**

```bash
cd /workspace/aussie-kicks-tracker
git add src/hooks/useSneakers.tsx
# Add SITEMAP.md or spec.yaml only if you actually edited them in Step 8.
git commit -m "$(cat <<'EOF'
feat(sneaker_scout-j26): all-view sorts by Hype DC listing rank

useSneakers now fetches the full filtered set, computes a per-sneaker
Hype rank (min across colorways, gender-aware), and interleaves
hype-ranked items with price-drop fallbacks via interleaveStriped.
Pagination happens client-side after the interleave.

First 12 slots match Hype's listing exactly; positions 16, 20, 24...
surface non-Hype items ranked by steepest recent price drop.

Closes: nothing yet — implementation tracked under sneaker_scout-j26
EOF
)"
```

---

## Task 9: File follow-up bd issues for known gaps

**Files:** none — bd state only.

- [ ] **Step 1: Create the frontend test-runner follow-up**

```bash
cd /workspace
bd create \
  --type=task \
  --priority=3 \
  --title="set up vitest in aussie-kicks-tracker" \
  --description="The frontend has no test runner today (just vite + eslint), so the j26 work shipped \`src/lib/rankInterleave.ts\` without unit tests despite being a pure, easily-testable function. Wire up vitest + @testing-library/react, add a CI script, and backfill tests for interleaveStriped (burst/stripe edges, empty queues, mid-stripe exhaustion). Unlocks proper TDD for any future frontend work." \
  --design="Pick vitest (matches Vite ecosystem). Add to package.json devDependencies, add npm script 'test'. First test file should be tests for interleaveStriped — that function was designed in j26 specifically to be unit-testable and is the obvious starter." \
  2>&1 | tail -3
```

- [ ] **Step 2: Cross-link the existing search-frequency issue**

`sneaker-scout-1wv` already covers user-search tracking — the fallback signal we *wanted* in j26 but couldn't compute. Add a note linking the two so future readers know the connection:

```bash
cd /workspace
bd update sneaker-scout-1wv --notes "$(cat <<'EOF'
The j26 implementation (distilled recommendation = mirror Hype DC) currently
uses 'steepest recent price drop' as the fallback signal for non-Hype products
because search-frequency tracking doesn't exist yet. Once the work in this
issue ships (a search_queries table and search-bar instrumentation), revisit
useSneakers / rankInterleave to swap the fallback signal to 'most searched
for' — which more directly answers the question this issue is exploring.
EOF
)" 2>&1 | tail -3
```

- [ ] **Step 3: Verify both updates landed**

```bash
bd list --status=open 2>&1 | grep -E '1wv|vitest' | head -5
```

Expected: see the new vitest issue and 1wv listed.

- [ ] **Step 4: No commit needed** — bd persists state to `.beads/issues.jsonl` automatically; that file change will be picked up by the final session commit.

---

## Task 10: Close `sneaker-scout-j26` and do session sweep

**Files:** none directly — bd state, plus a final per-issue commit if anything's left.

- [ ] **Step 1: Confirm all work is committed**

```bash
git status
```

Expected: only `.beads/*` modifications (from the close coming next). Working tree otherwise clean. If anything else is uncommitted, investigate — the per-issue protocol expects one commit per close, so an uncommitted code change here is a sign of a missing earlier commit.

- [ ] **Step 2: Close the issue**

```bash
cd /workspace
bd close sneaker-scout-j26 --reason "distilled recommendation shipped: mirror Hype listing on all-view via prices.listing_rank, with burst-then-stripe interleave and price-drop fallback"
```

- [ ] **Step 3: Commit the bd state change**

```bash
cd /workspace
git add .beads/
git commit -m "$(cat <<'EOF'
chore(sneaker_scout-j26): bd state for j26 close + follow-ups

Closes sneaker-scout-j26 (distilled recommendation algorithm).
Captures notes on sneaker-scout-1wv linking it to the j26 fallback
signal, and the new vitest-setup follow-up issue.

Closes: sneaker_scout-j26
EOF
)"
```

- [ ] **Step 4: Add a `bd remember` for the non-obvious decisions**

A future session won't have this conversation's brainstorming context. Capture the load-bearing choices:

```bash
cd /workspace
bd remember "j26 (distilled recommendation = mirror Hype DC) is implemented as: prices.listing_rank column populated by the Hype scraper, cleared per (retailer, gender) on each upload, used as the primary sort key in useSneakers. Fallback for non-Hype products is steepest recent price drop. Interleave is burst(12)-then-stripe(3:1). Frontend has no test runner yet (vitest follow-up open) — rankInterleave.ts is intentionally pure so it'll be the first thing tested when vitest lands."
```

- [ ] **Step 5: Final session push**

Per the project's Session Completion workflow:

```bash
cd /workspace
git pull --rebase
# bd dolt push  ← skip; CLAUDE.md notes no remote is configured for bd
git push
git status  # expect: "up to date with origin/<branch>"
```

If `git push` fails, resolve and retry until it succeeds. Work is not complete until push completes.

---

## Self-review

**Spec coverage:**
- Schema change (spec §"Schema change") → Task 1 ✓
- Scrape rank threading (spec §"Backend changes" / "pagination_scraper.py") → Tasks 2-3 ✓
- Uploader reset + write (spec §"Backend changes" / "update_supabase_daily.py") → Tasks 4-6 ✓
- Frontend composite sort + striped interleave (spec §"Frontend changes" + pseudocode) → Tasks 7-8 ✓
- Cross-gender min aggregation when `gender='all'` (spec §"Frontend changes" step 3) → Task 8 Step 5 ✓
- Edge cases: partial Hype run, no scrape yet, delisting (spec §"Edge cases") → handled by the unconditional clear-then-write in Task 6 plus the null-tolerant interleave in Task 7 ✓
- Testing: backend pytest, frontend smoke (spec §"Testing") → Tasks 2/3/4 (pytest) + Task 8 Step 7 (smoke) ✓
- Out-of-scope follow-ups: vitest + search tracking (spec §"Out-of-scope follow-ups") → Task 9 ✓
- Definition-of-done items 1-7 (spec §"Definition of done") → Tasks 1, 3, 6, 8 (steps 7-8), plus Task 10 ✓

**Placeholder scan:** No `TBD`, `TODO`, "add error handling" placeholders. The one runtime substitution required (the Hype DC retailer UUID in Task 8 Step 4) has explicit instructions on how to fetch it via `execute_sql` — not a placeholder, a per-environment value.

**Type consistency:**
- `combine_product_info(basic, detailed, retailer, gender, scrape_rank=None)` — defined Task 2, used Task 3 with kwarg `scrape_rank=scrape_rank`. ✓
- `_listing_rank_pairs(data) → set` — defined Task 4, called from `main()` in Task 6 returning into `rank_pairs`. ✓
- `_reset_listing_ranks_for_pairs(supabase, pairs)` — defined Task 6, called same task. ✓
- `RankedSneaker { sneaker, hypeRank, priceChange }` — defined Task 7, constructed Task 8. Property names match (`hypeRank` not `hype_rank`, `priceChange` not `price_change`). ✓
- `interleaveStriped(ranked, options?)` — defined Task 7, called Task 8 with no options (default burst=12, stripe=3). ✓
- `HYPEDC_RETAILER_ID` — defined Task 8 Step 4, used Task 8 Step 5. ✓

No issues found.
