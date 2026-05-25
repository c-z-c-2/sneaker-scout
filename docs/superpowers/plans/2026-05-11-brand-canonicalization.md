# Brand-name canonicalization at ingest — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a brand-name canonicalization layer to the Supabase ingest pipeline so different retailer scrapers' brand strings (`Salomon` vs `Salomon brand Logo Large`; `adidas` vs `adidas Originals` vs `adidas Performance`; `Asics` vs `ASICS Sportstyle`) collapse onto a single canonical brand row.

**Architecture:** Pure Python regex + alias-dictionary hybrid, exposed as `canonicalize_brand(raw: str) -> str` from a new module `sneaker-scout-backend/data_upload/canonicalize.py`. Called once at the brand-upsert site in `update_supabase_daily.py` to compute both the lookup key and the display string (same value — there is no schema change). TDD with pytest, one regex rule per task. The output is the brand's _preferred display form_; downstream consumers (frontend filter chips, future `ery`/`s8z` issues) read it unchanged. No DB schema change in this issue — `xdl` will backfill historical duplicates after `1oj`/`ery`/`s8z` ship.

**Tech Stack:** Python 3.12, pytest (new dev dep), existing `supabase-py` client. No new runtime dependencies. The canonicalizer is dependency-free.

**Scope note:** This plan is scoped to the brand axis only. Sneaker-name and colorway normalization are tracked in `sneaker_scout-ery` and `sneaker_scout-s8z` respectively; both will live in the same `canonicalize.py` module but are out-of-scope here.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `sneaker-scout-backend/data_upload/__init__.py` | Create | Make `data_upload` an explicit package so the test module can `from data_upload.canonicalize import …`. Currently absent — `data_upload` is an implicit namespace package today. |
| `sneaker-scout-backend/data_upload/canonicalize.py` | Create | The `canonicalize_brand` function plus the `BRAND_ALIASES` dict and the regex constants. ~50 lines. Sneaker/colorway canonicalizers (separate issues) will land here later. |
| `sneaker-scout-backend/tests/__init__.py` | Create if missing | Same reason — make `tests/` a proper package for pytest discovery. |
| `sneaker-scout-backend/tests/test_canonicalize.py` | Create | pytest module covering every public input class the function accepts. |
| `sneaker-scout-backend/data_upload/update_supabase_daily.py` | Modify (lines 147–158) | Wire `canonicalize_brand` into the brand-upsert lookup. |
| `sneaker-scout-backend/requirements-dev.txt` | Create | pytest pin; keeps runtime `requirements.txt` lean. |

