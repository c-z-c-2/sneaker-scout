# Sneaker-name normalization at ingest — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Supabase ingest pipeline collapse retailer-specific sneaker-name variants (`XT-6` vs `Salomon XT-6`; `Nike Air Force 1'07` vs `Nike Mens Air Force 1 '07`) onto a single `sneakers` row so the frontend stops rendering duplicate cards.

**Architecture:** Add a `lookup_key text` column to the `sneakers` table; populate it via a deterministic Python normalizer (`sneaker_lookup_key()` in `data_upload/canonicalize.py`) that strips the canonical brand prefix, strips a leading "Mens"/"Womens" qualifier, lowercases, and strips all non-alphanumerics. `update_supabase_daily.py`'s sneaker-upsert site looks up by `(brand_id, lookup_key)` instead of by `(brand_id, name)`. **Display-name policy is first-write-wins:** when a matching row is found, the existing `name` is kept; only `model` / `release_date` / `description` continue to be refreshed each run (matching today's behaviour). A one-off Python backfill computes `lookup_key` for the rows already in production. The unique constraint is deferred to `sneaker_scout-xdl` because existing duplicates would break it.

**Tech Stack:** Python 3.11+ (system pytest), Supabase Postgres, supabase-py client. New runtime dependency: none. The normalizer is dependency-free.

**Scope note:** This plan is scoped to the sneaker axis only. Colorway normalization is `sneaker_scout-s8z` (mirrors this plan structurally). Brand canonicalization is `sneaker_scout-1oj` (already shipped). Backfill-with-unique-constraint is `sneaker_scout-xdl`.

**Depends on:** `sneaker_scout-1oj` (✓ closed) — `sneaker_lookup_key` calls `canonicalize_brand` from that work to know what prefix to strip.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `aussie-kicks-tracker/supabase/migrations/20260511120000-ery-add-sneakers-lookup-key.sql` | Create | Schema migration: `ALTER TABLE sneakers ADD COLUMN lookup_key text NOT NULL DEFAULT ''` + non-unique index. NOT NULL with default lets the migration run before the backfill; the application code never writes an empty key after the backfill. |
| `sneaker-scout-backend/data_upload/canonicalize.py` | Modify | Add `sneaker_lookup_key(scraped_name, canonical_brand) -> str` alongside the existing `canonicalize_brand`. ~25 new lines. |
| `sneaker-scout-backend/tests/test_canonicalize.py` | Modify | Add tests for `sneaker_lookup_key`. ~50 new lines. |
| `sneaker-scout-backend/data_upload/backfill_lookup_keys.py` | Create | One-off Python script: reads every sneakers row + its brand, computes `lookup_key`, UPDATEs. Idempotent (re-running rewrites the same keys). |
| `sneaker-scout-backend/data_upload/update_supabase_daily.py` | Modify | Replace the sneaker-upsert block (~lines 168-200) so the lookup uses `lookup_key` and inserts populate it. Display-name first-write-wins. |
| `aussie-kicks-tracker/src/integrations/supabase/types.ts` | Regenerate (optional, recommended) | Pick up the new column so frontend types stay consistent. The frontend doesn't read `lookup_key`, so a stale types.ts won't break the UI — but regenerating prevents drift. |
| `spec.yaml` (repo root) | No change | spec.yaml describes the Supabase REST surface the frontend consumes; the frontend doesn't read `lookup_key`. |
| `aussie-kicks-tracker/SITEMAP.md` | No change | No route or page-level changes. |

---

## Repository layout reminder

Three independent git repos in play:
- `/workspace` — top-level, contains `.beads/` and the plan docs. **Beads commits land here.**
- `/workspace/sneaker-scout-backend/` — its own repo, contains the Python uploader and tests. **Implementation commits land here.**
- `/workspace/aussie-kicks-tracker/` — its own repo, contains the Supabase migrations and frontend types. **Migration commit lands here.**

Use `git -C <path>` to operate on a specific repo. NEVER use `git add -A` / `git add .` / `git commit -am` — the working trees have pre-existing dirty state from earlier work that must stay out of `ery`'s commits.

---

## Task 1: Schema migration

**Files:**
- Create: `aussie-kicks-tracker/supabase/migrations/20260511120000-ery-add-sneakers-lookup-key.sql`

- [ ] **Step 1: Create the migration file**

```sql
-- sneaker_scout-ery: add lookup_key column for sneaker-name normalization.
--
-- The Python ingest (data_upload/update_supabase_daily.py) computes
-- sneaker_lookup_key(scraped_name, canonical_brand) and uses it to match
-- the same physical shoe across retailers (e.g. 'XT-6' from salomon.com.au
-- and 'Salomon XT-6' from Hype DC both hash to 'xt6'). lookup_key is
-- written on insert and used for the upsert SELECT.
--
-- Constraint deferred to sneaker_scout-xdl: a UNIQUE(brand_id, lookup_key)
-- index would fail today because production already has duplicate sneaker
-- rows that share a lookup_key once normalized. xdl deduplicates first,
-- then adds the unique constraint.

ALTER TABLE public.sneakers
  ADD COLUMN lookup_key text NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS sneakers_brand_lookup_key_idx
  ON public.sneakers (brand_id, lookup_key);

COMMENT ON COLUMN public.sneakers.lookup_key IS
  'Normalized lookup key computed at ingest time by data_upload.canonicalize.sneaker_lookup_key(). Used to collapse retailer-specific name variants onto a single sneaker row. Display name lives in `name`. See sneaker_scout-ery.';
```

