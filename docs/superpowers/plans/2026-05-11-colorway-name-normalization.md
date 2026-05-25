# Colorway-name normalization at ingest — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Supabase ingest pipeline collapse retailer-specific colorway-name variants (`black/black/ftwsilver` vs `Black/Black/Ftwsilver` vs `BLACK/BLACK/FTWSILVER (000)`) onto a single `colorways` row under the same sneaker, mirroring the sneaker-axis fix from `sneaker_scout-ery`.

**Architecture:** Add a `lookup_key text` column to the `colorways` table; populate it via a deterministic Python normalizer (`colorway_lookup_key()` in `data_upload/canonicalize.py`) that strips trailing parens SKU codes (Platypus-style `(108)` references), lowercases, and strips all non-alphanumerics. Foot Locker `- BAT` / `- CASPER` nickname suffixes are preserved because they distinguish genuinely different colorways (Nike Tuned 1 BAT vs CASPER are different products). `update_supabase_daily.py`'s colorway-upsert site looks up by `(sneaker_id, lookup_key)` instead of by `(sneaker_id, name)`. **First-write-wins is extended to both `name` AND `image_url`** — when a match is found, the existing values are kept; today's last-write-wins image-update behaviour goes away as a side effect of this change. A one-off Python backfill computes `lookup_key` for the rows already in production. The unique constraint is deferred to `sneaker_scout-xdl` because existing duplicates would break it.

**Tech Stack:** Python 3.11+ (system pytest), Supabase Postgres, supabase-py client. No new runtime dependencies.

**Scope note:** This plan is scoped to the colorway axis only. The brand and sneaker axes are already done (`sneaker_scout-1oj` and `sneaker_scout-ery` respectively). Backfill-with-uniqueness is `sneaker_scout-xdl`.

**Depends on:** `sneaker_scout-ery` (✓ closed) — the colorway upsert now runs after the sneaker lookup has resolved `sneaker_id` via the lookup_key path. The sneaker-side first-write-wins policy means the resolved `sneaker_id` is stable across retailer ingests.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `aussie-kicks-tracker/supabase/migrations/20260511130000-s8z-add-colorways-lookup-key.sql` | Create | Schema migration: `ALTER TABLE colorways ADD COLUMN lookup_key text NOT NULL DEFAULT ''` + non-unique index on `(sneaker_id, lookup_key)`. NOT NULL with default lets the migration run before the backfill. |
| `sneaker-scout-backend/data_upload/canonicalize.py` | Modify | Add `colorway_lookup_key(scraped_colorway_name: str) -> str` alongside the existing `canonicalize_brand` and `sneaker_lookup_key`. ~20 new lines. |
| `sneaker-scout-backend/tests/test_canonicalize.py` | Modify | Add tests for `colorway_lookup_key`. ~70 new lines. |
| `sneaker-scout-backend/data_upload/backfill_lookup_keys.py` | Modify | Add a second pass that backfills `colorways.lookup_key`. The script becomes a two-pass tool (sneakers + colorways). |
| `sneaker-scout-backend/data_upload/update_supabase_daily.py` | Modify | Replace the colorway-upsert block (~lines 200-230) so the lookup uses `lookup_key` and inserts populate it. Apply first-write-wins to `name` and `image_url`. |
| `aussie-kicks-tracker/src/integrations/supabase/types.ts` | Regenerate (optional, recommended) | Pick up the new column. Frontend doesn't read `lookup_key` so a stale types.ts won't break the UI but regenerating prevents drift. |

---

## Repository layout reminder

Three independent git repos (same as `ery`):
- `/workspace` — top-level, contains `.beads/` and the plan docs. **Beads commits land here.**
- `/workspace/sneaker-scout-backend/` — Python uploader + tests. **Implementation commits land here.**
- `/workspace/aussie-kicks-tracker/` — Supabase migrations + frontend types. **Migration commit lands here.**

Use `git -C <path>` to operate on a specific repo. NEVER `git add -A` / `.` / `commit -am`. The backend repo has pre-existing dirty state on `data_upload/update_supabase_daily.py` (a colorway field-name compat fix unrelated to s8z) — the controller will stash it before Task 4 dispatches.

---

## Task 1: Schema migration

**Files:**
- Create: `aussie-kicks-tracker/supabase/migrations/20260511130000-s8z-add-colorways-lookup-key.sql`

