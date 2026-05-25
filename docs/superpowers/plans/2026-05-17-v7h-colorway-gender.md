# colorways.gender + per-gender scraping + gender toggle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land a `colorways.gender` column (backfilled `'mens'` for every existing row), teach each retailer scraper to walk a women's listing URL alongside the men's listing, and expose a 3-position `All | Mens | Womens` toggle above the listing on `/` and `/sale`.

**Architecture:** Three slices.

1. **Schema.** `colorways.gender` is `text NOT NULL` with a `CHECK` constraint allowing `'mens'|'womens'|'unisex'|'kids'`. Backfilled `'mens'` because every listing URL currently scraped is mens-only.
2. **Scrapers.** Each retailer scraper grows a `LISTING_URLS` dict keyed by `'mens'|'womens'` and a `--gender=mens|womens` CLI flag (defaulting `'mens'`). One invocation scrapes one gender and writes `jsons/<retailer>_<gender>_products.json`. `combine_product_info(...)` stamps `gender` onto each colorway dict. The bulk uploader propagates `gender` into the colorway upsert payload.
3. **Frontend.** `FilterContext` owns a new `selectedGender: 'all'|'mens'|'womens'` driven by `?gender=` URL param. A new `GenderToggle` component renders the three-button segmented control above the listing on `/` and `/sale`. Every listing/sale hook adds an inner-joined `.eq('colorways.gender', gender)` (or, on `/sale`, `.eq('gender', gender)` since the base table is `colorways`).

**Tech Stack:** Python 3.12 (Pydantic, pytest, supabase-py), TypeScript/React (Vite, react-router-dom, @tanstack/react-query, shadcn/ui Button), Supabase (PostgreSQL).

---

## File map

**Schema (1 new migration):**
- Create: `aussie-kicks-tracker/supabase/migrations/20260517120000-v7h-add-colorways-gender.sql`
- Modify: `aussie-kicks-tracker/src/integrations/supabase/types.ts` (add `gender` field to `colorways.Row/Insert/Update`)

**Backend models & uploader:**
- Modify: `sneaker-scout-backend/utils/schema.py` (add `gender` to `Colorway` + `ColorwayWithPricing`)
- Modify: `sneaker-scout-backend/data_upload/bulk_upload.py` (propagate `gender` in `collect_unique_entities` + `bulk_upload`)
- Modify: `sneaker-scout-backend/data_upload/update_supabase_daily.py` (set `gender` on colorway insert/update path)
- Modify: `sneaker-scout-backend/tests/test_bulk_upload.py` (extend `_item()` with `gender` kwarg + new assertions)

**Backend scrapers (5 files, same shape per retailer):**
- Modify: `sneaker-scout-backend/salomon/pagination_scraper.py`
- Modify: `sneaker-scout-backend/hypedc/pagination_scraper.py`
- Modify: `sneaker-scout-backend/platypus/pagination_scraper.py`
- Modify: `sneaker-scout-backend/footlocker/pagination_scraper.py`
- Modify: `sneaker-scout-backend/jdsports/pagination_scraper.py`

**Docker:**
- Modify: `sneaker-scout-backend/entrypoint.sh` (run salomon twice — once per gender — and upload each output)

**Frontend:**
- Modify: `aussie-kicks-tracker/src/contexts/FilterContext.tsx` (add `selectedGender` + `setGender` + `?gender=` param)
- Create: `aussie-kicks-tracker/src/components/GenderToggle.tsx` (3-button segmented control)
- Modify: `aussie-kicks-tracker/src/hooks/useSneakers.tsx` (add `gender` param to `useSneakers`, `useColorwaysCount`, `useInStockCount`, `usePriceDropsCount`, `useSaleColorways`, `useSaleColorwaysSignalCount`; gate via embedded `.eq('colorways.gender', ...)`)
- Modify: `aussie-kicks-tracker/src/lib/sneakerQueries.ts` (extend `fetchSaleColorways` + `fetchSaleColorwaysSignalCount` to filter by gender)
- Modify: `aussie-kicks-tracker/src/pages/Index.tsx` (render `<GenderToggle/>`, pass `selectedGender` into hooks)
- Modify: `aussie-kicks-tracker/src/pages/Sale.tsx` (same)

**Living documents:**
- Modify: `aussie-kicks-tracker/SITEMAP.md` (document the `?gender=` param on `/` and `/sale`)
- Modify: `spec.yaml` (add `gender` to the `Colorway` schema + a `gender=eq.X` example on `/rest/v1/colorways`; update scraper CLI section with the `--gender` flag and per-gender filenames)
- Modify: `CLAUDE.md` (repo root — update the dev-run example commands to show both genders)

---

## Task 1: Add `colorways.gender` schema migration

**Files:**
- Create: `aussie-kicks-tracker/supabase/migrations/20260517120000-v7h-add-colorways-gender.sql`

- [ ] **Step 1: Write the migration**

```sql
-- sneaker_scout-v7h: Add gender to colorways.
--
-- Every retailer listing URL the current scrapers visit is mens-only,
-- so existing rows are backfilled to 'mens'. The scraper changes that
-- land alongside this migration add the womens listing per retailer
-- and stamp the gender for each new colorway. Sizes were standardised
-- to US-Men by 505, which mis-sizes women's-only shoes by ~1.5 — once
-- this column ships, the size-conversion logic can be refined per
-- gender in a follow-up.
--
-- Stored as text with a CHECK constraint rather than a native enum
-- so adding kids/unisex later is a one-line ALTER TABLE.

BEGIN;

ALTER TABLE public.colorways
    ADD COLUMN gender text;

UPDATE public.colorways SET gender = 'mens' WHERE gender IS NULL;

ALTER TABLE public.colorways
    ALTER COLUMN gender SET NOT NULL,
    ADD CONSTRAINT colorways_gender_check
        CHECK (gender IN ('mens', 'womens', 'unisex', 'kids'));

COMMIT;
```

- [ ] **Step 2: Apply the migration**

Run from `aussie-kicks-tracker/`:

```bash
npx supabase db push
```

Expected: `Applying migration 20260517120000_v7h-add-colorways-gender.sql ... success`. Inspect with:

```bash
npx supabase db remote inspect | grep -A2 'colorways.*gender'
```

Expected: `gender | text | NOT NULL`.

- [ ] **Step 3: Sanity-check the backfill**

In the Supabase SQL editor (or psql against the project URL), run:

```sql
SELECT gender, COUNT(*) FROM public.colorways GROUP BY gender;
```

Expected: a single row, `mens | N` where `N` matches the total colorways count seen in the previous session's `bd remember` snapshots. **Stop the plan** and investigate if any other gender appears — the backfill should be deterministic.

- [ ] **Step 4: Commit**

```bash
git -C /workspace/sneaker-scout-backend add aussie-kicks-tracker/supabase/migrations/20260517120000-v7h-add-colorways-gender.sql
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-v7h): add colorways.gender with mens backfill"
```

(The migration file physically lives under the frontend repo but the backend repo is where ingest code commits land — match the existing migration commit pattern via `git -C` for whichever nested repo owns the migrations directory in your workspace. If the frontend dir is its own git repo separate from `sneaker-scout-backend/`, commit there instead.)

---

## Task 2: Update Supabase TypeScript types for `colorways.gender`

**Files:**
- Modify: `aussie-kicks-tracker/src/integrations/supabase/types.ts:38-72`

- [ ] **Step 1: Add `gender` to `colorways.Row`, `Insert`, `Update`**

Edit `aussie-kicks-tracker/src/integrations/supabase/types.ts`. Locate the `colorways:` block (around line 38) and add `gender: string` (or `'mens' | 'womens' | 'unisex' | 'kids'`) to each of `Row`, `Insert`, `Update`. After the edit the block reads:

```ts
      colorways: {
        Row: {
          color_code: string | null
          created_at: string
          gender: 'mens' | 'womens' | 'unisex' | 'kids'
          id: string
          image_url: string | null
          name: string
          sneaker_id: string
        }
        Insert: {
          color_code?: string | null
          created_at?: string
          gender: 'mens' | 'womens' | 'unisex' | 'kids'
          id?: string
          image_url?: string | null
          name: string
          sneaker_id: string
        }
        Update: {
          color_code?: string | null
          created_at?: string
          gender?: 'mens' | 'womens' | 'unisex' | 'kids'
          id?: string
          image_url?: string | null
          name?: string
          sneaker_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "colorways_sneaker_id_fkey"
            columns: ["sneaker_id"]
            isOneToOne: false
            referencedRelation: "sneakers"
            referencedColumns: ["id"]
          },
        ]
      }
```

- [ ] **Step 2: Type-check**

Run from `aussie-kicks-tracker/`:

```bash
npm run build
```

Expected: build succeeds. No call site yet uses `gender`, so the change is additive.

- [ ] **Step 3: Commit**