- [ ] **Step 2: Apply the migration to the live Supabase project**

This project does not have automated migration tooling wired up. Apply the migration manually via the Supabase dashboard SQL editor:

1. Open https://supabase.com/dashboard/project/ltjxebklcstqnddspoxr/sql/new
2. Paste the SQL from Step 1
3. Run it
4. Verify the column exists: `SELECT column_name, data_type, column_default FROM information_schema.columns WHERE table_name = 'sneakers' AND column_name = 'lookup_key';` — should return one row with `text` / `''::text`.

Note: If the dashboard isn't accessible, the SQL can also be run via the Supabase CLI (`supabase db push`) IF the CLI is logged in and linked to this project. The dashboard route is more reliable for this workflow.

- [ ] **Step 3: Commit the migration file in the aussie-kicks-tracker repo**

```bash
cd /workspace/aussie-kicks-tracker
git add supabase/migrations/20260511120000-ery-add-sneakers-lookup-key.sql
git commit -m "feat(sneaker_scout-ery): add sneakers.lookup_key column"
```

---

## Task 2: Add `sneaker_lookup_key` via TDD

**Files:**
- Modify: `sneaker-scout-backend/data_upload/canonicalize.py`
- Modify: `sneaker-scout-backend/tests/test_canonicalize.py`

This task bundles six TDD sub-cycles, one per behaviour, all on the same new function. Commits are intentionally granular for review but can be squashed at issue-close time per the project's per-issue commit protocol.

### Sub-cycle 2.1 — empty stub + first test

- [ ] **Step 1: Add a stub to `data_upload/canonicalize.py`**

Add at the bottom of the file, after `canonicalize_brand`:

```python
def sneaker_lookup_key(scraped_name: str, canonical_brand: str) -> str:
    """Return the normalized lookup key for a sneaker name.

    Used at ingest time to collapse retailer-specific spellings of the
    same shoe onto a single row in `sneakers`. The key is intended for
    matching only — the display name stays as the scraper produced it
    (first-write-wins policy lives in update_supabase_daily.py).

    `canonical_brand` is the output of `canonicalize_brand()` for the
    item being ingested; we strip it from the front of the name so
    'Salomon XT-6' (Hype DC) and 'XT-6' (Salomon direct) hash to the
    same key under brand_id=Salomon.
    """
    raise NotImplementedError
```

- [ ] **Step 2: Add first test to `tests/test_canonicalize.py`**

Append (preserving the existing top-of-file import block):

```python
def test_sneaker_lookup_key_is_importable():
    from data_upload.canonicalize import sneaker_lookup_key
    assert callable(sneaker_lookup_key)
```

- [ ] **Step 3: Run pytest from `sneaker-scout-backend/`**

```bash
cd /workspace/sneaker-scout-backend
pytest tests/test_canonicalize.py -v
```

Expected: 12 tests pass (11 existing + 1 new smoke).

- [ ] **Step 4: Commit**

```bash
git -C /workspace/sneaker-scout-backend add data_upload/canonicalize.py tests/test_canonicalize.py
git -C /workspace/sneaker-scout-backend commit -m "chore(sneaker_scout-ery): scaffold sneaker_lookup_key stub"
```

### Sub-cycle 2.2 — bare lowercase + non-alphanumeric strip

- [ ] **Step 1: Add failing tests**

Append to `tests/test_canonicalize.py`:

```python
def test_sneaker_lookup_key_lowercases_and_strips_punctuation():
    # No brand prefix to strip; just exercises the lower + alnum-only filter.
    assert sneaker_lookup_key("XT-6 GORE-TEX", "Salomon") == "xt6goretex"
    assert sneaker_lookup_key("Air Force 1 '07", "Nike") == "airforce107"
    assert sneaker_lookup_key("Old Skool Black", "Vans") == "oldskoolblack"
```

Also add the import to the top of the test file alongside `canonicalize_brand`:

```python
from data_upload.canonicalize import canonicalize_brand, sneaker_lookup_key
```

Remove the in-function `from data_upload.canonicalize import sneaker_lookup_key` line from `test_sneaker_lookup_key_is_importable` and have it just use the top-level import:

```python
def test_sneaker_lookup_key_is_importable():
    assert callable(sneaker_lookup_key)
```

- [ ] **Step 2: Run pytest, verify it fails**

```bash
pytest tests/test_canonicalize.py::test_sneaker_lookup_key_lowercases_and_strips_punctuation -v
```

Expected: FAIL with `NotImplementedError`.

- [ ] **Step 3: Replace the stub body**

Edit `data_upload/canonicalize.py` so `sneaker_lookup_key` becomes:

```python
def sneaker_lookup_key(scraped_name: str, canonical_brand: str) -> str:
    """[keep the existing docstring]"""
    s = scraped_name.lower()
    s = re.sub(r"[^a-z0-9]", "", s)
    return s
```

- [ ] **Step 4: Run pytest, verify green**

```bash
pytest tests/test_canonicalize.py -v
```

Expected: 13 tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /workspace/sneaker-scout-backend add data_upload/canonicalize.py tests/test_canonicalize.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-ery): lowercase + strip non-alphanumerics"
```

### Sub-cycle 2.3 — strip leading canonical brand prefix

- [ ] **Step 1: Add failing tests**

Append:

```python
def test_sneaker_lookup_key_strips_canonical_brand_prefix():
    # Hype DC writes 'Salomon XT-6' where salomon.com.au writes 'XT-6'.
    # Both must hash to the same key when brand is 'Salomon'.
    assert sneaker_lookup_key("Salomon XT-6", "Salomon") == "xt6"
    assert sneaker_lookup_key("XT-6", "Salomon") == "xt6"
    assert sneaker_lookup_key("Salomon XT-6 Gore-Tex", "Salomon") == "xt6goretex"
    assert sneaker_lookup_key("Nike Air Max 90", "Nike") == "airmax90"
    assert sneaker_lookup_key("Air Max 90", "Nike") == "airmax90"
    # Case-insensitive prefix detection
    assert sneaker_lookup_key("salomon XT-6", "Salomon") == "xt6"
    assert sneaker_lookup_key("SALOMON XT-6", "Salomon") == "xt6"
    # adidas is lowercase as a canonical brand — must still strip
    assert sneaker_lookup_key("adidas Stadt", "adidas") == "stadt"


def test_sneaker_lookup_key_does_not_strip_brand_substring():
    # 'Salomon' must only be stripped at the start; a model that
    # legitimately contains the brand name elsewhere is left alone.
    assert sneaker_lookup_key("Pro Salomon", "Salomon") == "prosalomon"
    # And a model that just happens to start with the same letters
    # but isn't the brand prefix shouldn't be stripped.
    assert sneaker_lookup_key("Salomonster", "Salomon") == "salomonster"
```

- [ ] **Step 2: Run pytest, verify failure**

```bash
pytest tests/test_canonicalize.py::test_sneaker_lookup_key_strips_canonical_brand_prefix -v
```

Expected: FAIL — current implementation doesn't strip brand.

- [ ] **Step 3: Update `sneaker_lookup_key`**

```python
def sneaker_lookup_key(scraped_name: str, canonical_brand: str) -> str:
    """[keep existing docstring]"""
    s = scraped_name
    # Strip leading canonical brand if the next character is whitespace
    # (so 'Salomonster' is not mangled into 'ter').
    prefix = canonical_brand + " "
    if s.lower().startswith(prefix.lower()):
        s = s[len(prefix):]
    s = s.lower()
    s = re.sub(r"[^a-z0-9]", "", s)
    return s
```

- [ ] **Step 4: Run pytest**

```bash
pytest tests/test_canonicalize.py -v
```

Expected: all green (15 tests).

- [ ] **Step 5: Commit**

```bash
git -C /workspace/sneaker-scout-backend add data_upload/canonicalize.py tests/test_canonicalize.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-ery): strip leading canonical brand prefix"
```

### Sub-cycle 2.4 — strip leading "Mens" / "Womens" qualifier

- [ ] **Step 1: Add failing tests**

Append:

```python
def test_sneaker_lookup_key_strips_mens_qualifier():
    # Platypus prepends 'Mens' to a lot of its sneaker names.
    # 'Nike Mens Dunk Low Retro' and 'Nike Dunk Low Retro' must collapse.
    assert sneaker_lookup_key("Nike Mens Dunk Low Retro", "Nike") == "dunklowretro"
    assert sneaker_lookup_key("Nike Dunk Low Retro", "Nike") == "dunklowretro"
    assert sneaker_lookup_key("Nike Mens P-6000", "Nike") == "p6000"
    assert sneaker_lookup_key("Reebok Mens Finale", "Reebok") == "finale"
    # 'Womens' and 'Men's' / 'Women's' variants
    assert sneaker_lookup_key("Nike Womens Air Force 1", "Nike") == "airforce1"
    assert sneaker_lookup_key("Nike Men's Dunk", "Nike") == "dunk"
    assert sneaker_lookup_key("Nike Women's Dunk", "Nike") == "dunk"


def test_sneaker_lookup_key_does_not_strip_mens_substring():
    # 'Mens' only stripped at the very start of the post-brand string.
    # Hypothetical model that contains 'mens' as part of a word.
    assert sneaker_lookup_key("Mens Club", "Nike") == "club"  # leading: strip
    assert sneaker_lookup_key("Statementsneaker", "Nike") == "statementsneaker"  # 'mens' inside, do not strip