- [ ] **Step 1: Create the migration file**

```sql
-- sneaker_scout-s8z: add lookup_key column for colorway-name normalization.
--
-- The Python ingest (data_upload/update_supabase_daily.py) computes
-- colorway_lookup_key(scraped_colorway_name) and uses it to match the
-- same colorway across retailers under a given sneaker_id (e.g.
-- 'black/black/ftwsilver' from salomon.com.au and 'Black/Black/Ftwsilver'
-- from Hype DC both hash to 'blackblackftwsilver'). lookup_key is
-- written on insert and used for the upsert SELECT.
--
-- Constraint deferred to sneaker_scout-xdl: a UNIQUE(sneaker_id,
-- lookup_key) index would fail today because production already has
-- duplicate colorway rows that share a lookup_key once normalized.
-- xdl deduplicates first, then adds the unique constraint.

ALTER TABLE public.colorways
  ADD COLUMN lookup_key text NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS colorways_sneaker_lookup_key_idx
  ON public.colorways (sneaker_id, lookup_key);

COMMENT ON COLUMN public.colorways.lookup_key IS
  'Normalized lookup key computed at ingest time by data_upload.canonicalize.colorway_lookup_key(). Used to collapse retailer-specific name variants onto a single colorway row per sneaker. Display name lives in `name`. See sneaker_scout-s8z.';
```

- [ ] **Step 2: Controller-only — apply to live Supabase**