```bash
git -C /workspace/aussie-kicks-tracker add src/integrations/supabase/types.ts
git -C /workspace/aussie-kicks-tracker commit -m "chore(sneaker_scout-v7h): expose colorways.gender in generated types"
```

---

## Task 3: Add `gender` to Pydantic Colorway model

**Files:**
- Modify: `sneaker-scout-backend/utils/schema.py:96-105` and `:196-209`
- Test: `sneaker-scout-backend/tests/test_schema_colorway_gender.py` (new file)

- [ ] **Step 1: Write the failing test**

Create `sneaker-scout-backend/tests/test_schema_colorway_gender.py`:

```python
"""sneaker_scout-v7h: Colorway model carries gender."""

from utils.schema import Colorway, ColorwayWithPricing
from uuid import uuid4

import pytest
from pydantic import ValidationError


def test_colorway_accepts_gender():
    c = Colorway(sneaker_id=uuid4(), name="Black", gender="mens")
    assert c.gender == "mens"


def test_colorway_rejects_unknown_gender():
    with pytest.raises(ValidationError):
        Colorway(sneaker_id=uuid4(), name="Black", gender="bogus")


def test_colorway_gender_optional_for_legacy_reads():
    # SELECT rows before backfill may not yet carry gender — model must
    # allow None so reads of the existing schema keep parsing.
    c = Colorway(sneaker_id=uuid4(), name="Black")
    assert c.gender is None


def test_colorway_with_pricing_accepts_gender():
    c = ColorwayWithPricing(sneaker_id=uuid4(), name="Black", gender="womens")
    assert c.gender == "womens"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd sneaker-scout-backend && source .venv/bin/activate
pytest tests/test_schema_colorway_gender.py -v
```

Expected: FAIL with `Unexpected keyword argument 'gender'` or similar (model rejects unknown field — `extra="forbid"`).

- [ ] **Step 3: Add `gender` to `Colorway`**

In `sneaker-scout-backend/utils/schema.py`, replace the `Colorway` class (lines 96-105) with:

```python
class Colorway(_Base):
    """`colorways` row — one product variant; carries the image."""

    id: Optional[UUID] = None
    sneaker_id: UUID
    name: str
    color_code: Optional[str] = None
    image_url: Optional[str] = None
    gender: Optional[Literal["mens", "womens", "unisex", "kids"]] = None
    created_at: Optional[datetime] = None
```

And at the top of the file, add `Literal` to the typing imports:

```python
from typing import List, Literal, Optional
```

`ColorwayWithPricing` inherits from `Colorway`, so it picks up `gender` automatically — no change needed there beyond a docstring touch-up if you want one.

- [ ] **Step 4: Run the test to verify it passes**

```bash
pytest tests/test_schema_colorway_gender.py -v
```

Expected: 4 passed.

- [ ] **Step 5: Run the existing test suite**

```bash
pytest -v
```

Expected: all existing tests still pass — the field is optional.

- [ ] **Step 6: Commit**

```bash
git -C /workspace/sneaker-scout-backend add utils/schema.py tests/test_schema_colorway_gender.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-v7h): add gender to Pydantic Colorway model"
```

---

## Task 4: `collect_unique_entities` propagates `gender`

**Files:**
- Modify: `sneaker-scout-backend/data_upload/bulk_upload.py:91-102`
- Test: `sneaker-scout-backend/tests/test_bulk_upload.py` (extend `_item()` + add new test)

- [ ] **Step 1: Extend the test fixture and add a failing test**

Open `sneaker-scout-backend/tests/test_bulk_upload.py`. Extend `_item()` to accept a `gender` kwarg (default `"mens"`), and add `"gender": gender` to the `"colorway"` dict it returns. The full updated helper:

```python
def _item(
    *,
    brand: str = "Salomon",
    sneaker_name: str = "XT-6",
    colorway_name: str = "black/black",
    retailer_name: str = "Salomon",
    price: str = "$340.00",
    size: str = "9.5 US",
    is_available: bool = True,
    gender: str = "mens",
) -> dict[str, Any]:
    return {
        "brand": {"name": brand, "logo_url": None},
        "sneaker": {
            "name": sneaker_name,
            "model": sneaker_name,
            "description": None,
            "release_date": None,
        },
        "colorway": {"name": colorway_name, "image_url": None, "gender": gender},
        "retailer": {
            "name": retailer_name,
            "website_url": "https://www.salomon.com.au",
            "logo_url": None,
        },
        "prices": {
            "price": price,
            "original_price": price,
            "currency": "AUD",
            "is_available": is_available,
            "product_url": f"https://example.com/{sneaker_name}",
        },
        "sizes": [{"size": size, "is_available": is_available}],
    }
```

Then add (anywhere in the `collect_unique_entities` section of the file):

```python
def test_plan_propagates_colorway_gender():
    plan = collect_unique_entities([
        _item(colorway_name="black/black", gender="mens"),
        _item(colorway_name="white/grey", gender="womens"),
    ])
    by_name = {c["name"]: c for c in plan.colorways}
    assert by_name["black/black"]["gender"] == "mens"
    assert by_name["white/grey"]["gender"] == "womens"


def test_plan_defaults_gender_to_mens_when_missing():
    # Backwards-compat: older JSON payloads scraped before v7h won't
    # carry gender. The planner should fall back to 'mens' so re-running
    # the uploader against an existing jsons/ file doesn't NULL-out the
    # column.
    item = _item()
    del item["colorway"]["gender"]
    plan = collect_unique_entities([item])
    assert plan.colorways[0]["gender"] == "mens"
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd sneaker-scout-backend && source .venv/bin/activate
pytest tests/test_bulk_upload.py::test_plan_propagates_colorway_gender tests/test_bulk_upload.py::test_plan_defaults_gender_to_mens_when_missing -v
```

Expected: both FAIL — colorway dicts in `plan.colorways` don't yet have a `gender` key.

- [ ] **Step 3: Plumb `gender` through `collect_unique_entities`**

In `sneaker-scout-backend/data_upload/bulk_upload.py`, replace the colorway accumulation block (around lines 91-102):

```python
        cw = item["colorway"]
        cw_name = cw.get("name") or cw.get("colorway_name") or ""
        cw_lookup = colorway_lookup_key(cw_name)
        c_key = (canon_brand, s_lookup, cw_lookup)
        if c_key not in colorways_by_key:
            colorways_by_key[c_key] = {
                "brand_lookup": canon_brand,
                "sneaker_lookup_key": s_lookup,
                "lookup_key": cw_lookup,
                "name": cw_name,
                "image_url": cw.get("image_url") or cw.get("colorway_image"),
                "gender": cw.get("gender") or "mens",
            }
```

(`"mens"` is the fallback for legacy JSON payloads scraped before v7h.)

- [ ] **Step 4: Run the tests to verify they pass**

```bash
pytest tests/test_bulk_upload.py -v
```

Expected: all green, including the two new tests.

- [ ] **Step 5: Commit**

```bash
git -C /workspace/sneaker-scout-backend add data_upload/bulk_upload.py tests/test_bulk_upload.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-v7h): collect_unique_entities propagates colorway gender"
```

---

## Task 5: `bulk_upload` writes `gender` to the colorways upsert

**Files:**
- Modify: `sneaker-scout-backend/data_upload/bulk_upload.py:213-227`
- Test: `sneaker-scout-backend/tests/test_bulk_upload.py` (new test in the orchestrator section)

- [ ] **Step 1: Add a failing test**

Find the orchestrator-test section in `tests/test_bulk_upload.py` (after `# ---------- bulk_upload ----------` if present, otherwise at the end). Append:

```python
def test_bulk_upload_includes_gender_in_colorway_upsert(monkeypatch):
    """The colorway upsert payload must include the gender so newly
    inserted rows satisfy the NOT NULL constraint added in v7h's
    migration."""
    from data_upload import bulk_upload as bu

    captured: dict[str, list[dict[str, Any]]] = {}

    class _Tbl:
        def __init__(self, name): self.name = name
        def select(self, *_a, **_kw): return self
        def eq(self, *_a, **_kw): return self
        def in_(self, *_a, **_kw): return self
        def execute(self): return type("R", (), {"data": []})()
        def upsert(self, payload, **_kw):
            captured.setdefault(self.name, []).extend(payload)
            # Return synthetic rows with stable ids so chained code keeps working.
            rows = [{**r, "id": f"{self.name}-{i}"} for i, r in enumerate(payload)]
            return type("R", (), {"data": rows, "execute": lambda self_=None: type("R2", (), {"data": rows})()})()
        def insert(self, payload, **_kw):
            captured.setdefault(self.name, []).extend(payload)
            return type("R", (), {"execute": lambda self_=None: type("R2", (), {"data": payload})()})()

    class _Client:
        def table(self, name): return _Tbl(name)

    bu.bulk_upload(_Client(), [_item(colorway_name="black", gender="womens")])

    cw_rows = captured.get("colorways", [])
    assert cw_rows, "no colorway upsert observed"
    assert cw_rows[0]["gender"] == "womens"
```