```

- [ ] **Step 2: Run pytest, verify failure**

- [ ] **Step 3: Update `sneaker_lookup_key`**

```python
def sneaker_lookup_key(scraped_name: str, canonical_brand: str) -> str:
    """[keep existing docstring]"""
    s = scraped_name
    prefix = canonical_brand + " "
    if s.lower().startswith(prefix.lower()):
        s = s[len(prefix):]
    # Strip leading gender qualifier (Mens / Men's / Womens / Women's)
    s = re.sub(r"^(men'?s|women'?s)\s+", "", s, flags=re.IGNORECASE)
    s = s.lower()
    s = re.sub(r"[^a-z0-9]", "", s)
    return s
```

- [ ] **Step 4: Run pytest** — expect green.

- [ ] **Step 5: Commit**

```bash
git -C /workspace/sneaker-scout-backend add data_upload/canonicalize.py tests/test_canonicalize.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-ery): strip leading Mens/Womens qualifier"
```

### Sub-cycle 2.5 — empty / whitespace input

- [ ] **Step 1: Add failing tests**

Append:

```python
def test_sneaker_lookup_key_rejects_empty_input():
    with pytest.raises(ValueError):
        sneaker_lookup_key("", "Salomon")
    with pytest.raises(ValueError):
        sneaker_lookup_key("   ", "Salomon")


def test_sneaker_lookup_key_rejects_brand_only_input():
    # A scraped name that is JUST the brand string normalizes to an
    # empty key — that's data corruption and should fail loudly rather
    # than silently insert an empty-keyed row.
    with pytest.raises(ValueError):
        sneaker_lookup_key("Salomon", "Salomon")
    with pytest.raises(ValueError):
        sneaker_lookup_key("Nike Mens", "Nike")  # brand + qualifier with no model


def test_sneaker_lookup_key_requires_brand():
    # Caller is expected to pass canonical brand from canonicalize_brand().
    # Missing brand is a programmer error, not data corruption.
    with pytest.raises(ValueError):
        sneaker_lookup_key("XT-6", "")
```

- [ ] **Step 2: Run pytest, verify failure**

- [ ] **Step 3: Update `sneaker_lookup_key`**

```python
def sneaker_lookup_key(scraped_name: str, canonical_brand: str) -> str:
    """[keep existing docstring]

    Raises ValueError on empty input, empty brand, or names that
    normalize to an empty key (e.g. the scraped name is just the
    brand string with no model).
    """
    if not canonical_brand or not canonical_brand.strip():
        raise ValueError("canonical_brand is required")
    if not scraped_name or not scraped_name.strip():
        raise ValueError("scraped_name is empty or whitespace-only")
    s = scraped_name.strip()
    prefix = canonical_brand + " "
    if s.lower().startswith(prefix.lower()):
        s = s[len(prefix):]
    s = re.sub(r"^(men'?s|women'?s)\s+", "", s, flags=re.IGNORECASE)
    s = s.lower()
    s = re.sub(r"[^a-z0-9]", "", s)
    if not s:
        raise ValueError(
            f"sneaker_lookup_key produced empty key for "
            f"name={scraped_name!r}, brand={canonical_brand!r}"
        )
    return s
```

- [ ] **Step 4: Run pytest** — expect green.

- [ ] **Step 5: Commit**

```bash
git -C /workspace/sneaker-scout-backend add data_upload/canonicalize.py tests/test_canonicalize.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-ery): reject empty / brand-only / no-brand inputs"
```

### Sub-cycle 2.6 — fixture test against real scraped JSON

- [ ] **Step 1: Add the fixture test**

Append to `tests/test_canonicalize.py`:

```python
def test_sneaker_lookup_key_collapses_known_production_duplicates():
    # Production DB today has these three duplicate sneaker clusters
    # (documented in sneaker_scout-z1t). sneaker_lookup_key must collapse
    # each cluster's pair onto a single key.
    pairs = [
        # (raw_a, brand_a), (raw_b, brand_b) — both should hash equal
        (("XT-6", "Salomon"), ("Salomon XT-6", "Salomon")),
        (("XT-6 GORE-TEX", "Salomon"), ("Salomon XT-6 Gore-Tex", "Salomon")),
        (("Nike Air Force 1'07", "Nike"), ("Nike Mens Air Force 1 '07", "Nike")),
    ]
    for (raw_a, brand_a), (raw_b, brand_b) in pairs:
        key_a = sneaker_lookup_key(raw_a, brand_a)
        key_b = sneaker_lookup_key(raw_b, brand_b)
        assert key_a == key_b, (
            f"duplicate cluster did not collapse: "
            f"{raw_a!r} -> {key_a!r}, {raw_b!r} -> {key_b!r}"
        )


def test_sneaker_lookup_key_does_not_collide_across_shoes():
    # Independent shoes that share words should NOT collide.
    assert sneaker_lookup_key("XT-6", "Salomon") != sneaker_lookup_key(
        "XT-6 GORE-TEX", "Salomon"
    )
    assert sneaker_lookup_key("Air Force 1", "Nike") != sneaker_lookup_key(
        "Air Max 1", "Nike"
    )
    assert sneaker_lookup_key("Dunk Low", "Nike") != sneaker_lookup_key(
        "Dunk High", "Nike"
    )