The implementer for this task creates the file but does NOT apply the migration. The controller applies the SQL via the Supabase dashboard (https://supabase.com/dashboard/project/ltjxebklcstqnddspoxr/sql/new) before dispatching Task 3 (the backfill).

- [ ] **Step 3: Commit in aussie-kicks-tracker**

```bash
git -C /workspace/aussie-kicks-tracker add supabase/migrations/20260511130000-s8z-add-colorways-lookup-key.sql
git -C /workspace/aussie-kicks-tracker commit -m "feat(sneaker_scout-s8z): add colorways.lookup_key column"
```

`git -C /workspace/aussie-kicks-tracker status --short` should show only the pre-existing dirty state from prior work; the commit must contain exactly the one migration file.

---

## Task 2: Add `colorway_lookup_key` via TDD

**Files:**
- Modify: `sneaker-scout-backend/data_upload/canonicalize.py`
- Modify: `sneaker-scout-backend/tests/test_canonicalize.py`

This task bundles four TDD sub-cycles on the same new function.

### Sub-cycle 2.1 — stub + smoke test

- [ ] **Step 1: Append the stub to `data_upload/canonicalize.py`**

```python
def colorway_lookup_key(scraped_colorway_name: str) -> str:
    """Return the normalized lookup key for a colorway name.

    Used at ingest time to collapse retailer-specific spellings of the
    same colorway under a given sneaker_id onto one `colorways` row.
    The key is intended for matching only — the display name stays as
    the scraper produced it (first-write-wins policy lives in
    update_supabase_daily.py).

    Strips trailing Platypus-style parens SKU codes (e.g. `(108)`),
    lowercases, and strips non-alphanumerics. Foot Locker nickname
    suffixes (e.g. ` - BAT`, ` - CASPER`) are preserved because they
    distinguish genuinely different colorways (Nike Tuned 1 BAT vs
    CASPER are different products).

    Raises ValueError on empty input or names that normalize to an
    empty key.
    """
    raise NotImplementedError
```

- [ ] **Step 2: Update the test file's top import line**

Find:
```python
from data_upload.canonicalize import canonicalize_brand, sneaker_lookup_key
```

Replace with:
```python
from data_upload.canonicalize import (
    canonicalize_brand,
    colorway_lookup_key,
    sneaker_lookup_key,
)
```

- [ ] **Step 3: Append smoke test**

```python
def test_colorway_lookup_key_is_importable():
    assert callable(colorway_lookup_key)
```

- [ ] **Step 4: Run pytest**

```bash
cd /workspace/sneaker-scout-backend
pytest tests/test_canonicalize.py -v
```

Expect 25 tests pass (24 existing + 1 new smoke).

- [ ] **Step 5: Commit**

```bash
git -C /workspace/sneaker-scout-backend add data_upload/canonicalize.py tests/test_canonicalize.py
git -C /workspace/sneaker-scout-backend commit -m "chore(sneaker_scout-s8z): scaffold colorway_lookup_key stub"
```

### Sub-cycle 2.2 — lowercase + strip non-alphanumerics

- [ ] **Step 1: Add failing tests**

```python
def test_colorway_lookup_key_lowercases_and_strips_punctuation():
    # Variants across the four retailer formats with no metadata suffix.
    assert colorway_lookup_key("black/black/ftwsilver") == "blackblackftwsilver"
    assert colorway_lookup_key("Black/Black/Ftwsilver") == "blackblackftwsilver"
    assert colorway_lookup_key("BLACK/BLACK/FTWSILVER") == "blackblackftwsilver"
    assert colorway_lookup_key("Core Black/Core Black/Gum") == "coreblackcoreblackgum"
    assert colorway_lookup_key("Black-Black-Black") == "blackblackblack"


def test_colorway_lookup_key_collapses_separator_variants():
    # Slash, dash, and space-separated variants of the same color sequence
    # all collapse to the same key.
    a = colorway_lookup_key("Black/Black/Black")
    b = colorway_lookup_key("Black-Black-Black")
    c = colorway_lookup_key("Black Black Black")
    assert a == b == c == "blackblackblack"
```

- [ ] **Step 2: Run, verify red**

```bash
pytest tests/test_canonicalize.py::test_colorway_lookup_key_lowercases_and_strips_punctuation -v
```

- [ ] **Step 3: Replace the stub body**

```python
def colorway_lookup_key(scraped_colorway_name: str) -> str:
    """[keep existing docstring]"""
    s = scraped_colorway_name.lower()
    s = re.sub(r"[^a-z0-9]", "", s)
    return s
```

- [ ] **Step 4: Run, verify green**

```bash
pytest tests/test_canonicalize.py -v
```

- [ ] **Step 5: Commit**

```bash
git -C /workspace/sneaker-scout-backend add data_upload/canonicalize.py tests/test_canonicalize.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-s8z): lowercase + strip non-alphanumerics"
```

### Sub-cycle 2.3 — strip trailing parens SKU codes

- [ ] **Step 1: Add failing tests**

```python
def test_colorway_lookup_key_strips_trailing_parens_code():
    # Platypus SKU codes — must collapse with no-code variants.
    assert colorway_lookup_key("BLACK (000)") == "black"
    assert colorway_lookup_key("SEA SALT (108)") == "seasalt"
    assert colorway_lookup_key("GREY (020)") == "grey"
    assert colorway_lookup_key("RAINCLOUD (161)") == "raincloud"
    # With whitespace around the parens
    assert colorway_lookup_key("BLACK  (000) ") == "black"
    # Cross-retailer match: Platypus-with-code vs bare
    assert (
        colorway_lookup_key("BLACK/BLACK/FTWSILVER (000)")
        == colorway_lookup_key("Black/Black/Ftwsilver")
    )


def test_colorway_lookup_key_only_strips_trailing_parens():
    # A parens group mid-string is NOT stripped — only one at the end.
    # (Defensive guard; no current retailer produces this pattern, but
    # we want to be sure the regex is anchored.)
    assert colorway_lookup_key("Black (limited) Edition") == "blacklimitededition"
```

- [ ] **Step 2: Run, verify red**

- [ ] **Step 3: Update the function**

```python
def colorway_lookup_key(scraped_colorway_name: str) -> str:
    """[keep existing docstring]"""
    # Strip trailing parens SKU codes (Platypus style: 'BLACK (000)').
    # Anchored to end-of-string so mid-string parens are preserved.
    s = re.sub(r"\s*\([^)]*\)\s*$", "", scraped_colorway_name)
    s = s.lower()
    s = re.sub(r"[^a-z0-9]", "", s)
    return s
```

- [ ] **Step 4: Run, verify green**

- [ ] **Step 5: Commit**

```bash
git -C /workspace/sneaker-scout-backend add data_upload/canonicalize.py tests/test_canonicalize.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-s8z): strip trailing parens SKU codes"
```

### Sub-cycle 2.4 — preserve Foot Locker nicknames

- [ ] **Step 1: Add failing tests**

```python
def test_colorway_lookup_key_preserves_foot_locker_nicknames():
    # Nicknames distinguish DIFFERENT colorways under the same sneaker.
    # Nike Tuned 1 'BAT' and 'CASPER' must NOT collapse.
    bat = colorway_lookup_key("Black-Black-Black - BAT")
    casper = colorway_lookup_key("White-Grey-White - CASPER")
    assert bat != casper
    assert bat == "blackblackblackbat"
    assert casper == "whitegreywhitecasper"


def test_colorway_lookup_key_handles_apostrophes_in_nicknames():
    # Foot Locker sometimes wraps the nickname in quotes:
    # "White-Grey-White - 'CASPER'"
    assert (
        colorway_lookup_key("White-Grey-White - 'CASPER'")
        == colorway_lookup_key("White-Grey-White - CASPER")
    )
```

- [ ] **Step 2: Run pytest**

```bash
pytest tests/test_canonicalize.py -v
```

These tests should already pass with the existing implementation — the alphanumeric-only filter naturally preserves nickname words and drops the surrounding punctuation. No code change required; the tests lock in the behaviour so a future regex tweak can't silently strip nicknames.

If they unexpectedly fail, do not loosen the test — investigate.

- [ ] **Step 3: Commit (test-only, no code change)**

```bash
git -C /workspace/sneaker-scout-backend add tests/test_canonicalize.py
git -C /workspace/sneaker-scout-backend commit -m "test(sneaker_scout-s8z): lock that Foot Locker nicknames are preserved"
```

### Sub-cycle 2.5 — empty / whitespace input

- [ ] **Step 1: Add failing tests**

```python
def test_colorway_lookup_key_rejects_empty_input():
    with pytest.raises(ValueError):
        colorway_lookup_key("")
    with pytest.raises(ValueError):
        colorway_lookup_key("   ")


def test_colorway_lookup_key_rejects_punctuation_only_input():
    # A colorway string that's just punctuation (or just a parens code)
    # normalizes to empty — fail loudly rather than insert an empty key.
    with pytest.raises(ValueError):
        colorway_lookup_key("///")
    with pytest.raises(ValueError):
        colorway_lookup_key("(000)")
    with pytest.raises(ValueError):
        colorway_lookup_key(" - ")
```

- [ ] **Step 2: Run, verify red**

- [ ] **Step 3: Update the function**

```python
def colorway_lookup_key(scraped_colorway_name: str) -> str:
    """Return the normalized lookup key for a colorway name.

    [... keep the existing paragraphs ...]

    Raises ValueError on empty input or names that normalize to an
    empty key (e.g. punctuation-only or parens-only inputs).
    """
    if not scraped_colorway_name or not scraped_colorway_name.strip():
        raise ValueError("scraped_colorway_name is empty or whitespace-only")
    s = re.sub(r"\s*\([^)]*\)\s*$", "", scraped_colorway_name)
    s = s.lower()
    s = re.sub(r"[^a-z0-9]", "", s)
    if not s:
        raise ValueError(
            f"colorway_lookup_key produced empty key for {scraped_colorway_name!r}"
        )
    return s
```

- [ ] **Step 4: Run pytest** — expect green.

- [ ] **Step 5: Commit**

```bash
git -C /workspace/sneaker-scout-backend add data_upload/canonicalize.py tests/test_canonicalize.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-s8z): reject empty / punctuation-only inputs"
```

### Sub-cycle 2.6 — fixture test against real scraped JSON

- [ ] **Step 1: Append the fixture test**

```python
def test_colorway_lookup_key_against_real_scraped_colorways():
    # Sanity-check that every colorway string currently produced by the
    # four retailer scrapers normalizes to a non-empty key without raising.
    jsons_dir = pathlib.Path(__file__).resolve().parent.parent / "jsons"
    if not jsons_dir.is_dir():
        return
    for path in jsons_dir.glob("*_products.json"):
        items = json.load(path.open())
        for item in items:
            raw = item.get("colorway", {}).get("name") or item.get(
                "colorway", {}
            ).get("colorway_name")
            if not raw:
                continue
            key = colorway_lookup_key(raw)
            assert key, f"empty key from {raw!r} in {path.name}"
```

(The `colorway_name` fallback covers the pre-canonical JSON format that some older `jsons/*.json` files still use.)

- [ ] **Step 2: Run pytest**

```bash
pytest tests/test_canonicalize.py -v
```

If any colorway string produces an empty key or raises, investigate the source data (likely a malformed scrape) and either fix the scraper or strengthen the normalizer. Do not loosen the test.

- [ ] **Step 3: Commit**

```bash
git -C /workspace/sneaker-scout-backend add tests/test_canonicalize.py
git -C /workspace/sneaker-scout-backend commit -m "test(sneaker_scout-s8z): lock colorway_lookup_key against real scraped data"
```

---

## Task 3: Extend backfill script to populate `colorways.lookup_key`

**Files:**
- Modify: `sneaker-scout-backend/data_upload/backfill_lookup_keys.py`

The existing backfill script handles sneakers only. Extend it to a two-pass tool.

- [ ] **Step 1: Refactor `main()` into per-table passes**

Replace the existing `main()` body with this structure (keeping the imports and `load_dotenv()` block at the top of the file):

```python
def _backfill_sneakers(sb) -> tuple[int, int]:
    """Backfill sneakers.lookup_key. Returns (updated, skipped)."""
    rows = sb.table("sneakers").select(
        "id, name, brand:brands(name)"
    ).execute().data
    logger.info("sneakers: loaded %d rows", len(rows))

    updated = 0
    skipped = 0
    for row in rows:
        raw_name = row.get("name")
        brand = row.get("brand") or {}
        raw_brand = brand.get("name")
        if not raw_name or not raw_brand:
            logger.warning(
                "sneakers: skipping id=%s — missing name (%r) or brand (%r)",
                row.get("id"), raw_name, raw_brand
            )
            skipped += 1
            continue
        try:
            canonical_brand = canonicalize_brand(raw_brand)
            lookup_key = sneaker_lookup_key(raw_name, canonical_brand)
        except ValueError as exc:
            logger.warning(
                "sneakers: skipping id=%s — normalize failed: %s",
                row.get("id"), exc
            )
            skipped += 1
            continue
        sb.table("sneakers").update({"lookup_key": lookup_key}).eq(
            "id", row["id"]
        ).execute()
        updated += 1
        logger.info(
            "sneakers: updated id=%s: name=%r brand=%r -> lookup_key=%r",
            row["id"], raw_name, raw_brand, lookup_key
        )
    return updated, skipped


def _backfill_colorways(sb) -> tuple[int, int]:
    """Backfill colorways.lookup_key. Returns (updated, skipped)."""
    rows = sb.table("colorways").select("id, name").execute().data
    logger.info("colorways: loaded %d rows", len(rows))

    updated = 0
    skipped = 0
    for row in rows:
        raw_name = row.get("name")
        if not raw_name:
            logger.warning(
                "colorways: skipping id=%s — missing name",
                row.get("id")
            )
            skipped += 1
            continue
        try:
            lookup_key = colorway_lookup_key(raw_name)
        except ValueError as exc:
            logger.warning(
                "colorways: skipping id=%s — normalize failed: %s",
                row.get("id"), exc
            )
            skipped += 1
            continue
        sb.table("colorways").update({"lookup_key": lookup_key}).eq(
            "id", row["id"]
        ).execute()
        updated += 1
        logger.info(
            "colorways: updated id=%s: name=%r -> lookup_key=%r",
            row["id"], raw_name, lookup_key
        )
    return updated, skipped


def main() -> int:
    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_KEY")
    if not url or not key:
        logger.error("SUPABASE_URL and SUPABASE_SERVICE_KEY must be set")
        return 1

    sb = create_client(url, key)
    s_updated, s_skipped = _backfill_sneakers(sb)
    c_updated, c_skipped = _backfill_colorways(sb)
    logger.info(
        "Done. sneakers updated=%d skipped=%d  colorways updated=%d skipped=%d",
        s_updated, s_skipped, c_updated, c_skipped
    )
    return 0
```

- [ ] **Step 2: Extend the import to include `colorway_lookup_key`**

Find:
```python
from .canonicalize import canonicalize_brand, sneaker_lookup_key
```

Replace with:
```python
from .canonicalize import (
    canonicalize_brand,
    colorway_lookup_key,
    sneaker_lookup_key,
)
```

- [ ] **Step 3: Run the backfill against the live DB**

(Controller note: must be done AFTER the Task 1 migration has been applied to the live Supabase.)

```bash
cd /workspace/sneaker-scout-backend
python -m data_upload.backfill_lookup_keys
```

If `load_dotenv()` fails with `AssertionError: frame.f_back is not None`, use `load_dotenv("/workspace/sneaker-scout-backend/.env")` instead.

Expected output:
```
INFO sneakers: loaded 33 rows
INFO sneakers: updated id=...
...
INFO colorways: loaded ~45 rows
INFO colorways: updated id=...
...
INFO Done. sneakers updated=33 skipped=0  colorways updated=~45 skipped=0
```

Re-running the sneaker pass is idempotent — it'll rewrite the same keys.

- [ ] **Step 4: Spot-check the colorway pass collapsed at least one cross-spelling pair**

```bash
python -c "
import os
from dotenv import load_dotenv
from supabase import create_client
load_dotenv('/workspace/sneaker-scout-backend/.env')
sb = create_client(os.environ['SUPABASE_URL'], os.environ['SUPABASE_SERVICE_KEY'])
rows = sb.table('colorways').select('sneaker_id, name, lookup_key').execute().data
from collections import defaultdict
groups = defaultdict(list)
for r in rows:
    groups[(r['sneaker_id'], r['lookup_key'])].append(r['name'])
for k, names in groups.items():
    if len(names) > 1:
        print(f'  COLLAPSE: sneaker_id={k[0]} lookup_key={k[1]!r} <- {names}')
print(f'total {len(rows)} colorways, {sum(1 for v in groups.values() if len(v) > 1)} collision pairs')
"
```

The exact collision count depends on production state, but any colorway pair that previously created two rows for the same sneaker should now show up.

- [ ] **Step 5: Commit**

```bash
git -C /workspace/sneaker-scout-backend add data_upload/backfill_lookup_keys.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-s8z): extend backfill to populate colorways.lookup_key"
```

---

## Task 4: Wire `colorway_lookup_key` into the upsert

**Files:**
- Modify: `sneaker-scout-backend/data_upload/update_supabase_daily.py` (the colorway-upsert block, ~lines 200-230)
- Modify: `sneaker-scout-backend/tests/test_canonicalize.py` (one new import-guard test)

(Controller note: stash the pre-existing dirty diff on `update_supabase_daily.py` before dispatching this task, mirroring the ery flow.)

- [ ] **Step 1: Extend the import**

Find:
```python
from .canonicalize import canonicalize_brand, sneaker_lookup_key
```

Replace with:
```python
from .canonicalize import (
    canonicalize_brand,
    colorway_lookup_key,
    sneaker_lookup_key,
)
```

- [ ] **Step 2: Replace the colorway-upsert block**

Find this block in `data_upload/update_supabase_daily.py` (the section starting around `# 3. Check if colorway exists by name and sneaker_id`):

```python
            colorway_response = supabase.table("colorways").select("id, image_url").eq("name", colorway_name).eq("sneaker_id", sneaker_id).execute()

            if not colorway_response.data:
                # Insert new colorway
                colorway_response = supabase.table("colorways").insert({
                    "sneaker_id": sneaker_id,
                    "name": colorway_name,
                    "image_url": colorway_image,
                }).execute()
                logger.info(f"Inserted colorway: {colorway_name}")
            else:
                # Colorway exists, check if image_url needs updating
                existing_colorway = colorway_response.data[0]
                colorway_id = existing_colorway["id"]
                existing_image_url = existing_colorway.get("image_url")

                if colorway_image and colorway_image != existing_image_url:
                    supabase.table("colorways").update({
                        "image_url": colorway_image,
                    }).eq("id", colorway_id).execute()
                    logger.info(f"Updated colorway image for {colorway_name}: {existing_image_url} -> {colorway_image}")
                else:
                    logger.info(f"Colorway already exists and image_url is up to date or not provided: {colorway_name}")
            
            colorway_id = colorway_response.data[0]["id"]
```

Replace with:

```python
            # 3. Check if colorway exists by (sneaker_id, lookup_key).
            # lookup_key collapses retailer-specific spellings of the
            # same colorway ('black/black/ftwsilver' vs 'Black/Black/Ftwsilver'
            # vs 'BLACK/BLACK/FTWSILVER (000)') onto a single row per
            # sneaker. First-write-wins on both `name` and `image_url`:
            # on match, neither column is touched. See sneaker_scout-s8z.
            colorway_lookup = colorway_lookup_key(colorway_name)
            colorway_response = supabase.table("colorways").select(
                "id, name, image_url"
            ).eq("lookup_key", colorway_lookup).eq("sneaker_id", sneaker_id).execute()

            if not colorway_response.data:
                colorway_response = supabase.table("colorways").insert({
                    "sneaker_id": sneaker_id,
                    "name": colorway_name,
                    "lookup_key": colorway_lookup,
                    "image_url": colorway_image,
                }).execute()
                logger.info(
                    f"Inserted colorway: {colorway_name!r} "
                    f"(lookup_key={colorway_lookup!r})"
                )
            else:
                existing = colorway_response.data[0]
                logger.info(
                    f"Matched colorway: {colorway_name!r} -> existing "
                    f"row {existing['name']!r} (lookup_key={colorway_lookup!r}); "
                    f"first-write-wins, no update applied"
                )

            colorway_id = colorway_response.data[0]["id"]
```

Key changes:
- Compute `colorway_lookup` before the SELECT.
- SELECT matches on `(sneaker_id, lookup_key)`, not `(sneaker_id, name)`.
- INSERT payload writes `lookup_key`.
- The MATCH branch is now a no-op (no image_url update). This is intentional: the pre-existing code updated image_url whenever the scraped image differed from the stored one (de facto last-write-wins on image). With first-write-wins applied to both name AND image_url, the match branch only logs.

- [ ] **Step 3: Add a regression test**

Append to `/workspace/sneaker-scout-backend/tests/test_canonicalize.py`:

```python
def test_update_supabase_daily_imports_colorway_lookup_key():
    # Belt-and-braces: matches the existing brand and sneaker import guards.
    from data_upload import update_supabase_daily
    assert hasattr(update_supabase_daily, "colorway_lookup_key")
```

- [ ] **Step 4: Run pytest**

```bash
cd /workspace/sneaker-scout-backend
pytest tests/test_canonicalize.py -v
```

Expect all tests pass (one more than before — the new import-guard test).

- [ ] **Step 5: Stage and commit ONLY the two files**

```bash
git -C /workspace/sneaker-scout-backend status --short
```

Confirm ONLY `data_upload/update_supabase_daily.py` and `tests/test_canonicalize.py` are staged. Then:

```bash
git -C /workspace/sneaker-scout-backend add data_upload/update_supabase_daily.py tests/test_canonicalize.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-s8z): match colorways by lookup_key at upsert site"
```

---

## Task 5: Dry-run sanity check

**Files:** none (controller-only, read-only verification).

- [ ] **Step 1: Predict post-normalization colorway groupings**

```bash
cd /workspace/sneaker-scout-backend
python -c "
import json, pathlib
import sys
sys.path.insert(0, '.')
from data_upload.canonicalize import colorway_lookup_key

groups = {}
for p in pathlib.Path('jsons').glob('*_products.json'):
    for item in json.load(open(p)):
        cw = item.get('colorway', {})
        raw = cw.get('name') or cw.get('colorway_name')
        if not raw:
            continue
        sneaker_name = item.get('sneaker', {}).get('name', '?')
        try:
            key = colorway_lookup_key(raw)
        except ValueError as e:
            print(f'  SKIP {sneaker_name!r}/{raw!r}: {e}')
            continue
        groups.setdefault((sneaker_name, key), set()).add(raw)

for (sneaker, key), names in sorted(groups.items()):
    marker = '** ' if len(names) > 1 else '   '
    print(f'{marker}sneaker={sneaker!r:35} key={key!r:30} <- {sorted(names)}')
"
```

The output shows every (sneaker_name, colorway_lookup_key) group. `**` markers indicate cross-retailer collapses — colorway names from different retailers that now hash to the same key under the same sneaker. The exact count depends on JSON snapshots present.

- [ ] **Step 2: No commit** — verification only.

---

## Task 6 (optional): Regenerate frontend Supabase types

Same pattern as ery Task 6. Skip if no Supabase CLI is available — frontend doesn't read `lookup_key`.

If running:

```bash
cd /workspace/aussie-kicks-tracker
npx supabase gen types typescript --linked > src/integrations/supabase/types.ts
npm run lint
npm run build
git add src/integrations/supabase/types.ts
git commit -m "chore(sneaker_scout-s8z): regenerate supabase types for colorways.lookup_key"
```

---

## Task 7: Close the issue and recap commit

**Files:** none (git + bd operations).

- [ ] **Step 1: Run all tests once more**

```bash
cd /workspace/sneaker-scout-backend
pytest tests/test_canonicalize.py -v
```

Expect all green.

- [ ] **Step 2: Status check across all three repos**

```bash
git -C /workspace/sneaker-scout-backend status --short
git -C /workspace/aussie-kicks-tracker status --short
git -C /workspace status --short
```

Pre-existing dirty state is fine; only flag uncommitted s8z work.

- [ ] **Step 3: Close the bd issue**

```bash
bd close sneaker_scout-s8z --reason="colorways.lookup_key column added. colorway_lookup_key(scraped_name) strips trailing Platypus parens SKU codes, lowercases, strips non-alphanumerics; preserves Foot Locker ' - BAT' / ' - CASPER' nicknames. update_supabase_daily.py matches by (sneaker_id, lookup_key) with first-write-wins on name AND image_url. Backfill script extended to two-pass (sneakers + colorways). UNIQUE(sneaker_id, lookup_key) deferred to xdl."
```

- [ ] **Step 4: Recap commit in /workspace**

```bash
cd /workspace
git add .beads/.bv.lock .beads/export-state.json .beads/interactions.jsonl .beads/issues.jsonl
git commit -m "$(cat <<'EOF'
feat(sneaker_scout-s8z): normalize colorway names at ingest

Mirror of sneaker_scout-ery for the colorway axis. Different retailer
scrapers produce different colorway strings for the same colorway
('black/black/ftwsilver' vs 'Black/Black/Ftwsilver' vs
'BLACK/BLACK/FTWSILVER (000)' vs 'Black-Black-Black - BAT') and the
uploader was matching by exact (sneaker_id, name), so the same
colorway across retailers landed as multiple colorway rows under a
shoe.

Schema: colorways.lookup_key text NOT NULL DEFAULT '' with a
non-unique index on (sneaker_id, lookup_key). Migration file lives
in aussie-kicks-tracker/supabase/migrations/.

Python: colorway_lookup_key(scraped_colorway_name) in
data_upload/canonicalize.py. Strips trailing Platypus-style parens
SKU codes (e.g. '(108)'), lowercases, strips non-alphanumerics.
Preserves Foot Locker nickname suffixes ('- BAT' / '- CASPER')
because they distinguish genuinely different colorways. Raises
ValueError on empty or punctuation-only input.

Ingest path: update_supabase_daily.py now matches colorways on
(sneaker_id, lookup_key). First-write-wins is extended to both
`name` AND `image_url` — the pre-existing last-write-wins image
update behaviour goes away as a side effect.

Backfill: data_upload/backfill_lookup_keys.py is now a two-pass
tool (sneakers + colorways). Populates colorways.lookup_key for
the ~45 rows already in production.

UNIQUE(sneaker_id, lookup_key) is deferred to sneaker_scout-xdl.

Closes: sneaker_scout-s8z
EOF
)"
```

---

## Self-Review

**Spec coverage** — `sneaker_scout-s8z` calls for:

| Requirement | Covered by |
|---|---|
| Casefold for matching | Sub-cycle 2.2 |
| Collapse separator whitespace | Sub-cycle 2.2 (alphanumeric-only filter erases all separators) |
| Original string for display | Task 4 (first-write-wins on `name`) |
| Lower priority than sneaker work | Was the scoping rationale; this plan honors it by reusing ery's structure |
| Foundation for 5qf (price-drop page can rank by colorway) | After s8z lands, each colorway row aggregates prices across retailers — 5qf gets clean data |

**Placeholder scan** — every code step has actual code. No "TBD" / "similar to Task N" patterns.

**Type consistency** — `colorway_lookup_key(scraped_colorway_name: str) -> str` is consistent across Sub-cycles 2.1-2.5, the fixture test, Task 3's backfill, and Task 4's wiring.

**Things to flag at execution time:**

1. Task 1's migration has to be applied via the Supabase dashboard (no CLI in this environment, no `exec_sql` RPC defined). Controller handles between Task 1 and Task 3.

2. Task 4 replaces a block whose match branch currently DOES update `image_url`. The new match branch does NOT update image_url. This is intentional (first-write-wins) but is a behaviour change worth calling out in the recap.

3. The pre-existing dirty diff on `data_upload/update_supabase_daily.py` (a colorway field-name compat fix unrelated to s8z) must be stashed by the controller before Task 4 and restored after.

4. The fixture test in Sub-cycle 2.6 reads `colorway.name OR colorway.colorway_name` to handle both pre-canonical and post-canonical JSON formats. Production scrapers should be writing `colorway.name`; if a fixture file is in the old `colorway_name` shape, that's not a test failure but a hint the scraper output format has drifted.