(If `tests/test_bulk_upload.py` already has a fake-supabase fixture, prefer that — match its calling convention rather than the inline `_Tbl` above. Inspect the file before writing this test; if a helper exists, reuse it and skip the `_Tbl` boilerplate.)

- [ ] **Step 2: Run the test to verify it fails**

```bash
pytest tests/test_bulk_upload.py::test_bulk_upload_includes_gender_in_colorway_upsert -v
```

Expected: FAIL — `gender` key is missing from the upsert payload (the dict-stripping loop drops it because it isn't whitelisted yet).

- [ ] **Step 3: Pass `gender` through to the colorway upsert**

In `sneaker-scout-backend/data_upload/bulk_upload.py`, replace the colorway upsert block (around lines 213-224):

```python
    colorway_payload = []
    for c in plan.colorways:
        row = dict(c)
        brand_id = brand_id_by_name[row.pop("brand_lookup")]
        sneaker_id = sneaker_id_by_key[
            (brand_id, row.pop("sneaker_lookup_key"))
        ]
        row["sneaker_id"] = sneaker_id
        colorway_payload.append(row)
    colorway_rows = supabase.table("colorways").upsert(
        colorway_payload, on_conflict="sneaker_id,lookup_key"
    ).execute().data
```

No code change is actually required here — `row = dict(c)` already includes `gender` from Task 4. **The fix is upstream** (Task 4 already accomplished this). Re-run the test:

```bash
pytest tests/test_bulk_upload.py::test_bulk_upload_includes_gender_in_colorway_upsert -v
```

Expected: PASS.

If the test still fails, audit the row construction — something in `dict(c)` is dropping the field. Most likely the `_Tbl` fake above is the culprit; adjust the fake to faithfully capture the payload.

- [ ] **Step 4: Commit (test-only commit)**

```bash
git -C /workspace/sneaker-scout-backend add tests/test_bulk_upload.py
git -C /workspace/sneaker-scout-backend commit -m "test(sneaker_scout-v7h): assert bulk_upload writes colorway gender"
```

---

## Task 6: `update_supabase_daily.py` writes `gender` on colorway insert

The per-row path is kept available behind `run_update.py --per-row`. It needs the same treatment as `bulk_upload`.

**Files:**
- Modify: `sneaker-scout-backend/data_upload/update_supabase_daily.py:286-298`

- [ ] **Step 1: Plumb `gender` into the colorway insert**

Locate the `colorways` insert block (lines ~286-298) and update both the insert payload and the update path:

```python
            if not colorway_response.data:
                colorway_response = supabase.table("colorways").insert({
                    "sneaker_id": sneaker_id,
                    "name": colorway_display,
                    "lookup_key": colorway_lookup,
                    "image_url": colorway_image,
                    "gender": colorway_data.get("gender") or "mens",
                }).execute()
                logger.info(
                    f"Inserted colorway: {colorway_display!r} "
                    f"(lookup_key={colorway_lookup!r})"
                )
            else:
                existing = colorway_response.data[0]
                # Detect unrecognised collisions: same algorithmic key, different
                # display name, not in registry. Queue for human review.
                if existing["name"] != colorway_display and override is None:
                    _write_pending_review(
                        sneaker_key=lookup_key,
                        sneaker_display=sneaker_data["name"],
                        scraped_colorway=colorway_name,
                        computed_lookup_key=colorway_lookup,
                        colliding_existing_name=existing["name"],
                        retailer=item.get("retailer", {}).get("name", "unknown"),
                    )
                logger.info(
                    f"Matched colorway: {colorway_display!r} -> existing "
                    f"row {existing['name']!r} (lookup_key={colorway_lookup!r}); "
                    f"first-write-wins, no update applied"
                )
```

The match path intentionally does NOT update gender (first-write-wins, same as `name`) — a single physical colorway should not change gender between scrapes. If a retailer mis-categorises a shoe, that's a manual override in `colorway_overrides.yaml` territory.

- [ ] **Step 2: Smoke-run the per-row path against an existing JSON**

```bash
cd sneaker-scout-backend && source .venv/bin/activate
python -m data_upload.run_update --per-row --file=jsons/salomon_products.json
```

Expected: the run completes; `supabase_update.log` shows `Inserted colorway: ...` / `Matched colorway: ...` lines with no errors. Verify in Supabase SQL editor that newly inserted colorways have `gender='mens'`:

```sql
SELECT gender, COUNT(*) FROM public.colorways GROUP BY gender;
```

- [ ] **Step 3: Commit**

```bash
git -C /workspace/sneaker-scout-backend add data_upload/update_supabase_daily.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-v7h): per-row uploader writes colorway gender"
```

---

## Task 7: Salomon scraper — per-gender URL + `--gender` CLI flag

**Files:**
- Modify: `sneaker-scout-backend/salomon/pagination_scraper.py:88-120, 258-288`

- [ ] **Step 1: Replace `LISTING_URL` constant with a per-gender map**

In `sneaker-scout-backend/salomon/pagination_scraper.py`, replace the hard-coded base URL at line 260 (and remove any other reference to it) with a module-level dict near the top. After the existing imports, insert:

```python
LISTING_URLS = {
    "mens": "https://salomon.com.au/collections/mens#/filter:ss_subcollection_filter:shoes",
    "womens": "https://salomon.com.au/collections/womens#/filter:ss_subcollection_filter:shoes",
}
```

- [ ] **Step 2: Plumb `gender` through `combine_product_info`**

Modify `combine_product_info(basic_info, detailed_info)` (line 88) to accept `gender`:

```python
def combine_product_info(basic_info, detailed_info, gender):
    combined_info = {
        'sneaker': {
            'name': basic_info.get('name', ''),
            'model': basic_info.get('name', '').split(' ')[0] if basic_info.get('name') else '',
            'description': detailed_info.get('description', ''),
            'release_date': detailed_info.get('release_date', None)
        },
        'brand': {
            'name': detailed_info.get('brand', {}).get('name', 'Salomon'),
            'logo_url': detailed_info.get('brand', {}).get('logo_url', '')
        },
        'colorway': {
            'name': detailed_info.get('colorway', {}).get('name', ''),
            'color_code': '',
            'image_url': basic_info.get('image_url', ''),
            'gender': gender,
        },
        'prices': {
            'price': basic_info.get('sale_price', basic_info.get('price', '')),
            'original_price': basic_info.get('original_price', basic_info.get('price', '')),
            'currency': 'AUD',
            'is_available': detailed_info.get('is_available', False),
            'product_url': basic_info.get('url', '')
        },
        'retailer': detailed_info.get('retailer', {
            'name': 'Salomon Australia',
            'website_url': 'https://salomon.com.au',
            'logo_url': ''
        }),
        'sizes': detailed_info.get('sizes', [])
    }

    return combined_info
```

- [ ] **Step 3: Plumb `gender` through `scrape_all_pages`**

Change `scrape_all_pages` (line 138) to take `gender` and pass it to `combine_product_info`:

```python
def scrape_all_pages(base_url, retailer=None, gender="mens", max_pages=None, max_products_per_page=5, page_timeout=30):
```

Find the call to `combine_product_info(basic_info, detailed_info)` (around line 211) and pass `gender`:

```python
                    combined_info = combine_product_info(basic_info, detailed_info, gender)
```

- [ ] **Step 4: Replace the `__main__` block with argparse**

Replace lines 258-288 with:

```python
if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Scrape Salomon AU listing")
    parser.add_argument(
        "--gender",
        choices=("mens", "womens"),
        default="mens",
        help="Which listing to scrape (default: mens). One invocation per gender.",
    )
    args = parser.parse_args()

    base_url = LISTING_URLS[args.gender]
    retailer = {
        'name': 'Salomon Australia',
        'website_url': 'https://salomon.com.au',
        'logo_url': 'https://salomon.com.au/cdn/shop/files/1278_1_a777c16c-54d9-4015-843d-f768f66955e3_32x32.png'
    }

    # Scrape 3 pages worth of items per the a1i stress test — 999
    # effectively removes the per-page cap since Salomon's listing
    # never serves more than ~50 cards per page.
    all_products = scrape_all_pages(
        base_url,
        retailer=retailer,
        gender=args.gender,
        max_pages=3,
        max_products_per_page=999,
        page_timeout=30,
    )

    print(f"\nProcessed {len(all_products)} products successfully")

    if all_products:
        out = f"jsons/salomon_{args.gender}_products.json"
        save_to_json(all_products, out)
        print(f"All done! Data has been saved to {out}")
    else:
        print("No products were scraped.")
```

- [ ] **Step 5: Smoke-run both genders end-to-end**

```bash
cd sneaker-scout-backend && source .venv/bin/activate
python -m salomon.pagination_scraper --gender=mens
python -m salomon.pagination_scraper --gender=womens
```

Expected: `jsons/salomon_mens_products.json` and `jsons/salomon_womens_products.json` exist; each contains items whose `colorway.gender` matches the invocation. Inspect with:

```bash
python -c "import json; d=json.load(open('jsons/salomon_womens_products.json')); print({p['colorway'].get('gender') for p in d})"
```

Expected: `{'womens'}`.

- [ ] **Step 6: Upload both files and verify in Supabase**

```bash
python -m data_upload.run_update --file=jsons/salomon_mens_products.json
python -m data_upload.run_update --file=jsons/salomon_womens_products.json
```

Then in SQL editor:

```sql
SELECT gender, COUNT(*) FROM public.colorways GROUP BY gender;
```

Expected: a `mens` count AND a `womens` count.

- [ ] **Step 7: Commit**

```bash
git -C /workspace/sneaker-scout-backend add salomon/pagination_scraper.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-v7h): salomon scraper accepts --gender flag, emits gender per colorway"
```

---

## Task 8: Hype DC scraper — per-gender URL + `--gender` CLI flag

**Files:**
- Modify: `sneaker-scout-backend/hypedc/pagination_scraper.py:99, 282-340, 409-414, 522-540`

- [ ] **Step 1: Replace `LISTING_URL` with per-gender map**

Replace line 99 with:

```python
LISTING_URLS = {
    "mens": "https://www.hypedc.com/au/categories/mens/footwear/sneakers",
    "womens": "https://www.hypedc.com/au/categories/womens/footwear/sneakers",
}
```

(Keep a `LISTING_URL = LISTING_URLS["mens"]` line directly after if any function defaults still reference the singular constant, then audit and remove. Cleaner: also update those defaults — see Step 3.)

- [ ] **Step 2: Update `combine_product_info` to accept and stamp `gender`**

Modify `combine_product_info(basic, detailed, retailer)` (line 282) to take `gender`:

```python
def combine_product_info(basic, detailed, retailer, gender):
    """..."""
    detailed = detailed or {}
    basic = basic or {}
    # ... unchanged body ...
    return {
        # ... unchanged keys ...
        "colorway": {
            "name": detail_colorway.get("name", ""),
            "color_code": detail_colorway.get("color_code", ""),
            "image_url": image_url,
            "gender": gender,
        },
        # ... unchanged keys ...
    }
```

- [ ] **Step 3: Plumb `gender` through `_scrape_via_static_fallback` and `scrape_all_pages`**

Change the signatures:

```python
def _scrape_via_static_fallback(retailer, gender, max_products):
    # ...
        combined = combine_product_info(basic, detailed, retailer, gender)
        products.append(combined)
    return products


def scrape_all_pages(
    base_url=None,
    retailer=None,
    gender="mens",
    max_pages=3,
    max_products_per_page=3,
):
    if retailer is None:
        retailer = RETAILER
    if base_url is None:
        base_url = LISTING_URLS[gender]
    # ... unchanged body, but update the two combine_product_info calls
    # and the static-fallback call:
    #   _scrape_via_static_fallback(retailer, gender, max_products_per_page)
    #   combine_product_info(basic, detailed, retailer, gender)
```

Find every call to `_scrape_via_static_fallback(retailer, max_products_per_page)` and `combine_product_info(basic, detailed, retailer)` in `pagination_scraper.py` (use grep on the file) and add the `gender` arg to each.

- [ ] **Step 4: Replace the `__main__` block with argparse**

Replace lines 522-540 with:

```python
if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Scrape Hype DC listing")
    parser.add_argument(
        "--gender", choices=("mens", "womens"), default="mens",
        help="Which listing to scrape (default: mens).",
    )
    args = parser.parse_args()

    products = scrape_all_pages(
        base_url=LISTING_URLS[args.gender],
        retailer=RETAILER,
        gender=args.gender,
        max_pages=3,
        max_products_per_page=999,
    )
    if products:
        out = f"jsons/hypedc_{args.gender}_products.json"
        save_to_json(products, out)
        print(f"\nSaved {len(products)} products to {out}")
    else:
        print("No products scraped")
```

- [ ] **Step 5: Update the static-fallback path's caller in the freesh test (if it exists)**

Run:

```bash
cd sneaker-scout-backend && grep -rn "_scrape_via_static_fallback\|combine_product_info(" hypedc/ tests/
```

For every match, update to pass `gender` (use `"mens"` as the test fixture default since the saved freesh/ HTML is a mens listing).

- [ ] **Step 6: Verify tests + run the scraper**

```bash
source .venv/bin/activate
pytest tests/test_hypedc_unit_lock.py tests/test_hypedc_brand_extraction.py -v
```

Expected: green.

Then a CAPTCHA-aware live run (per CLAUDE.md, **headed mode only**):

```bash
HYPEDC_HEADLESS=false python -m hypedc.pagination_scraper --gender=womens
```

Solve any DataDome challenge interactively. Expected: `jsons/hypedc_womens_products.json` produced with `gender='womens'` on every colorway.

- [ ] **Step 7: Commit**

```bash
git -C /workspace/sneaker-scout-backend add hypedc/pagination_scraper.py tests/
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-v7h): hypedc scraper accepts --gender flag, emits gender per colorway"
```

---

## Task 9: Platypus scraper — per-gender URL + `--gender` CLI flag

**Files:**
- Modify: `sneaker-scout-backend/platypus/pagination_scraper.py:105, 345-410, 478, 595-609`

Apply the same pattern as Task 8. The Platypus listing URL changes from `/shop/mens/footwear/sneakers` to `/shop/womens/footwear/sneakers`. Output filename: `jsons/platypus_<gender>_products.json`. Static-fallback callers (`_scrape_via_static_fallback`) must take `gender` too.

- [ ] **Step 1: `LISTING_URLS` map at line 105**

```python
LISTING_URLS = {
    "mens": "https://www.platypusshoes.com.au/shop/mens/footwear/sneakers",
    "womens": "https://www.platypusshoes.com.au/shop/womens/footwear/sneakers",
}
```

- [ ] **Step 2: `combine_product_info(basic, detailed, retailer, gender)` — add `gender` to the colorway dict**

Same shape as Task 8 step 2.

- [ ] **Step 3: `scrape_all_pages(base_url=None, retailer=None, gender="mens", ...)` and update every call site for `combine_product_info` and any `_scrape_via_static_fallback` to pass `gender`**

- [ ] **Step 4: `__main__` block with argparse + `jsons/platypus_<gender>_products.json` output filename**

- [ ] **Step 5: Smoke-run both genders**

```bash
PLATYPUS_HEADLESS=false python -m platypus.pagination_scraper --gender=mens
PLATYPUS_HEADLESS=false python -m platypus.pagination_scraper --gender=womens
```

Expected: two JSONs, each with the correct `gender` on every colorway.

- [ ] **Step 6: Commit**

```bash
git -C /workspace/sneaker-scout-backend add platypus/pagination_scraper.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-v7h): platypus scraper accepts --gender flag, emits gender per colorway"
```

---

## Task 10: Foot Locker scraper — promote existing `section` to `--gender` CLI flag

`footlocker/pagination_scraper.py` already has a `section="mens"` parameter on `scrape_all_pages` and `navigate_to_listing_via_menu`. The work here is mostly renaming and wiring up the CLI flag.

**Files:**
- Modify: `sneaker-scout-backend/footlocker/pagination_scraper.py:108, 337-352, 782-843, 919-928, 1148-1169`

- [ ] **Step 1: Add `LISTING_URLS` and keep `LISTING_URL` as the mens alias**

Replace line 108 with:

```python
LISTING_URLS = {
    "mens": "https://www.footlocker.com.au/en/category/mens/shoes",
    "womens": "https://www.footlocker.com.au/en/category/womens/shoes",
}
LISTING_URL = LISTING_URLS["mens"]  # back-compat for any inner call still referencing the singular
```

- [ ] **Step 2: Rename the `section` kwarg to `gender` (or keep `section` and add `gender` as an alias)**

The existing `section` parameter on `scrape_all_pages` and `navigate_to_listing_via_menu` already accepts `"mens"`/`"womens"`. Rename it to `gender` for clarity, or keep `section` and treat it as the same axis. For brevity, **keep `section`** as the internal name and treat the `--gender` CLI flag as its driver.

- [ ] **Step 3: Plumb `gender` into `combine_product_info`**

Modify `combine_product_info(basic, detailed, retailer)` (line 782) to take `gender` and add `"gender": gender` to the colorway dict — same pattern as Task 8 step 2.

Find every call site (`grep -n combine_product_info footlocker/`) and pass `gender`.

- [ ] **Step 4: Update `__main__` with argparse + per-gender filename**

Replace lines 1148-1169 with:

```python
if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Scrape Foot Locker AU listing")
    parser.add_argument(
        "--gender", choices=("mens", "womens"), default="mens",
        help="Which listing to scrape (default: mens).",
    )
    args = parser.parse_args()

    max_pages = int(os.environ.get("FOOTLOCKER_MAX_PAGES", "3"))
    max_per_page = int(os.environ.get("FOOTLOCKER_MAX_PER_PAGE", "999"))
    products = scrape_all_pages(
        base_url=LISTING_URLS[args.gender],
        retailer=RETAILER,
        gender=args.gender,
        max_products_per_page=max_per_page,
        max_pages=max_pages,
        section=args.gender,  # drives the mega-menu click
    )
    if products:
        out = f"jsons/footlocker_{args.gender}_products.json"
        save_to_json(products, out)
        print(f"\nSaved {len(products)} products to {out}")
    else:
        print("No products scraped")
```

- [ ] **Step 5: Add `gender` to `scrape_all_pages` signature, forward to `combine_product_info`**

Modify line 919's signature to include `gender="mens"` and pass it into `combine_product_info` at each call site inside the function.

- [ ] **Step 6: Smoke-run both genders**

```bash
FOOTLOCKER_HEADLESS=false python -m footlocker.pagination_scraper --gender=mens
FOOTLOCKER_HEADLESS=false python -m footlocker.pagination_scraper --gender=womens
```

Expected: both JSONs produced, each with correct `colorway.gender`.

- [ ] **Step 7: Commit**

```bash
git -C /workspace/sneaker-scout-backend add footlocker/pagination_scraper.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-v7h): footlocker scraper accepts --gender flag, emits gender per colorway"
```

---

## Task 11: JD Sports scraper — per-gender URL + `--gender` CLI flag

**Files:**
- Modify: `sneaker-scout-backend/jdsports/pagination_scraper.py:101, 444-502, 563, 684-702`

- [ ] **Step 1: `LISTING_URLS` map at line 101**

```python
LISTING_URLS = {
    "mens": "https://www.jd-sports.com.au/men/mens-footwear/trainers/",
    "womens": "https://www.jd-sports.com.au/women/womens-footwear/trainers/",
}
```

(If the women's URL differs in URL structure on the JD site, capture the real one via a quick browser hit before committing. The above mirrors the men's URL pattern; JD's site has historically mirrored this.)

- [ ] **Step 2: `combine_product_info(basic, detailed, retailer, gender)` — add `gender` to the colorway dict** (same pattern as Task 8 step 2)

- [ ] **Step 3: Plumb `gender` through `scrape_all_pages` and forward to `combine_product_info`**

- [ ] **Step 4: Replace `__main__` with argparse + per-gender filename**

```python
if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Scrape JD Sports AU listing")
    parser.add_argument(
        "--gender", choices=("mens", "womens"), default="mens",
        help="Which listing to scrape (default: mens).",
    )
    args = parser.parse_args()

    max_pages = int(os.environ.get("JDSPORTS_MAX_PAGES", "1"))
    max_per_page = int(os.environ.get("JDSPORTS_MAX_PER_PAGE", "3"))
    products = scrape_all_pages(
        base_url=LISTING_URLS[args.gender],
        retailer=RETAILER,
        gender=args.gender,
        max_pages=max_pages,
        max_products_per_page=max_per_page,
    )
    if products:
        out = f"jsons/jdsports_{args.gender}_products.json"
        save_to_json(products, out)
        print(f"\nSaved {len(products)} products to {out}")
    else:
        print("No products scraped")
```

- [ ] **Step 5: Smoke-run both genders**

```bash
JDSPORTS_HEADLESS=false python -m jdsports.pagination_scraper --gender=mens
JDSPORTS_HEADLESS=false python -m jdsports.pagination_scraper --gender=womens
```

Expected: both JSONs produced.

- [ ] **Step 6: Commit**

```bash
git -C /workspace/sneaker-scout-backend add jdsports/pagination_scraper.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-v7h): jdsports scraper accepts --gender flag, emits gender per colorway"
```

---

## Task 12: Docker entrypoint — scrape + upload both genders

**Files:**
- Modify: `sneaker-scout-backend/entrypoint.sh`

- [ ] **Step 1: Update `run_pipeline` to run mens AND womens for Salomon**

Replace the body of `run_pipeline` with:

```bash
run_pipeline() {
    echo ""
    echo "=========================================="
    echo "Pipeline run starting at $(date)"
    echo "=========================================="

    cd /app

    for gender in mens womens; do
        echo "[Salomon] Scraping ${gender}..."
        python -m backend.salomon.pagination_scraper --gender=${gender}
        SCRAPE_EXIT=$?
        if [ $SCRAPE_EXIT -ne 0 ]; then
            echo "[ERROR] Salomon ${gender} scraper failed with exit code $SCRAPE_EXIT"
            return 1
        fi

        echo "[Salomon] Uploading ${gender}..."
        python -m backend.data_upload.run_update --file=backend/jsons/salomon_${gender}_products.json
        UPLOAD_EXIT=$?
        if [ $UPLOAD_EXIT -ne 0 ]; then
            echo "[ERROR] Salomon ${gender} upload failed with exit code $UPLOAD_EXIT"
            return 1
        fi
    done

    echo "=========================================="
    echo "Pipeline run finished at $(date)"
    echo "=========================================="
}
```

(The loop pattern makes adding hypedc/platypus/footlocker/jdsports later — per existing CLAUDE.md note — a one-line append per retailer.)

- [ ] **Step 2: Smoke-run the container**

```bash
docker-compose run --rm backend python -m backend.salomon.pagination_scraper --gender=womens
```

Expected: a successful run that produces `backend/jsons/salomon_womens_products.json` inside the container.

- [ ] **Step 3: Commit**

```bash
git -C /workspace/sneaker-scout-backend add entrypoint.sh
git -C /workspace/sneaker-scout-backend commit -m "chore(sneaker_scout-v7h): entrypoint runs salomon mens + womens each cycle"
```

---

## Task 13: FilterContext — add `selectedGender` + `?gender=` URL param

**Files:**
- Modify: `aussie-kicks-tracker/src/contexts/FilterContext.tsx`

- [ ] **Step 1: Extend the context shape and reader**

Replace the entire file content with:

```tsx
import { createContext, useCallback, useContext, useMemo } from 'react';
import { useSearchParams } from 'react-router-dom';

export type Gender = 'all' | 'mens' | 'womens';

interface FilterContextValue {
  selectedRetailerIds: string[];
  selectedSizes: number[];
  selectedGender: Gender;
  toggleRetailer: (id: string) => void;
  toggleSize: (size: number) => void;
  setRetailers: (ids: string[]) => void;
  setSizes: (sizes: number[]) => void;
  setGender: (gender: Gender) => void;
  clearAll: () => void;
  hasAnyFilter: boolean;
}

const FilterContext = createContext<FilterContextValue | null>(null);

const RETAILER_PARAM = 'retailers';
const SIZE_PARAM = 'sizes';
const GENDER_PARAM = 'gender';

const isGender = (v: string | null): v is Gender =>
  v === 'mens' || v === 'womens' || v === 'all';

export const FilterProvider = ({ children }: { children: React.ReactNode }) => {
  const [searchParams, setSearchParams] = useSearchParams();

  const selectedRetailerIds = useMemo(() => {
    const raw = searchParams.get(RETAILER_PARAM);
    if (!raw) return [];
    return raw.split(',').filter(Boolean);
  }, [searchParams]);

  const selectedSizes = useMemo(() => {
    const raw = searchParams.get(SIZE_PARAM);
    if (!raw) return [];
    return raw
      .split(',')
      .map((s) => Number(s))
      .filter((n) => Number.isFinite(n));
  }, [searchParams]);

  const selectedGender: Gender = useMemo(() => {
    const raw = searchParams.get(GENDER_PARAM);
    return isGender(raw) ? raw : 'all';
  }, [searchParams]);

  const writeRetailers = useCallback(
    (ids: string[]) => {
      setSearchParams((prev) => {
        const next = new URLSearchParams(prev);
        if (ids.length === 0) next.delete(RETAILER_PARAM);
        else next.set(RETAILER_PARAM, ids.join(','));
        return next;
      });
    },
    [setSearchParams]
  );

  const writeSizes = useCallback(
    (sizes: number[]) => {
      setSearchParams((prev) => {
        const next = new URLSearchParams(prev);
        if (sizes.length === 0) next.delete(SIZE_PARAM);
        else next.set(SIZE_PARAM, sizes.join(','));
        return next;
      });
    },
    [setSearchParams]
  );

  const setGender = useCallback(
    (gender: Gender) => {
      setSearchParams((prev) => {
        const next = new URLSearchParams(prev);
        if (gender === 'all') next.delete(GENDER_PARAM);
        else next.set(GENDER_PARAM, gender);
        return next;
      });
    },
    [setSearchParams]
  );

  const toggleRetailer = useCallback(
    (id: string) => {
      const next = selectedRetailerIds.includes(id)
        ? selectedRetailerIds.filter((x) => x !== id)
        : [...selectedRetailerIds, id];
      writeRetailers(next);
    },
    [selectedRetailerIds, writeRetailers]
  );

  const toggleSize = useCallback(
    (size: number) => {
      const next = selectedSizes.includes(size)
        ? selectedSizes.filter((x) => x !== size)
        : [...selectedSizes, size];
      writeSizes(next);
    },
    [selectedSizes, writeSizes]
  );

  const clearAll = useCallback(() => {
    setSearchParams((prev) => {
      const next = new URLSearchParams(prev);
      next.delete(RETAILER_PARAM);
      next.delete(SIZE_PARAM);
      next.delete(GENDER_PARAM);
      return next;
    });
  }, [setSearchParams]);

  const value = useMemo<FilterContextValue>(
    () => ({
      selectedRetailerIds,
      selectedSizes,
      selectedGender,
      toggleRetailer,
      toggleSize,
      setRetailers: writeRetailers,
      setSizes: writeSizes,
      setGender,
      clearAll,
      hasAnyFilter:
        selectedRetailerIds.length > 0 ||
        selectedSizes.length > 0 ||
        selectedGender !== 'all',
    }),
    [
      selectedRetailerIds,
      selectedSizes,
      selectedGender,
      toggleRetailer,
      toggleSize,
      writeRetailers,
      writeSizes,
      setGender,
      clearAll,
    ]
  );

  return <FilterContext.Provider value={value}>{children}</FilterContext.Provider>;
};

export const useFilters = () => {
  const ctx = useContext(FilterContext);
  if (!ctx) throw new Error('useFilters must be used within FilterProvider');
  return ctx;
};
```

- [ ] **Step 2: Type-check**

```bash
cd aussie-kicks-tracker && npm run build
```

Expected: builds. The new `selectedGender` and `setGender` are unused so far; no call site change is required for this commit.

- [ ] **Step 3: Commit**

```bash
git -C /workspace/aussie-kicks-tracker add src/contexts/FilterContext.tsx
git -C /workspace/aussie-kicks-tracker commit -m "feat(sneaker_scout-v7h): FilterContext owns gender filter via ?gender= URL param"
```

---

## Task 14: GenderToggle component

**Files:**
- Create: `aussie-kicks-tracker/src/components/GenderToggle.tsx`

- [ ] **Step 1: Create the component**

Write the entire file:

```tsx
import { Button } from '@/components/ui/button';
import { useFilters, type Gender } from '@/contexts/FilterContext';

const OPTIONS: { value: Gender; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: 'mens', label: 'Mens' },
  { value: 'womens', label: 'Womens' },
];

export const GenderToggle = () => {
  const { selectedGender, setGender } = useFilters();
  return (
    <div
      className="flex items-center rounded-md border bg-muted/30 p-0.5"
      role="group"
      aria-label="Filter by gender"
    >
      {OPTIONS.map((o) => (
        <Button
          key={o.value}
          variant={selectedGender === o.value ? 'default' : 'ghost'}
          size="sm"
          onClick={() => setGender(o.value)}
          aria-pressed={selectedGender === o.value}
        >
          {o.label}
        </Button>
      ))}
    </div>
  );
};
```

(The `Gender` type is re-exported from `FilterContext.tsx`; the component is self-contained.)

- [ ] **Step 2: Type-check**

```bash
cd aussie-kicks-tracker && npm run build
```

Expected: builds. Component not yet rendered.

- [ ] **Step 3: Commit**

```bash
git -C /workspace/aussie-kicks-tracker add src/components/GenderToggle.tsx
git -C /workspace/aussie-kicks-tracker commit -m "feat(sneaker_scout-v7h): GenderToggle segmented control"
```

---

## Task 15: Apply gender filter in listing hooks

**Files:**
- Modify: `aussie-kicks-tracker/src/hooks/useSneakers.tsx` (`useSneakers`, `useColorwaysCount`, `useInStockCount`, `usePriceDropsCount`)

The pattern is identical for all four hooks: take a `gender: Gender` parameter (default `'all'`), include it in the cache key, and when it isn't `'all'`, promote the colorways embed to `!inner` and add `.eq('colorways.gender', gender)` to the query.

- [ ] **Step 1: Add `gender` to `useSneakers`**

Modify the `useSneakers` signature (line 49) and body. The full new signature + the spots that change:

```tsx
import type { Gender } from '@/contexts/FilterContext';

export const useSneakers = (
  page: number = 1,
  limit: number = 20,
  retailerIds: string[] = [],
  sizes: number[] = [],
  gender: Gender = 'all'
) => {
  const retailerKey = [...retailerIds].sort().join(',');
  const sizeKey = [...sizes].sort((a, b) => a - b).join(',');

  return useQuery({
    queryKey: ['sneakers', page, limit, retailerKey, sizeKey, gender],
    queryFn: async (): Promise<PaginatedSneakers> => {
      const offset = (page - 1) * limit;
      const hasRetailerFilter = retailerIds.length > 0;
      const hasSizeFilter = sizes.length > 0;
      const hasGenderFilter = gender !== 'all';
      const wantInnerColorways = hasRetailerFilter || hasSizeFilter || hasGenderFilter;

      let colorwaySelect: string;
      if (hasSizeFilter) {
        colorwaySelect =
          'colorways!inner(id, name, color_code, image_url, gender, sneaker_sizes!inner(retailer_id, is_available, sizes!inner(us_size)))';
      } else if (wantInnerColorways) {
        // retailer- or gender-only — still need inner join to drop sneakers
        // with no surviving colorway.
        colorwaySelect =
          'colorways!inner(id, name, color_code, image_url, gender' +
          (hasRetailerFilter ? ', prices!inner(retailer_id, is_available)' : '') +
          ')';
      } else {
        colorwaySelect = 'colorways(id, name, color_code, image_url, gender)';
      }

      let query = supabase
        .from('sneakers')
        .select(/* ... unchanged template literal with ${colorwaySelect} ... */, {
          count: 'exact',
        })
        .order('name')
        .range(offset, offset + limit - 1);

      if (hasSizeFilter) {
        query = query
          .in('colorways.sneaker_sizes.sizes.us_size', sizes)
          .eq('colorways.sneaker_sizes.is_available', true);
        if (hasRetailerFilter) {
          query = query.in('colorways.sneaker_sizes.retailer_id', retailerIds);
        }
      } else if (hasRetailerFilter) {
        query = query
          .in('colorways.prices.retailer_id', retailerIds)
          .eq('colorways.prices.is_available', true);
      }

      if (hasGenderFilter) {
        query = query.eq('colorways.gender', gender);
      }

      // ... rest of the function unchanged ...
```

(Keep the rest of the function as-is. The `colorwaySelect` block is the only structural change; the new `if (hasGenderFilter)` line slots in before the existing `await query` call.)

- [ ] **Step 2: Add `gender` to `useColorwaysCount`**

Replace its signature and body's filter block:

```tsx
export const useColorwaysCount = (
  retailerIds: string[] = [],
  sizes: number[] = [],
  gender: Gender = 'all'
) => {
  const retailerKey = [...retailerIds].sort().join(',');
  const sizeKey = [...sizes].sort((a, b) => a - b).join(',');
  return useQuery({
    queryKey: ['colorwaysCount', retailerKey, sizeKey, gender],
    queryFn: async (): Promise<number> => {
      const hasRetailerFilter = retailerIds.length > 0;
      const hasSizeFilter = sizes.length > 0;
      const hasGenderFilter = gender !== 'all';

      if (!hasRetailerFilter && !hasSizeFilter && !hasGenderFilter) {
        const { count, error } = await supabase
          .from('colorways')
          .select('id', { count: 'exact', head: true });
        if (error) {
          console.error('colorwaysCount error:', error);
          return 0;
        }
        return count ?? 0;
      }

      let query = supabase
        .from('colorways')
        .select(
          hasSizeFilter
            ? 'id, gender, sneaker_sizes!inner(retailer_id, is_available, sizes!inner(us_size))'
            : hasRetailerFilter
              ? 'id, gender, prices!inner(retailer_id, is_available)'
              : 'id, gender'
        );
      if (hasSizeFilter) {
        query = query
          .in('sneaker_sizes.sizes.us_size', sizes)
          .eq('sneaker_sizes.is_available', true);
        if (hasRetailerFilter) {
          query = query.in('sneaker_sizes.retailer_id', retailerIds);
        }
      } else if (hasRetailerFilter) {
        query = query
          .in('prices.retailer_id', retailerIds)
          .eq('prices.is_available', true);
      }
      if (hasGenderFilter) {
        query = query.eq('gender', gender);
      }

      const { data, error } = await query;
      if (error) {
        console.error('colorwaysCount error:', error);
        return 0;
      }
      const seen = new Set<string>();
      (data ?? []).forEach((row: { id: string }) => seen.add(row.id));
      return seen.size;
    },
  });
};
```

- [ ] **Step 3: Same pattern for `useInStockCount`**

Add `gender: Gender = 'all'` parameter; include in `queryKey`; promote colorways embed to `!inner` and add `.eq('colorways.gender', gender)` when `hasGenderFilter`.

- [ ] **Step 4: Same pattern for `usePriceDropsCount`**

Same shape — add `gender` parameter, embed promotion, filter clause.

- [ ] **Step 5: Type-check**

```bash
cd aussie-kicks-tracker && npm run build
```

Expected: builds. Existing call sites (Index, Admin, Sale) will still work since `gender` defaults to `'all'`.

- [ ] **Step 6: Commit**

```bash
git -C /workspace/aussie-kicks-tracker add src/hooks/useSneakers.tsx
git -C /workspace/aussie-kicks-tracker commit -m "feat(sneaker_scout-v7h): listing hooks honour gender filter"
```

---

## Task 16: Apply gender filter in sale hooks

**Files:**
- Modify: `aussie-kicks-tracker/src/lib/sneakerQueries.ts` (`fetchSaleColorways`, `fetchSaleColorwaysSignalCount`, `fetchSaleColorwaysCount`)
- Modify: `aussie-kicks-tracker/src/hooks/useSneakers.tsx` (`useSaleColorways`, `useSaleColorwaysSignalCount` to accept `gender`)

The base table for `/sale` queries is `colorways`, so the filter clause is `.eq('gender', gender)` (no nested path).

- [ ] **Step 1: Extend `fetchSaleColorways` to accept and apply `gender`**

In `sneakerQueries.ts`, modify the signature and body:

```ts
import type { Gender } from '@/contexts/FilterContext';

export async function fetchSaleColorways(
  signal: SaleSignal,
  retailerIds: string[],
  sizes: number[],
  gender: Gender = 'all'
): Promise<SaleColorway[]> {
  const hasRetailer = retailerIds.length > 0;
  const hasSize = sizes.length > 0;
  const hasGender = gender !== 'all';

  // ... existing selectShape construction unchanged ...

  let query = supabase
    .from('colorways')
    .select(selectShape)
    .or(SIGNAL_TO_FILTER[signal], { foreignTable: 'prices' });

  if (hasRetailer) {
    query = query.in('prices.retailer_id', retailerIds);
  }
  if (hasSize) {
    query = query
      .in('sneaker_sizes.sizes.us_size', sizes)
      .eq('sneaker_sizes.is_available', true);
    if (hasRetailer) {
      query = query.in('sneaker_sizes.retailer_id', retailerIds);
    }
  }
  if (hasGender) {
    query = query.eq('gender', gender);
  }

  // ... rest of the function unchanged ...
}
```

- [ ] **Step 2: Same treatment for `fetchSaleColorwaysSignalCount`**

Add `gender: Gender = 'all'` param, mirror the `if (hasGender) query = query.eq('gender', gender)` clause.

`fetchSaleColorwaysCount` delegates to `fetchSaleColorwaysSignalCount` — it can stay unfiltered (it drives the unfiltered Index hero tile), so no change beyond what the delegate provides.

- [ ] **Step 3: Pass `gender` from `useSaleColorways` and `useSaleColorwaysSignalCount`**

In `useSneakers.tsx`, extend both hooks:

```tsx
export const useSaleColorways = (
  page: number = 1,
  limit: number = 20,
  retailerIds: string[] = [],
  sizes: number[] = [],
  signal: SaleSignal = 'all',
  sort: SaleSort = 'pct',
  gender: Gender = 'all'
) => {
  const retailerKey = [...retailerIds].sort().join(',');
  const sizeKey = [...sizes].sort((a, b) => a - b).join(',');

  return useQuery({
    queryKey: ['saleColorways', signal, retailerKey, sizeKey, gender],
    queryFn: () => fetchSaleColorways(signal, retailerIds, sizes, gender),
    select: (rows): PaginatedSaleColorways => {
      // ... unchanged ...
    },
  });
};

export const useSaleColorwaysSignalCount = (
  signal: SaleSignal,
  retailerIds: string[] = [],
  sizes: number[] = [],
  gender: Gender = 'all'
) => {
  const retailerKey = [...retailerIds].sort().join(',');
  const sizeKey = [...sizes].sort((a, b) => a - b).join(',');
  return useQuery({
    queryKey: ['saleColorwaysSignalCount', signal, retailerKey, sizeKey, gender],
    queryFn: () => fetchSaleColorwaysSignalCount(signal, retailerIds, sizes, gender),
  });
};
```

- [ ] **Step 4: Type-check**

```bash
cd aussie-kicks-tracker && npm run build
```

Expected: builds.

- [ ] **Step 5: Commit**

```bash
git -C /workspace/aussie-kicks-tracker add src/lib/sneakerQueries.ts src/hooks/useSneakers.tsx
git -C /workspace/aussie-kicks-tracker commit -m "feat(sneaker_scout-v7h): sale hooks honour gender filter"
```

---

## Task 17: Render `<GenderToggle/>` on `/` and `/sale`, pass `gender` into hooks

**Files:**
- Modify: `aussie-kicks-tracker/src/pages/Index.tsx`
- Modify: `aussie-kicks-tracker/src/pages/Sale.tsx`

- [ ] **Step 1: Wire the toggle into `Index.tsx`**

In `src/pages/Index.tsx`:

a) Import the new pieces near the existing imports:

```tsx
import { GenderToggle } from '@/components/GenderToggle';
```

b) Pull `selectedGender` from `useFilters`:

```tsx
const { selectedRetailerIds, selectedSizes, selectedGender } = useFilters();
const filterKey = `${selectedRetailerIds.join(',')}|${selectedSizes.join(',')}|${selectedGender}`;
```

c) Pass `selectedGender` into both hooks:

```tsx
const { data: sneakersData, isLoading } = useSneakers(currentPage, itemsPerPage, selectedRetailerIds, selectedSizes, selectedGender);
const { data: colorwaysTotal = 0 } = useColorwaysCount(selectedRetailerIds, selectedSizes, selectedGender);
```

d) Render `<GenderToggle/>` in the header of the listings card — directly inside the `<CardHeader><div className="flex items-center justify-between">` block, alongside the existing view-mode buttons. The minimal edit is to add a sibling row above the existing controls, e.g.:

```tsx
<div className="flex items-center gap-3 mb-3">
  <GenderToggle />
</div>
```

Place it inside `<CardContent>` above the `<Tabs>` block for the cleanest layout, or in the header next to the view-mode toggles if you want it inline. Reviewer's choice — the spec calls it a "chip above the listing".

- [ ] **Step 2: Wire the toggle into `Sale.tsx`**

In `src/pages/Sale.tsx`:

a) Import:

```tsx
import { GenderToggle } from '@/components/GenderToggle';
```