def test_sneaker_lookup_key_against_real_scraped_brands():
    # Sanity-check that every (brand, sneaker name) pair currently
    # present in jsons/*_products.json produces a non-empty key without
    # raising. Caller is expected to pre-canonicalize the brand via
    # canonicalize_brand() before calling sneaker_lookup_key.
    jsons_dir = pathlib.Path(__file__).resolve().parent.parent / "jsons"
    if not jsons_dir.is_dir():
        return
    for path in jsons_dir.glob("*_products.json"):
        items = json.load(path.open())
        for item in items:
            raw_brand = item.get("brand", {}).get("name")
            raw_name = item.get("sneaker", {}).get("name")
            if not raw_brand or not raw_name:
                continue
            canonical_brand = canonicalize_brand(raw_brand)
            key = sneaker_lookup_key(raw_name, canonical_brand)
            assert key, f"empty key from {raw_name!r} / {canonical_brand!r}"
```

- [ ] **Step 2: Run pytest**

```bash
pytest tests/test_canonicalize.py -v
```

If any of the three production-duplicate pairs FAIL to collapse, the normalizer is incomplete — adjust the regex/strip logic until they collapse. Do not loosen the test.

If the JSON sanity-check fails on a particular (raw_brand, raw_name), check whether that input is legitimately producing an empty key (data corruption — fix the scraper, file a separate issue) or whether the normalizer is too aggressive.

- [ ] **Step 3: Commit**

```bash
git -C /workspace/sneaker-scout-backend add tests/test_canonicalize.py
git -C /workspace/sneaker-scout-backend commit -m "test(sneaker_scout-ery): lock sneaker_lookup_key against production duplicates"
```

---

## Task 3: Backfill script for existing rows

**Files:**
- Create: `sneaker-scout-backend/data_upload/backfill_lookup_keys.py`

The migration in Task 1 created the column with default `''`. This task populates it for every existing sneaker row.

- [ ] **Step 1: Create the backfill script**

```python
"""Backfill sneakers.lookup_key for rows that already exist in production.

Run once, after the schema migration in
aussie-kicks-tracker/supabase/migrations/20260511120000-ery-add-sneakers-lookup-key.sql
has been applied. Idempotent — re-running rewrites the same keys.

Usage (from sneaker-scout-backend/):
    python -m data_upload.backfill_lookup_keys

Requires SUPABASE_URL and SUPABASE_SERVICE_KEY in the project .env.
"""
from __future__ import annotations

import logging
import os
import sys

from dotenv import load_dotenv
from supabase import create_client

from .canonicalize import canonicalize_brand, sneaker_lookup_key

load_dotenv()

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
logger = logging.getLogger("backfill_lookup_keys")