No schema changes. No frontend changes. No spec.yaml change (spec.yaml describes the Supabase REST surface and scraper CLI invocations; the canonicalization is an internal transform of an existing CLI's behaviour and the columns it writes are unchanged).

---

## Task 1: Bootstrap test scaffolding

**Files:**
- Create: `sneaker-scout-backend/data_upload/__init__.py`
- Create: `sneaker-scout-backend/tests/__init__.py`
- Create: `sneaker-scout-backend/data_upload/canonicalize.py`
- Create: `sneaker-scout-backend/requirements-dev.txt`
- Create: `sneaker-scout-backend/tests/test_canonicalize.py`

- [ ] **Step 1: Create `data_upload/__init__.py`**

Empty file:

```python
```

(zero bytes is fine — just establishes the package).

- [ ] **Step 2: Create `tests/__init__.py`**

Empty file (same reasoning).

- [ ] **Step 3: Create `requirements-dev.txt`**

```
pytest>=8.0
```

- [ ] **Step 4: Install dev dependencies**

Run from the project root:

```bash
/workspace/sneaker-scout-backend/.venv/bin/pip install -r /workspace/sneaker-scout-backend/requirements-dev.txt
```

Expected: pytest 8.x installed.

- [ ] **Step 5: Create `data_upload/canonicalize.py` with a stub**

```python
"""Canonicalization helpers for the Supabase ingest pipeline.

Each retailer scraper produces its own naming convention. Without
canonicalization, the same physical product lands as multiple rows
because update_supabase_daily.py upserts by exact string match.

This module exposes one function per axis (brand / sneaker / colorway —
the latter two will land via sneaker_scout-ery and sneaker_scout-s8z).
Each returns the *preferred display form*, which doubles as the DB
lookup key. There is no schema change — we are normalizing the value
that gets written into `brands.name` (and equivalent columns) so the
existing exact-match upsert collapses duplicates."""

from __future__ import annotations


def canonicalize_brand(raw: str) -> str:
    """Return the canonical display form of a brand name.

    Strips the 'X brand Logo Large' alt-text artefact (Hype DC scraping
    bug), drops sub-brand suffixes (Originals/Performance/Sportstyle),
    and normalizes casing for known brands via a small alias dictionary.
    Unknown brands fall through preserving their original casing."""
    raise NotImplementedError
```

- [ ] **Step 6: Create `tests/test_canonicalize.py` with one smoke test**

```python
"""Tests for data_upload.canonicalize.

Run from sneaker-scout-backend/:
    .venv/bin/pytest tests/test_canonicalize.py -v
"""

from data_upload.canonicalize import canonicalize_brand


def test_canonicalize_brand_is_importable():
    # Calling will raise NotImplementedError until Task 2; the smoke
    # check is that the function exists and is callable.
    assert callable(canonicalize_brand)
```

- [ ] **Step 7: Run pytest to verify discovery works**

```bash
cd /workspace/sneaker-scout-backend
.venv/bin/pytest tests/test_canonicalize.py -v
```

Expected: 1 passed.

- [ ] **Step 8: Commit**

```bash
git add sneaker-scout-backend/data_upload/__init__.py \
        sneaker-scout-backend/data_upload/canonicalize.py \
        sneaker-scout-backend/tests/__init__.py \
        sneaker-scout-backend/tests/test_canonicalize.py \
        sneaker-scout-backend/requirements-dev.txt
git commit -m "chore(sneaker_scout-1oj): scaffold canonicalize module + pytest dev dep"
```

---

## Task 2: TDD — bare brand passes through unchanged

**Files:**
- Modify: `sneaker-scout-backend/tests/test_canonicalize.py`
- Modify: `sneaker-scout-backend/data_upload/canonicalize.py`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_canonicalize.py`:

```python
def test_bare_brand_passes_through():
    assert canonicalize_brand("Salomon") == "Salomon"
    assert canonicalize_brand("Nike") == "Nike"
```

- [ ] **Step 2: Run and verify failure**

```bash
cd /workspace/sneaker-scout-backend
.venv/bin/pytest tests/test_canonicalize.py::test_bare_brand_passes_through -v
```

Expected: FAIL with `NotImplementedError`.

- [ ] **Step 3: Replace the stub body**

Replace the `raise NotImplementedError` line with:

```python
    return raw
```

- [ ] **Step 4: Run and verify pass**

```bash
.venv/bin/pytest tests/test_canonicalize.py -v
```

Expected: 2 passed.

- [ ] **Step 5: Commit**

```bash
git add sneaker-scout-backend/tests/test_canonicalize.py \
        sneaker-scout-backend/data_upload/canonicalize.py
git commit -m "feat(sneaker_scout-1oj): identity passthrough for bare brand names"
```

---

## Task 3: TDD — strip Hype DC "brand Logo Large" alt-text bug

**Files:**
- Modify: `sneaker-scout-backend/tests/test_canonicalize.py`
- Modify: `sneaker-scout-backend/data_upload/canonicalize.py`

- [ ] **Step 1: Write the failing tests**

Append:

```python
def test_strips_brand_logo_large_alt_text():
    # Hype DC scraper bug: alt attribute of the brand logo image leaks
    # into the brand-name field. See sneaker_scout-c3o for the upstream
    # fix; this function papers over it on the ingest side.
    assert canonicalize_brand("Salomon brand Logo Large") == "Salomon"
    assert canonicalize_brand("Nike brand Logo Large") == "Nike"
    # Case-insensitive match on the suffix
    assert canonicalize_brand("Salomon Brand Logo Large") == "Salomon"
    assert canonicalize_brand("Salomon BRAND LOGO LARGE") == "Salomon"
```

- [ ] **Step 2: Run and verify failure**

```bash
.venv/bin/pytest tests/test_canonicalize.py::test_strips_brand_logo_large_alt_text -v
```

Expected: FAIL — function returns the raw input.

- [ ] **Step 3: Add the regex strip**

Replace the body of `canonicalize_brand` with:

```python
    import re
    s = raw
    s = re.sub(r"\s+brand\s+logo\s+large\s*$", "", s, flags=re.IGNORECASE)
    return s
```

Then lift the `import re` to the top of the module (idiomatic):

```python
from __future__ import annotations

import re
```

…and the function body becomes:

```python
    s = raw
    s = re.sub(r"\s+brand\s+logo\s+large\s*$", "", s, flags=re.IGNORECASE)
    return s
```

- [ ] **Step 4: Run and verify pass**

```bash
.venv/bin/pytest tests/test_canonicalize.py -v
```

Expected: 3 passed (smoke + bare + alt-text strip).

- [ ] **Step 5: Commit**

```bash
git add sneaker-scout-backend/tests/test_canonicalize.py \
        sneaker-scout-backend/data_upload/canonicalize.py
git commit -m "feat(sneaker_scout-1oj): strip Hype DC 'brand Logo Large' alt-text suffix"
```

---

## Task 4: TDD — strip sub-brand suffixes

**Files:**
- Modify: `sneaker-scout-backend/tests/test_canonicalize.py`
- Modify: `sneaker-scout-backend/data_upload/canonicalize.py`

- [ ] **Step 1: Write the failing tests**

Append:

```python
def test_strips_subbrand_suffixes():
    # Hype DC distinguishes adidas Originals from adidas Performance;
    # users want a single 'adidas' filter chip.
    assert canonicalize_brand("adidas Originals") == "adidas"
    assert canonicalize_brand("adidas Performance") == "adidas"
    assert canonicalize_brand("ASICS Sportstyle") == "ASICS"
    # Case-insensitive
    assert canonicalize_brand("adidas originals") == "adidas"
    assert canonicalize_brand("ASICS SPORTSTYLE") == "ASICS"


def test_subbrand_strip_only_at_end():
    # A brand string that legitimately contains the word should not be
    # mangled — guard against false positives.
    assert canonicalize_brand("Performance Lab") == "Performance Lab"
```

- [ ] **Step 2: Run and verify failure**

```bash
.venv/bin/pytest tests/test_canonicalize.py::test_strips_subbrand_suffixes -v
```

Expected: FAIL.

- [ ] **Step 3: Add the sub-brand regex strip**

Update `canonicalize_brand` body to:

```python
    s = raw
    s = re.sub(r"\s+brand\s+logo\s+large\s*$", "", s, flags=re.IGNORECASE)
    s = re.sub(r"\s+(originals|performance|sportstyle)\s*$", "", s, flags=re.IGNORECASE)
    return s
```

- [ ] **Step 4: Run and verify pass**

```bash
.venv/bin/pytest tests/test_canonicalize.py -v
```

Expected: 5 passed.

- [ ] **Step 5: Commit**

```bash
git add sneaker-scout-backend/tests/test_canonicalize.py \
        sneaker-scout-backend/data_upload/canonicalize.py
git commit -m "feat(sneaker_scout-1oj): collapse adidas Originals/Performance + ASICS Sportstyle"
```

---

## Task 5: TDD — case normalization via alias dictionary

**Files:**
- Modify: `sneaker-scout-backend/tests/test_canonicalize.py`
- Modify: `sneaker-scout-backend/data_upload/canonicalize.py`

- [ ] **Step 1: Write the failing tests**

Append:

```python
def test_alias_normalizes_casing():
    # 'Asics' (Platypus) and 'ASICS Sportstyle' (Hype DC) should both
    # land on 'ASICS' (the brand's own preferred form).
    assert canonicalize_brand("Asics") == "ASICS"
    assert canonicalize_brand("asics") == "ASICS"
    assert canonicalize_brand("ASICS Sportstyle") == "ASICS"
    # adidas prefers lowercase
    assert canonicalize_brand("Adidas") == "adidas"
    assert canonicalize_brand("ADIDAS") == "adidas"
    # Stays Nike regardless of case input
    assert canonicalize_brand("NIKE") == "Nike"
    assert canonicalize_brand("nike") == "Nike"


def test_unknown_brand_preserves_input_casing():
    # A brand that isn't in the alias table falls through with its
    # original casing — we don't want to lowercase 'New Balance' or
    # break future additions.
    assert canonicalize_brand("Some Indie Maker") == "Some Indie Maker"
```

- [ ] **Step 2: Run and verify failure**

```bash
.venv/bin/pytest tests/test_canonicalize.py::test_alias_normalizes_casing -v
```

Expected: FAIL — current code preserves input casing for everything.

- [ ] **Step 3: Add the alias dictionary and lookup**

Update the full module to:

```python
"""Canonicalization helpers for the Supabase ingest pipeline.

Each retailer scraper produces its own naming convention. Without
canonicalization, the same physical product lands as multiple rows
because update_supabase_daily.py upserts by exact string match.

This module exposes one function per axis (brand / sneaker / colorway —
the latter two will land via sneaker_scout-ery and sneaker_scout-s8z).
Each returns the *preferred display form*, which doubles as the DB
lookup key. There is no schema change — we are normalizing the value
that gets written into `brands.name` (and equivalent columns) so the
existing exact-match upsert collapses duplicates."""

from __future__ import annotations

import re

# Preferred display form, keyed by lowercase variant. Add a row when a
# new retailer surfaces a known brand with non-standard casing.
BRAND_ALIASES: dict[str, str] = {
    "salomon": "Salomon",
    "asics": "ASICS",
    "adidas": "adidas",
    "nike": "Nike",
    "new balance": "New Balance",
    "vans": "Vans",
    "reebok": "Reebok",
    "converse": "Converse",
    "puma": "Puma",
    "jordan": "Jordan",
    "air jordan": "Jordan",
}

_BRAND_LOGO_SUFFIX = re.compile(r"\s+brand\s+logo\s+large\s*$", re.IGNORECASE)
_SUBBRAND_SUFFIX = re.compile(
    r"\s+(originals|performance|sportstyle)\s*$", re.IGNORECASE
)


def canonicalize_brand(raw: str) -> str:
    """Return the canonical display form of a brand name.

    Strips the 'X brand Logo Large' alt-text artefact (Hype DC scraping
    bug), drops sub-brand suffixes (Originals/Performance/Sportstyle),
    and normalizes casing for known brands via BRAND_ALIASES. Unknown
    brands fall through preserving their original casing."""
    s = _BRAND_LOGO_SUFFIX.sub("", raw)
    s = _SUBBRAND_SUFFIX.sub("", s)
    return BRAND_ALIASES.get(s.lower(), s)
```

- [ ] **Step 4: Run and verify pass**

```bash
.venv/bin/pytest tests/test_canonicalize.py -v
```

Expected: 7 passed.

- [ ] **Step 5: Commit**

```bash
git add sneaker-scout-backend/tests/test_canonicalize.py \
        sneaker-scout-backend/data_upload/canonicalize.py
git commit -m "feat(sneaker_scout-1oj): alias table normalizes brand casing"
```

---

## Task 6: TDD — whitespace + empty input handling

**Files:**
- Modify: `sneaker-scout-backend/tests/test_canonicalize.py`
- Modify: `sneaker-scout-backend/data_upload/canonicalize.py`

- [ ] **Step 1: Write the failing tests**

Append:

```python
import pytest


def test_strips_surrounding_whitespace():
    assert canonicalize_brand("  Salomon  ") == "Salomon"
    assert canonicalize_brand("\tASICS\n") == "ASICS"


def test_empty_input_raises():
    with pytest.raises(ValueError):
        canonicalize_brand("")
    with pytest.raises(ValueError):
        canonicalize_brand("   ")
```

- [ ] **Step 2: Run and verify failure**

```bash
.venv/bin/pytest tests/test_canonicalize.py -v
```

Expected: both whitespace tests FAIL.

- [ ] **Step 3: Handle whitespace and empty input**

Update `canonicalize_brand`:

```python
def canonicalize_brand(raw: str) -> str:
    """Return the canonical display form of a brand name.

    Strips the 'X brand Logo Large' alt-text artefact (Hype DC scraping
    bug), drops sub-brand suffixes (Originals/Performance/Sportstyle),
    and normalizes casing for known brands via BRAND_ALIASES. Unknown
    brands fall through preserving their original casing.

    Raises ValueError on empty/whitespace-only input — a missing brand
    is upstream data corruption that should fail the ingest loudly."""
    s = (raw or "").strip()
    if not s:
        raise ValueError("brand name is empty or whitespace-only")
    s = _BRAND_LOGO_SUFFIX.sub("", s)
    s = _SUBBRAND_SUFFIX.sub("", s)
    return BRAND_ALIASES.get(s.lower(), s)
```

- [ ] **Step 4: Run and verify pass**

```bash
.venv/bin/pytest tests/test_canonicalize.py -v
```

Expected: 9 passed.

- [ ] **Step 5: Commit**

```bash
git add sneaker-scout-backend/tests/test_canonicalize.py \
        sneaker-scout-backend/data_upload/canonicalize.py
git commit -m "feat(sneaker_scout-1oj): trim whitespace and reject empty brand input"
```

---

## Task 7: TDD — fixture-driven check against real scraped JSON

**Files:**
- Modify: `sneaker-scout-backend/tests/test_canonicalize.py`

This task locks in behaviour against the real scraper output sitting in
`jsons/` so a future regex change can't silently regress on actual data.

- [ ] **Step 1: Write the failing/passing test**

Append:

```python
import json
import pathlib


def test_canonicalizes_real_scraped_brands():
    # Pin behaviour against every brand string seen in the current JSON
    # snapshots. Add new (input, expected) pairs when a scraper produces
    # a new variant.
    expected = {
        # Salomon direct
        "Salomon": "Salomon",
        # Hype DC alt-text bug + sub-brand variants
        "Salomon brand Logo Large": "Salomon",
        "adidas Originals": "adidas",
        "adidas Performance": "adidas",
        "ASICS Sportstyle": "ASICS",
        "New Balance": "New Balance",
        "Nike": "Nike",
        # Platypus variants
        "Vans": "Vans",
        "Asics": "ASICS",
        "adidas": "adidas",
        "Reebok": "Reebok",
        "Converse": "Converse",
        # Foot Locker
    }
    for raw, want in expected.items():
        assert canonicalize_brand(raw) == want, f"{raw!r} -> {canonicalize_brand(raw)!r}, want {want!r}"

    # And sanity-check that every brand string actually present in the
    # checked-in scraper outputs lands somewhere — i.e. no exception.
    jsons_dir = pathlib.Path(__file__).resolve().parent.parent / "jsons"
    if not jsons_dir.is_dir():
        # Running outside the repo layout; skip the file scan.
        return
    for path in jsons_dir.glob("*_products.json"):
        with path.open() as f:
            items = json.load(f)
        for item in items:
            raw = item.get("brand", {}).get("name")
            if raw:
                canonicalize_brand(raw)  # must not raise
```

- [ ] **Step 2: Run the test**

```bash
.venv/bin/pytest tests/test_canonicalize.py::test_canonicalizes_real_scraped_brands -v
```

Expected: PASS (Tasks 2–6 should already cover everything in the dict).
If it fails on a particular pair, that's a regex gap — fix the regex
and re-run before committing.

- [ ] **Step 3: Commit**

```bash
git add sneaker-scout-backend/tests/test_canonicalize.py
git commit -m "test(sneaker_scout-1oj): lock canonicalization against real scraped JSON"
```

---

## Task 8: Wire `canonicalize_brand` into the upsert path

**Files:**
- Modify: `sneaker-scout-backend/data_upload/update_supabase_daily.py` (lines ~140–160)

- [ ] **Step 1: Add the import**

At the top of `update_supabase_daily.py`, alongside the existing imports:

```python
from data_upload.canonicalize import canonicalize_brand
```

(The `data_upload` package now resolves because Task 1 added `__init__.py`.)

- [ ] **Step 2: Replace the brand-upsert block**

Find this block (currently around lines 147–159):

```python
            # 1. Insert brand (if not exists)
            brand_data = item["brand"]
            brand_response = supabase.table("brands").select("id").eq("name", brand_data["name"]).execute()

            if not brand_response.data:
                brand_response = supabase.table("brands").insert({
                    "name": brand_data["name"],
                    "logo_url": brand_data["logo_url"]
                }).execute()
                logger.info(f"Inserted brand: {brand_data['name']}")
            else:
                logger.info(f"Brand already exists: {brand_data['name']}")

            brand_id = brand_response.data[0]["id"]
```

Replace with:

```python
            # 1. Insert brand (if not exists). Canonicalize first so
            # 'Salomon brand Logo Large' / 'adidas Originals' / 'Asics'
            # collapse onto the same row as 'Salomon' / 'adidas' /
            # 'ASICS' respectively. See sneaker_scout-1oj.
            brand_data = item["brand"]
            brand_name = canonicalize_brand(brand_data["name"])
            brand_response = supabase.table("brands").select("id").eq("name", brand_name).execute()

            if not brand_response.data:
                brand_response = supabase.table("brands").insert({
                    "name": brand_name,
                    "logo_url": brand_data["logo_url"]
                }).execute()
                logger.info(f"Inserted brand: {brand_name} (raw: {brand_data['name']!r})")
            else:
                logger.info(f"Brand already exists: {brand_name} (raw: {brand_data['name']!r})")

            brand_id = brand_response.data[0]["id"]
```

- [ ] **Step 3: Write a regression test that exercises the wiring**

Add to `sneaker-scout-backend/tests/test_canonicalize.py`:

```python
def test_update_supabase_daily_imports_canonicalize_brand():
    # Belt-and-braces guard: if a refactor accidentally drops the
    # import, the integration silently regresses. Catch it here.
    from data_upload import update_supabase_daily
    assert hasattr(update_supabase_daily, "canonicalize_brand")
```

- [ ] **Step 4: Run the tests**

```bash
cd /workspace/sneaker-scout-backend
.venv/bin/pytest tests/test_canonicalize.py -v
```

Expected: all canonicalize tests + the new import-check pass.

Note: `update_supabase_daily.py` reads `SUPABASE_URL` / `SUPABASE_SERVICE_KEY` at import time. The test imports the module, so the local `.env` must be loadable — which it already is via `load_dotenv()` at the top of the file. If the test fails with a missing-env error, that's a separate config issue; do not paper over it.

- [ ] **Step 5: Commit**

```bash
git add sneaker-scout-backend/data_upload/update_supabase_daily.py \
        sneaker-scout-backend/tests/test_canonicalize.py
git commit -m "feat(sneaker_scout-1oj): canonicalize brand at the upsert site"
```

---

## Task 9: Dry-run sanity check against live JSON snapshots

**Files:** none (read-only verification)

- [ ] **Step 1: Predict the post-canonicalization brand set**

Run from `sneaker-scout-backend/`:

```bash
.venv/bin/python -c "
import json, pathlib
from data_upload.canonicalize import canonicalize_brand
seen = {}
for p in pathlib.Path('jsons').glob('*_products.json'):
    for item in json.load(open(p)):
        raw = item.get('brand', {}).get('name')
        if not raw: continue
        canon = canonicalize_brand(raw)
        seen.setdefault(canon, set()).add(raw)
for canon, raws in sorted(seen.items()):
    print(f'{canon!r:20} <- {sorted(raws)}')
"
```

Expected output (roughly):

```
'ASICS'              <- ['ASICS Sportstyle', 'Asics']
'Converse'           <- ['Converse']
'New Balance'        <- ['New Balance']
'Nike'               <- ['Nike']
'Reebok'             <- ['Reebok']
'Salomon'            <- ['Salomon', 'Salomon brand Logo Large']
'Vans'               <- ['Vans']
'adidas'             <- ['adidas', 'adidas Originals', 'adidas Performance']
```

If a raw variant is missing a known canonical landing — e.g. `'Adidas'`
shows up under its own key instead of folding to `'adidas'` — extend
the alias dict and add a covering test back in `test_canonicalize.py`.
Do not declare the task done while a known-duplicate raw value lands
on its own canonical key.

- [ ] **Step 2: (Optional, requires Supabase) re-upload one JSON and confirm no duplicate brand rows**

Only run this if you want end-to-end verification against the live DB.
The plan does not require it — the post-canonicalization deduplication
of existing duplicate rows is `sneaker_scout-xdl`'s job.

```bash
cd /workspace/sneaker-scout-backend
.venv/bin/python -m data_upload.run_update --file=jsons/hypedc_products.json
```

Then in Python:

```python
import os
from dotenv import load_dotenv
from supabase import create_client
load_dotenv('/workspace/sneaker-scout-backend/.env')
sb = create_client(os.environ['SUPABASE_URL'], os.environ['SUPABASE_SERVICE_KEY'])
br = sb.table('brands').select('id,name').execute().data
print(sorted({r['name'] for r in br}))
```

After the re-upload, the new run should not insert any new brand row
for `'Salomon brand Logo Large'` / `'adidas Originals'` / etc. — the
canonicalizer maps them onto existing rows. (Existing duplicate rows
remain until `xdl` runs.)

- [ ] **Step 3: No commit** — this task is read-only verification.

---

## Task 10: Close the issue and recap commit

**Files:** none (git + bd operations)

This issue uses the project's per-issue commit protocol (one bd close →
one commit). Tasks 1–8 created intermediate commits during development;
the close commit summarizes the whole change.

- [ ] **Step 1: Verify all tests pass**

```bash
cd /workspace/sneaker-scout-backend
.venv/bin/pytest tests/test_canonicalize.py -v
```

Expected: all green.

- [ ] **Step 2: Confirm no uncommitted work**

```bash
git status --short
```

Should show only `.beads/` modifications (from bd state). If files
under `sneaker-scout-backend/` or `docs/` still show as dirty, you
missed a commit — go back and finish it before continuing.

- [ ] **Step 3: Close the bd issue**

```bash
bd close sneaker_scout-1oj --reason="Canonicalization layer landed: BRAND_ALIASES + 'brand Logo Large' / sub-brand suffix regex strips. Wired into update_supabase_daily.py. New ingests won't create duplicate brand rows; xdl will backfill existing duplicates."
```

- [ ] **Step 4: Stage the bd state and create the recap commit**

```bash
git add .beads/.bv.lock .beads/export-state.json .beads/interactions.jsonl .beads/issues.jsonl
git commit -m "$(cat <<'EOF'
feat(sneaker_scout-1oj): canonicalize brand names at ingest

Different retailer scrapers were producing different brand strings for
the same brand (Salomon vs 'Salomon brand Logo Large'; adidas vs
'adidas Originals' / 'adidas Performance'; Asics vs 'ASICS Sportstyle')
and update_supabase_daily.py was upserting brands by exact-string
match, so the production DB grew 13 brand rows that collapsed to 9
canonical brands and split the frontend filter chips.

Added data_upload/canonicalize.py with canonicalize_brand(raw) -> str.
It strips the Hype DC 'brand Logo Large' alt-text artefact (upstream
fix tracked in sneaker_scout-c3o), drops 'Originals' / 'Performance' /
'Sportstyle' sub-brand suffixes, and normalizes casing for known
brands via a BRAND_ALIASES dictionary. Unknown brands fall through
preserving their casing; empty/whitespace input raises ValueError.

The function is called once at the brand-upsert site so the lookup
key and the row's display string are the same canonical value — no
schema change. Existing duplicate rows in the DB are left alone;
sneaker_scout-xdl will backfill them once ery and s8z also ship.

Closes: sneaker_scout-1oj
EOF
)"
```

- [ ] **Step 5: Verify session close protocol**

Per the project's CLAUDE.md session-close protocol:

```bash
bd ready                          # confirm 1oj is no longer ready
git log --oneline -5              # verify the commits chain
git status --short                # should be clean (or only the
                                  # unrelated pre-existing dirty state
                                  # listed at session start)