b) Pull `selectedGender`:

```tsx
const { selectedRetailerIds, selectedSizes, selectedGender, clearAll, hasAnyFilter } = useFilters();
const filterKey = `${signal}|${sort}|${selectedRetailerIds.join(',')}|${selectedSizes.join(',')}|${selectedGender}`;
```

c) Pass `selectedGender` into both hooks (3 signal-count calls + the main listing hook):

```tsx
const { data: allCount = 0 } = useSaleColorwaysSignalCount('all', selectedRetailerIds, selectedSizes, selectedGender);
const { data: saleCount = 0 } = useSaleColorwaysSignalCount('sale', selectedRetailerIds, selectedSizes, selectedGender);
const { data: lowestCount = 0 } = useSaleColorwaysSignalCount('lowest', selectedRetailerIds, selectedSizes, selectedGender);
// ...
const { data, isLoading } = useSaleColorways(currentPage, ITEMS_PER_PAGE, selectedRetailerIds, selectedSizes, signal, sort, selectedGender);
```

d) Render the toggle above the listing — beside the existing `<SignalChips>` and `<SortDropdown>` in the card header, or as a standalone row above the card:

```tsx
<div className="flex items-center gap-3 mb-4">
  <GenderToggle />
</div>
```

- [ ] **Step 3: Run the dev server and smoke-test the toggle**