def main() -> int:
    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_KEY")
    if not url or not key:
        logger.error("SUPABASE_URL and SUPABASE_SERVICE_KEY must be set")
        return 1

    sb = create_client(url, key)

    # Pull every sneaker row plus its brand name. brand is embedded so
    # we don't need a second round trip per row.
    rows = sb.table("sneakers").select(
        "id, name, brand:brands(name)"
    ).execute().data
    logger.info("Loaded %d sneaker rows", len(rows))

    updated = 0
    skipped = 0
    for row in rows:
        raw_name = row.get("name")
        brand = row.get("brand") or {}
        raw_brand = brand.get("name")
        if not raw_name or not raw_brand:
            logger.warning(
                "Skipping row id=%s — missing name (%r) or brand (%r)",
                row.get("id"), raw_name, raw_brand
            )
            skipped += 1
            continue
        try:
            canonical_brand = canonicalize_brand(raw_brand)
            lookup_key = sneaker_lookup_key(raw_name, canonical_brand)
        except ValueError as exc:
            logger.warning(
                "Skipping row id=%s — normalize failed: %s",
                row.get("id"), exc
            )
            skipped += 1
            continue

        sb.table("sneakers").update({"lookup_key": lookup_key}).eq(
            "id", row["id"]
        ).execute()
        updated += 1
        logger.info(
            "Updated id=%s: name=%r brand=%r -> lookup_key=%r",
            row["id"], raw_name, raw_brand, lookup_key
        )

    logger.info("Done. Updated=%d Skipped=%d", updated, skipped)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Run the backfill (after Task 1's migration is applied)**

```bash
cd /workspace/sneaker-scout-backend
python -m data_upload.backfill_lookup_keys
```

Expected output: ~33 "Updated id=…" lines, "Done. Updated=33 Skipped=0" (or close — production sneaker count as of 2026-05-11).

Verify in the dashboard or via Python:

```python
sb.table("sneakers").select("name, lookup_key, brand:brands(name)").execute().data
```

Spot-check: `XT-6` and `Salomon XT-6` should now share `lookup_key='xt6'`. `Nike Air Force 1'07` and `Nike Mens Air Force 1 '07` should share `lookup_key='airforce107'`.

- [ ] **Step 3: Commit**

```bash
git -C /workspace/sneaker-scout-backend add data_upload/backfill_lookup_keys.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-ery): one-off backfill script for sneakers.lookup_key"
```

---

## Task 4: Wire `sneaker_lookup_key` into the upsert

**Files:**
- Modify: `sneaker-scout-backend/data_upload/update_supabase_daily.py` (lines ~168-200, the sneaker-upsert block)
- Modify: `sneaker-scout-backend/tests/test_canonicalize.py` (one new test)

- [ ] **Step 1: Update the import**

The existing import line:

```python
from .canonicalize import canonicalize_brand
```

becomes:

```python
from .canonicalize import canonicalize_brand, sneaker_lookup_key
```

- [ ] **Step 2: Replace the sneaker-upsert block**

Find this block in `data_upload/update_supabase_daily.py` (around line 168-200):

```python
            # 2. Check if sneaker exists by name and brand_id
            sneaker_data = item["sneaker"]
            sneaker_response = supabase.table("sneakers").select("id").eq("name", sneaker_data["name"]).eq("brand_id", brand_id).execute()

            if not sneaker_response.data:
                # Insert new sneaker
                sneaker_response = supabase.table("sneakers").insert({
                    "name": sneaker_data["name"],
                    "brand_id": brand_id,
                    "model": sneaker_data["model"],
                    "release_date": sneaker_data["release_date"],
                    "description": sneaker_data["description"]
                }).execute()
                logger.info(f"Inserted sneaker: {sneaker_data['name']}")
            else:
                # Update existing sneaker
                sneaker_id = sneaker_response.data[0]["id"]
                supabase.table("sneakers").update({
                    "model": sneaker_data["model"],
                    "release_date": sneaker_data["release_date"],
                    "description": sneaker_data["description"],
                    "updated_at": datetime.now().isoformat()
                }).eq("id", sneaker_id).execute()
                logger.info(f"Updated sneaker: {sneaker_data['name']}")

            sneaker_id = sneaker_response.data[0]["id"]
```

Replace it with:

```python
            # 2. Check if sneaker exists by (brand_id, lookup_key).
            # lookup_key collapses retailer-specific name variants
            # ('XT-6' / 'Salomon XT-6' / 'Nike Mens Air Force 1 \'07')
            # onto a single row. Display name is first-write-wins:
            # we never overwrite the existing `name` on match — only
            # model / release_date / description are refreshed.
            # See sneaker_scout-ery.
            sneaker_data = item["sneaker"]
            lookup_key = sneaker_lookup_key(sneaker_data["name"], brand_name)
            sneaker_response = supabase.table("sneakers").select("id, name").eq(
                "lookup_key", lookup_key
            ).eq("brand_id", brand_id).execute()

            if not sneaker_response.data:
                # Insert new sneaker
                sneaker_response = supabase.table("sneakers").insert({
                    "name": sneaker_data["name"],
                    "brand_id": brand_id,
                    "lookup_key": lookup_key,
                    "model": sneaker_data["model"],
                    "release_date": sneaker_data["release_date"],
                    "description": sneaker_data["description"]
                }).execute()
                logger.info(
                    f"Inserted sneaker: {sneaker_data['name']!r} "
                    f"(lookup_key={lookup_key!r})"
                )
            else:
                # Existing row — first-write-wins on name.
                sneaker_id = sneaker_response.data[0]["id"]
                existing_name = sneaker_response.data[0]["name"]
                supabase.table("sneakers").update({
                    "model": sneaker_data["model"],
                    "release_date": sneaker_data["release_date"],
                    "description": sneaker_data["description"],
                    "updated_at": datetime.now().isoformat()
                }).eq("id", sneaker_id).execute()
                logger.info(
                    f"Matched sneaker: {sneaker_data['name']!r} -> existing "
                    f"row {existing_name!r} (lookup_key={lookup_key!r})"
                )

            sneaker_id = sneaker_response.data[0]["id"]
```

Key changes:
- Compute `lookup_key` from `sneaker_data["name"]` + `brand_name` (which Task 1oj already canonicalized in the preceding block).
- SELECT matches on `lookup_key`, not `name`.
- INSERT writes `lookup_key`.
- UPDATE block (the match branch) does NOT touch `name` — that's the first-write-wins policy.
- Log lines mention both the scraped name and the existing/matched name so duplicate-collapse events are visible in logs.

- [ ] **Step 3: Add a regression test that exercises the wiring**

Append to `tests/test_canonicalize.py`:

```python
def test_update_supabase_daily_imports_sneaker_lookup_key():
    # Belt-and-braces: if a refactor accidentally drops the import,
    # the integration silently regresses (just like the brand import).
    from data_upload import update_supabase_daily
    assert hasattr(update_supabase_daily, "sneaker_lookup_key")
```

- [ ] **Step 4: Run pytest**

```bash
cd /workspace/sneaker-scout-backend
pytest tests/test_canonicalize.py -v
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /workspace/sneaker-scout-backend add data_upload/update_supabase_daily.py tests/test_canonicalize.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-ery): match sneakers by lookup_key at upsert site"
```

---

## Task 5: Dry-run sanity check against the JSON snapshots

**Files:** none (read-only verification).

- [ ] **Step 1: Predict the post-normalization sneaker set**

Run from `sneaker-scout-backend/`:

```bash
python -c "
import json, pathlib
from data_upload.canonicalize import canonicalize_brand, sneaker_lookup_key

groups = {}
for p in pathlib.Path('jsons').glob('*_products.json'):
    for item in json.load(open(p)):
        raw_brand = item.get('brand', {}).get('name')
        raw_name = item.get('sneaker', {}).get('name')
        if not raw_brand or not raw_name:
            continue
        cb = canonicalize_brand(raw_brand)
        key = sneaker_lookup_key(raw_name, cb)
        groups.setdefault((cb, key), set()).add(raw_name)

for (brand, key), names in sorted(groups.items()):
    marker = '  ' if len(names) == 1 else '** '
    print(f'{marker}brand={brand!r:14} key={key!r:25} <- {sorted(names)}')
"
```

Expected: every cluster size is 1 (one raw name per (brand, key)) EXCEPT where the input JSONs legitimately contain duplicates (which is fine — the scrapers occasionally see the same product twice within one run). The clusters that lit up during z1t (`xt6`, `xt6goretex`, `airforce107`) should appear collapsed in the live DB after Task 3's backfill, not in the JSON snapshots themselves (the JSONs come from different scraper runs and might or might not contain the duplicate variants).

If you see `**` rows pointing at cross-retailer collapses (e.g. `brand='Salomon' key='xt6' <- ['Salomon XT-6', 'XT-6']`), that's the win.

- [ ] **Step 2: (Optional) Re-upload one JSON and confirm no new duplicate rows are inserted**

Optional end-to-end check. Run from `sneaker-scout-backend/`:

```bash
python -m data_upload.run_update --file=jsons/hypedc_products.json
```

Then in Python:

```python
import os
from dotenv import load_dotenv
from supabase import create_client
load_dotenv('/workspace/sneaker-scout-backend/.env')
sb = create_client(os.environ['SUPABASE_URL'], os.environ['SUPABASE_SERVICE_KEY'])

salomon_sneakers = sb.table("sneakers").select(
    "id, name, lookup_key, brand:brands!inner(name)"
).eq("brand.name", "Salomon").execute().data
for s in salomon_sneakers:
    print(s)
```

The Hype DC scraper produces both `Salomon XT-6` and `Salomon XT-6 Gore-Tex`. After re-uploading hypedc_products.json:
- Existing rows `XT-6` and `XT-6 GORE-TEX` (from the earlier salomon scraper run) should now have `lookup_key='xt6'` and `lookup_key='xt6goretex'` respectively.
- The Hype DC variants should match those existing rows (not create new sneaker rows) because their normalized keys match.
- Per first-write-wins, the `name` column stays as `XT-6` and `XT-6 GORE-TEX` (the originals from Salomon direct).
- Prices and colorways under those rows accumulate from both retailers.

If new sneaker rows DID get created for `Salomon XT-6` / `Salomon XT-6 Gore-Tex`, that's a bug — the wiring isn't matching by lookup_key correctly. Diagnose before declaring done.

- [ ] **Step 3: No commit** — this task is read-only verification.

---

## Task 6 (optional): Regenerate frontend Supabase types

**Files:**
- Modify: `aussie-kicks-tracker/src/integrations/supabase/types.ts`

The frontend doesn't read `lookup_key`, so a stale types.ts doesn't break anything functionally. But regenerating prevents drift. Skip this task if you don't have the Supabase CLI installed and authenticated for this project — it doesn't block `ery`.

- [ ] **Step 1: Regenerate types**

```bash
cd /workspace/aussie-kicks-tracker
npx supabase gen types typescript --linked > src/integrations/supabase/types.ts
```

Or, if the CLI isn't set up: open the Supabase dashboard → API Docs → generated types tab, copy the TypeScript output, paste into `types.ts`. The diff should add one field: `lookup_key: string` on the `sneakers` table's `Row`, `Insert`, and `Update` shapes.

- [ ] **Step 2: Run the frontend type-check / build**

```bash
cd /workspace/aussie-kicks-tracker
npm run lint
npm run build
```

Both should succeed. If `lookup_key` is now expected on sneaker inserts in code paths the frontend uses, those paths need updating — but the frontend doesn't currently insert sneaker rows (only the backend uploader does), so no app code should need to change.

- [ ] **Step 3: Commit (in aussie-kicks-tracker)**

```bash
cd /workspace/aussie-kicks-tracker
git add src/integrations/supabase/types.ts
git commit -m "chore(sneaker_scout-ery): regenerate supabase types for sneakers.lookup_key"
```

---

## Task 7: Close the issue and recap commit

**Files:** none (git + bd operations)

- [ ] **Step 1: Verify all tests pass**

```bash
cd /workspace/sneaker-scout-backend
pytest tests/test_canonicalize.py -v
```

Expected: all green.

- [ ] **Step 2: Confirm no uncommitted work in any of the three repos**

```bash
git -C /workspace/sneaker-scout-backend status --short
git -C /workspace/aussie-kicks-tracker status --short
git -C /workspace status --short
```

Any pre-existing dirty state (from before `ery` started) is fine. Only flag if there are ery-related files still uncommitted.

- [ ] **Step 3: Close the bd issue**

```bash
bd close sneaker_scout-ery --reason="Lookup-key column added to sneakers; sneaker_lookup_key(scraped_name, canonical_brand) normalizes via brand-prefix strip, Mens/Womens qualifier strip, lowercase, alnum-only filter. update_supabase_daily.py matches on lookup_key with first-write-wins display-name policy. Backfill applied to existing rows. UNIQUE(brand_id, lookup_key) deferred to xdl which must dedupe first."
```

- [ ] **Step 4: Stage the bd state and create the recap commit in /workspace**

```bash
cd /workspace
git add .beads/.bv.lock .beads/export-state.json .beads/interactions.jsonl .beads/issues.jsonl
git commit -m "$(cat <<'EOF'
feat(sneaker_scout-ery): normalize sneaker names at ingest

Different retailer scrapers were producing different sneaker strings
for the same shoe ('XT-6' vs 'Salomon XT-6'; 'Nike Air Force 1\'07'
vs 'Nike Mens Air Force 1 \'07') and update_supabase_daily.py was
upserting by exact-name match — production grew duplicate sneaker
rows that the frontend rendered as separate cards.

Added sneaker_lookup_key(scraped_name, canonical_brand) in
data_upload/canonicalize.py. It strips the canonical brand prefix
(uses the canonicalize_brand output from sneaker_scout-1oj), strips
'Mens'/'Womens'/"Men's"/"Women's" qualifiers, lowercases, and strips
non-alphanumerics. Raises ValueError on empty/brand-only/no-brand
inputs.

Schema change: sneakers.lookup_key text NOT NULL DEFAULT '' with a
non-unique index on (brand_id, lookup_key). Backfill script
(data_upload/backfill_lookup_keys.py) populates the column for the
~33 rows that already exist in production. The upsert path now
matches on (brand_id, lookup_key) and applies a first-write-wins
display-name policy — model/release_date/description still refresh
on every run, but `name` is preserved from the first ingest.

Three commits in sneaker-scout-backend cover this end-to-end. The
migration file lives in aussie-kicks-tracker (separate repo).

UNIQUE(brand_id, lookup_key) is deferred to sneaker_scout-xdl, which
must collapse the existing duplicate clusters before the constraint
can be added without conflict.

Closes: sneaker_scout-ery
EOF
)"
```

---

## Self-Review

**Spec coverage** — `sneaker_scout-ery` calls for:

| Requirement | Covered by |
|---|---|
| Strip leading brand prefix | Sub-cycle 2.3 |
| Strip "Mens" qualifier | Sub-cycle 2.4 |
| Normalize 'gore-tex'/'Gore-Tex'/'GORE-TEX' | Sub-cycle 2.2 (lower + alnum-strip collapses all three to `goretex`) |
| Casefold for matching | Sub-cycle 2.2 |
| Display vs lookup-key split | Task 1 (schema) + Task 4 (first-write-wins on name) |
| Depends on brand canonicalization landing first | Sub-cycle 2.3 imports `canonicalize_brand` indirectly via `brand_name` from the upsert site; tests pass a canonical brand explicitly |
| Production duplicates collapse correctly | Sub-cycle 2.6 fixture test pins all three clusters |

**Placeholder scan** — every code step includes the actual code. No "TBD" / "implement later" / "similar to Task N" patterns.

**Type consistency** — `sneaker_lookup_key(scraped_name: str, canonical_brand: str) -> str` is consistent across Sub-cycles 2.1–2.5, Sub-cycle 2.6's fixture test, Task 3's backfill, and Task 4's wiring. `lookup_key` (the variable) is consistently a `str`. The `BRAND_ALIASES` dict from `1oj` is referenced implicitly via `canonicalize_brand` but not directly extended.

**Things to flag at execution time:**

1. The schema migration in Task 1 cannot be applied automatically — the developer must paste the SQL into the Supabase dashboard. If the dashboard isn't accessible at execution time, the implementer should escalate as BLOCKED rather than proceed.

2. Task 3's backfill is destructive in the sense that it writes to every row in `sneakers`. The script is idempotent, but it's worth running once in a non-prod environment first if one exists (there isn't one in this project today).

3. The `lookup_key` column starts as NOT NULL DEFAULT ''. Until the backfill runs, every row has an empty key. The application code (Task 4) writes the real key on insert, but any existing row that's matched before the backfill would match on `lookup_key=''` — collapsing all unmatched-key rows onto each other. **Apply the migration and run the backfill before deploying the Task 4 wiring**, in that order, or the upsert will misbehave on the first run.

4. The fixture test in Sub-cycle 2.6 will fail if the JSON snapshots ever contain a sneaker whose name normalizes to an empty key. If that happens, fix the source scraper (file a separate issue) — don't loosen the assertion.