```

No `git push` — there is no git remote configured in this workspace.
The session-close protocol's push step is a no-op here; just confirm
work is committed locally.

---

## Self-Review

**Spec coverage** — `sneaker_scout-1oj` calls for:

| Requirement | Covered by |
|---|---|
| Brand-name canonicalization at ingest | Tasks 1–8 |
| Handle `<brand> brand Logo Large` alt-text bug | Task 3 |
| Handle sub-brand suffixes (Originals/Performance/Sportstyle) | Task 4 |
| Case folding | Task 5 (alias dict) + Task 6 (whitespace) |
| "Regex layer or brand_aliases lookup table" | Both — regex for suffix stripping, dict for canonical casing |
| Preserve original display strings where useful | Display string = canonical (one filter chip per brand) — argued in Architecture |
| No `gcg` / `5qf` blocking | Dependency edges already exist in beads |

**Placeholder scan** — no "TBD", "implement later", or "similar to Task N"
references. Every code step shows the exact code to write.

**Type consistency** — `canonicalize_brand` signature `(raw: str) -> str`
matches across Tasks 1, 5, 6, 8. `BRAND_ALIASES: dict[str, str]` referenced
only in Task 5 with the same shape. Regex constants `_BRAND_LOGO_SUFFIX`
and `_SUBBRAND_SUFFIX` introduced in Task 5 are not referenced before
that task.

**One thing to flag:** Task 8's import-check test (`test_update_supabase_daily_imports_canonicalize_brand`) triggers a real import of `update_supabase_daily.py`, which reads `SUPABASE_URL` / `SUPABASE_SERVICE_KEY` at import time and raises `ValueError` if they're missing. The local `.env` covers this; CI will need them set or that test will fail loudly — which is the correct behaviour, but worth flagging so it isn't a surprise.