```bash
cd aussie-kicks-tracker && npm run dev
```

Open http://localhost:8080/ and verify:

- Toggle renders with `All` highlighted.
- Click `Womens`. URL updates to `?gender=womens`. Listing reflows to show only colorways whose `gender='womens'`.
- Click `Mens`. URL updates to `?gender=mens`. Listing shows the mens set.
- Click `All`. `?gender=` clears from the URL. Full listing returns.

Same test at http://localhost:8080/sale: the toggle drives the qualifying-colorway set, and the (N) numbers next to each signal chip update.

- [ ] **Step 4: Lint + build**

```bash
npm run lint && npm run build
```

Expected: clean lint + successful build.

- [ ] **Step 5: Commit**

```bash
git -C /workspace/aussie-kicks-tracker add src/pages/Index.tsx src/pages/Sale.tsx
git -C /workspace/aussie-kicks-tracker commit -m "feat(sneaker_scout-v7h): gender toggle on / and /sale"
```

---

## Task 18: Update living documents (SITEMAP.md + spec.yaml + CLAUDE.md)

**Files:**
- Modify: `aussie-kicks-tracker/SITEMAP.md` (Index `/` and `/sale` URL-param tables)
- Modify: `spec.yaml` (Colorway schema + `/rest/v1/colorways` example + scraper CLI section)
- Modify: `CLAUDE.md` (dev-run examples)

- [ ] **Step 1: SITEMAP.md — add `gender` to the URL-param tables**

In `aussie-kicks-tracker/SITEMAP.md`:

Under `## / — Index (public listing)` (around line 30) and `## /sale — Sale / price-drop listing` (around line 109), insert a new row in each `URL params` table:

```
| `gender` | `mens` \| `womens` (anything else = `all`) | Restrict listing to colorways with the matching `gender`. Shared via `FilterContext`. |
```

- [ ] **Step 2: spec.yaml — extend Colorway schema and `/rest/v1/colorways`**

a) In the `Colorway` schema block (around line 87), add:

```yaml
        gender:
          type: string
          enum: [mens, womens, unisex, kids]
          description: |
            Demographic the colorway is marketed to. Backfilled `mens` by
            migration 20260517120000-v7h; every retailer scraper since
            then emits the gender per colorway based on which listing URL
            the row was scraped from. See sneaker_scout-v7h.
```

b) Under `/rest/v1/colorways` (around line 332), add an `x-curl-example` for the gender filter:

```yaml
      x-gender-filter-example: |
        # Restrict to womens colorways only — used by the `?gender=womens`
        # URL state on the `/` and `/sale` pages.
        curl "$SUPABASE_URL/rest/v1/colorways?gender=eq.womens&select=id,name,gender" \
          -H "apikey: $SUPABASE_ANON_KEY"
```

c) In the scraper CLI section (search for `scraper CLI` or the `salomon.pagination_scraper` reference), document the `--gender` flag:

```yaml
        Per-retailer invocation, one process per gender. Each writes a per-gender JSON:

          python -m salomon.pagination_scraper --gender=mens
          python -m salomon.pagination_scraper --gender=womens
            -> jsons/salomon_mens_products.json, jsons/salomon_womens_products.json

        Default is --gender=mens. Same flag on hypedc/platypus/footlocker/jdsports.
        Upload each JSON via data_upload.run_update --file=jsons/<retailer>_<gender>_products.json.
```

- [ ] **Step 3: CLAUDE.md (repo root) — update the dev-run examples**

In `/workspace/CLAUDE.md`, find the "Run locally (recommended for dev)" block (under `### Backend (sneaker-scout-backend/)`). Update each scraper invocation example to pass `--gender=mens` (and add a note about womens). After the change the relevant block reads:

```bash
# Stage 1 — scrape (produces jsons/<retailer>_<gender>_products.json)
python -m salomon.pagination_scraper --gender=mens
python -m salomon.pagination_scraper --gender=womens
python -m hypedc.pagination_scraper --gender=mens   # repeat with --gender=womens
# ... etc for platypus, footlocker, jdsports ...

# Stage 2 — upload (.env must define SUPABASE_URL + SUPABASE_SERVICE_KEY)
python -m data_upload.run_update --file=jsons/salomon_mens_products.json
python -m data_upload.run_update --file=jsons/salomon_womens_products.json
# ... repeat per retailer/gender
```

- [ ] **Step 4: Commit**

```bash
git -C /workspace/aussie-kicks-tracker add SITEMAP.md
git -C /workspace/aussie-kicks-tracker commit -m "docs(sneaker_scout-v7h): SITEMAP gender param on / and /sale"

git -C /workspace add spec.yaml CLAUDE.md
git -C /workspace commit -m "docs(sneaker_scout-v7h): spec + CLAUDE describe gender + --gender flag"
```

(If your workspace layout has the SITEMAP/spec/CLAUDE files under different git repos than shown here, match each commit to its owning repo. Use `git -C <path>` to be explicit.)

---

## Task 19: End-to-end smoke + close the bead

**Files:** (no edits — verification only)

- [ ] **Step 1: Run the full backend test suite**

```bash
cd sneaker-scout-backend && source .venv/bin/activate
pytest -v
```

Expected: all green, including `test_schema_colorway_gender.py` and the new bulk-upload tests.

- [ ] **Step 2: Run the frontend lint + build**

```bash
cd aussie-kicks-tracker
npm run lint
npm run build
```

Expected: clean.

- [ ] **Step 3: Full end-to-end smoke in the browser**

```bash
npm run dev
```

Open:
- http://localhost:8080/ — toggle through `All` / `Mens` / `Womens`; combine with a retailer chip and a size chip; verify counts on the tiles refresh; verify cards still render correctly.
- http://localhost:8080/sale — same toggle behavior; verify the (N) numbers next to each signal chip update with the gender filter.
- http://localhost:8080/sneaker/<some-uuid> — the detail page is unchanged but should still render (no regression).

- [ ] **Step 4: Close the bead and commit the bd state**

```bash
cd /workspace
bd close sneaker_scout-v7h --reason="schema, scrapers, frontend toggle all shipped under plan 2026-05-17-v7h"
git -C /workspace add .beads/
git -C /workspace commit -m "chore: bd state for sneaker_scout-v7h close"
```

- [ ] **Step 5: Session-close push** (per CLAUDE.md Session Completion workflow)

```bash
# /workspace
git pull --rebase && git push
# sneaker-scout-backend (nested repo)
git -C /workspace/sneaker-scout-backend pull --rebase && git -C /workspace/sneaker-scout-backend push
# aussie-kicks-tracker (nested repo) — only if it has a remote
git -C /workspace/aussie-kicks-tracker pull --rebase && git -C /workspace/aussie-kicks-tracker push
```

Expected: each `git status` reports `up to date with origin`. If any repo has no remote configured, skip its `git push` (per the bd-prime note about local-only mode).

---

## Risks and rollback

- **Empty backfill** — if the SQL `UPDATE` in Task 1 leaves any colorway row with `NULL` gender, the `ALTER COLUMN gender SET NOT NULL` will fail and the migration's `BEGIN`/`COMMIT` block rolls everything back. Investigate; this implies the row was inserted between the `UPDATE` and the `ALTER` (unlikely with no concurrent writes during deploy).
- **Mis-classified women's URL on a retailer** — if a retailer's women's listing URL is wrong (e.g. JD Sports has a different slug than guessed), Task 11 step 5's smoke run will fail to produce a JSON; correct the URL constant before re-running.
- **PostgREST nested filter quirks** — if `.eq('colorways.gender', gender)` doesn't filter on a sneakers-base query (because the embed isn't promoted to `!inner`), the listing will return sneakers with zero surviving colorways. The Task 15 code uses `wantInnerColorways` to guard this; verify in the browser that switching to `Womens` actually narrows the visible cards.
- **Filenames break Docker uploads** — Task 12 updates the entrypoint. If you skip that task but ship the new scrapers, the container's `salomon_products.json` (singular) path is gone and uploads silently 404. Run docker-compose locally after Task 12 to verify.

If a problem surfaces in production after deploy, revert via:

```sql
ALTER TABLE public.colorways DROP CONSTRAINT colorways_gender_check;
ALTER TABLE public.colorways DROP COLUMN gender;
```

(plus reverting the migration file and the code that references the column).

---

## Self-review checklist

- **Spec coverage:** Migration ✓ · backfill ✓ · scraper emit per retailer ✓ (×5) · filter chip on `/` and `/sale` ✓ · enum values mens/womens/unisex/kids ✓ (CHECK constraint).
- **Placeholders:** None — every step contains the actual code/command.
- **Type consistency:** `Gender` type defined once in `FilterContext.tsx`, imported everywhere (`GenderToggle`, `useSneakers`, `sneakerQueries`). `selectedGender` ↔ `setGender` API stable across consumers.
- **Living docs:** SITEMAP + spec.yaml + CLAUDE.md updated (Task 18) in the same plan that ships the code.
- **Beads + commits:** one commit per task, prefixed `<type>(sneaker_scout-v7h)`; bd close happens at the end alongside the bd-state commit.
