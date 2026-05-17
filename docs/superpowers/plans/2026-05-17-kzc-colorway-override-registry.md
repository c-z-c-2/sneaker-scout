# Colorway Override Registry — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a human-reviewed YAML registry of per-sneaker colorway aliases so that the ingest pipeline can correctly separate colorways that the algorithm incorrectly collapses (e.g. NB 9060 "Black" vs "Black (000)" vs "Black (001)" all hash to `"black"`), and surface unrecognised collisions for human review rather than silently merging them.

**Architecture:** A new `data_upload/colorway_overrides.yaml` (version-controlled, human-edited) lists per-sneaker alias lists and optional `lookup_key_override` values. A companion Python module `data_upload/colorway_overrides.py` loads that file and exposes a `ColorwayRegistry.lookup(sneaker_key, scraped_name)` method. `update_supabase_daily.py`'s colorway-upsert block consults the registry first: if the scraped name is a known alias it uses the override key; if it would collide with an existing row under a name not in any alias list it writes to `jsons/pending_review.jsonl` (warning, does not block ingest). An interactive CLI `data_upload/review_colorways.py` processes the pending file and writes decisions back to the YAML.

**Tech Stack:** Python 3.11+, PyYAML (add to `requirements.txt`), no other new dependencies. Tests with `pytest`.

**Beads issue:** `sneaker_scout-kzc`

---

## Concrete Problem to Fix

Running today's JSON snapshots through the pipeline:

| Retailer | Scraped name | Algorithmic `colorway_lookup_key` |
|---|---|---|
| Platypus | `BLACK` | `black` |
| Platypus | `BLACK (000)` | `black` ← collision |
| Hype DC | `Black (001)` | `black` ← collision |

All three are genuine, distinct NB 9060 colorways but they'd land on one DB row.

---

## Repository notes

- All implementation files live under `sneaker-scout-backend/`.
- Test command: `python -m pytest tests/test_canonicalize.py -v` (from `sneaker-scout-backend/`).
- `pyyaml` is not yet in `requirements.txt` — Task 1 adds it.
- Variable naming in `update_supabase_daily.py`: `lookup_key` = the **sneaker**'s lookup key (line 176); `colorway_lookup` = the **colorway**'s key (line 228). Keep this distinction throughout.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `requirements.txt` | Modify | Add `pyyaml` |
| `data_upload/colorway_overrides.yaml` | Create | Human-authored registry: per-sneaker alias lists + optional `lookup_key_override` |
| `data_upload/colorway_overrides.py` | Create | `ColorwayRegistry` class + `OverrideResult` dataclass; loads YAML; exposes `lookup()` |
| `data_upload/update_supabase_daily.py` | Modify | Consult registry before colorway upsert; write `pending_review.jsonl` on unrecognised collision |
| `data_upload/review_colorways.py` | Create | Interactive CLI that reads `pending_review.jsonl`, prompts human, updates YAML |
| `tests/test_canonicalize.py` | Modify | Tests for `ColorwayRegistry.lookup()`; import guard for new integration |
| `.gitignore` | Modify | Gitignore `jsons/pending_review.jsonl` (runtime-generated) |

---

## Task 1: Add `pyyaml` and create the YAML registry

**Files:**
- Modify: `sneaker-scout-backend/requirements.txt`
- Create: `sneaker-scout-backend/data_upload/colorway_overrides.yaml`

- [ ] **Step 1: Add pyyaml to requirements.txt**

Open `sneaker-scout-backend/requirements.txt` and append one line:

```
pyyaml
```

- [ ] **Step 2: Create `data_upload/colorway_overrides.yaml`**

Create the file at `sneaker-scout-backend/data_upload/colorway_overrides.yaml` with this exact content:

```yaml
# Human-reviewed per-sneaker colorway disambiguation registry.
#
# Problem: colorway_lookup_key() strips trailing parens codes (e.g. '(000)')
# which is correct for most Platypus SKU metadata but wrong when the code
# distinguishes genuinely different colorways on the same sneaker.
#
# Format:
#   sneakers:
#     <sneaker_lookup_key>:     # output of sneaker_lookup_key() for this model
#       colorways:
#         <canonical_display_name>:
#           aliases: [list of scraped strings that belong to this colorway]
#           lookup_key_override: <optional — overrides the algorithmic key>
#
# When ingest sees a scraped colorway string:
#   1. Looks up the current sneaker's lookup_key in this registry.
#   2. Scans all colorway entries for this sneaker to find which entry
#      contains the scraped name in its aliases list.
#   3. If found: uses canonical_display_name and lookup_key_override (if set)
#      instead of the algorithmic colorway_lookup_key() result.
#   4. If NOT found AND the algorithmic key would collide with an existing
#      DB row under a different display name: writes to
#      jsons/pending_review.jsonl and logs a WARNING. Ingest continues.
#
# To resolve pending items: run python -m data_upload.review_colorways
# from sneaker-scout-backend/.

sneakers:
  "9060":  # sneaker_lookup_key("New Balance 9060", "New Balance") == "9060"
    colorways:
      "Black":
        # Platypus plain black — no SKU code suffix.
        aliases:
          - "BLACK"
          - "Black"
      "Black (000)":
        # Platypus black with (000) suffix — distinct colorway from plain Black.
        aliases:
          - "BLACK (000)"
          - "Black (000)"
        lookup_key_override: "black000"
      "Black (001)":
        # Hype DC black with (001) suffix — third distinct black on the 9060.
        aliases:
          - "Black (001)"
          - "BLACK (001)"
        lookup_key_override: "black001"
```

- [ ] **Step 3: Verify the YAML file parses cleanly**

```bash
cd /workspace/sneaker-scout-backend
python -c "
import yaml, pathlib
data = yaml.safe_load(pathlib.Path('data_upload/colorway_overrides.yaml').read_text())
sneakers = data.get('sneakers', {})
print('Loaded', len(sneakers), 'sneaker entries:', list(sneakers.keys()))
nb9060 = sneakers.get('9060', {}).get('colorways', {})
print('NB 9060 colorways:', list(nb9060.keys()))
"
```

Expected output:
```
Loaded 1 sneaker entries: ['9060']
NB 9060 colorways: ['Black', 'Black (000)', 'Black (001)']
```

- [ ] **Step 4: Gitignore the pending review file**

Open `sneaker-scout-backend/.gitignore` and append:

```
# Runtime-generated colorway collision queue. Reviewed via:
#   python -m data_upload.review_colorways
jsons/pending_review.jsonl
```

- [ ] **Step 5: Commit**

```bash
git -C /workspace/sneaker-scout-backend add requirements.txt data_upload/colorway_overrides.yaml .gitignore
git -C /workspace/sneaker-scout-backend commit -m "chore(sneaker_scout-kzc): add pyyaml, YAML registry scaffold, gitignore pending"
```

---

## Task 2: `colorway_overrides.py` module (TDD)

**Files:**
- Create: `sneaker-scout-backend/data_upload/colorway_overrides.py`
- Modify: `sneaker-scout-backend/tests/test_canonicalize.py`

### Sub-cycle 2.1 — stub + smoke test

- [ ] **Step 1: Create the stub module**

Create `sneaker-scout-backend/data_upload/colorway_overrides.py`:

```python
"""Human-reviewed colorway override registry.

Consulted by update_supabase_daily.py before applying
colorway_lookup_key() to catch cases where the algorithm collapses
two genuinely different colorways (e.g. NB 9060 'Black' vs
'Black (000)'). See sneaker_scout-kzc.

Usage:
    registry = ColorwayRegistry.load()
    result = registry.lookup(sneaker_key="9060", scraped_name="BLACK (000)")
    if result:
        colorway_display = result.canonical_name
        colorway_lookup = result.lookup_key_override or colorway_lookup_key(colorway_display)
"""
from __future__ import annotations

import pathlib
from dataclasses import dataclass
from typing import Optional

import yaml

_REGISTRY_PATH = pathlib.Path(__file__).parent / "colorway_overrides.yaml"


@dataclass(frozen=True)
class OverrideResult:
    canonical_name: str
    lookup_key_override: Optional[str]  # None means: use algorithmic key


class ColorwayRegistry:
    def __init__(self, data: dict) -> None:
        self._sneakers: dict = data.get("sneakers") or {}

    @classmethod
    def load(cls, path: pathlib.Path = _REGISTRY_PATH) -> "ColorwayRegistry":
        raise NotImplementedError

    def lookup(self, sneaker_key: str, scraped_name: str) -> Optional[OverrideResult]:
        raise NotImplementedError

    def has_sneaker(self, sneaker_key: str) -> bool:
        raise NotImplementedError
```

- [ ] **Step 2: Add smoke tests to `tests/test_canonicalize.py`**

Append at the end of the file (after the last test):

```python
# ---------------------------------------------------------------------------
# colorway_overrides.ColorwayRegistry — sneaker_scout-kzc
# ---------------------------------------------------------------------------

from data_upload.colorway_overrides import ColorwayRegistry, OverrideResult


def test_colorway_registry_is_importable():
    assert callable(ColorwayRegistry.load)


def test_override_result_is_importable():
    assert OverrideResult  # dataclass, not callable via ()
```

- [ ] **Step 3: Run tests — expect 40 old pass + 2 new pass (smoke tests don't call NotImplementedError)**

```bash
cd /workspace/sneaker-scout-backend
python -m pytest tests/test_canonicalize.py -v -k "registry_is_importable or override_result"
```

Expected: 2 tests PASS.

- [ ] **Step 4: Commit stub**

```bash
git -C /workspace/sneaker-scout-backend add data_upload/colorway_overrides.py tests/test_canonicalize.py
git -C /workspace/sneaker-scout-backend commit -m "chore(sneaker_scout-kzc): scaffold ColorwayRegistry stub"
```

### Sub-cycle 2.2 — `load()` from disk

- [ ] **Step 1: Add failing tests**

Append to `tests/test_canonicalize.py`:

```python
def test_colorway_registry_load_reads_yaml():
    # The production YAML must be loadable without raising.
    registry = ColorwayRegistry.load()
    assert isinstance(registry, ColorwayRegistry)


def test_colorway_registry_load_missing_file_returns_empty():
    import pathlib, tempfile, os
    registry = ColorwayRegistry.load(path=pathlib.Path("/tmp/nonexistent_kzc.yaml"))
    assert isinstance(registry, ColorwayRegistry)
    assert not registry.has_sneaker("9060")
```

- [ ] **Step 2: Run, verify red**

```bash
python -m pytest tests/test_canonicalize.py -v -k "load_reads_yaml or load_missing"
```

Expected: 2 FAIL with `NotImplementedError`.

- [ ] **Step 3: Implement `load()` and `has_sneaker()`**

Replace both stubs in `colorway_overrides.py`:

```python
    @classmethod
    def load(cls, path: pathlib.Path = _REGISTRY_PATH) -> "ColorwayRegistry":
        if not path.exists():
            return cls({})
        with path.open() as f:
            data = yaml.safe_load(f) or {}
        return cls(data)

    def has_sneaker(self, sneaker_key: str) -> bool:
        return sneaker_key in self._sneakers
```

- [ ] **Step 4: Run, verify green**

```bash
python -m pytest tests/test_canonicalize.py -v -k "load"
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C /workspace/sneaker-scout-backend add data_upload/colorway_overrides.py tests/test_canonicalize.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-kzc): implement ColorwayRegistry.load()"
```

### Sub-cycle 2.3 — `lookup()` — hit and miss

- [ ] **Step 1: Add failing tests**

Append to `tests/test_canonicalize.py`:

```python
def test_colorway_registry_lookup_returns_none_for_unknown_sneaker():
    registry = ColorwayRegistry.load()
    result = registry.lookup(sneaker_key="nonexistent_shoe_xyz", scraped_name="Black")
    assert result is None


def test_colorway_registry_lookup_returns_none_for_unknown_alias():
    # 9060 is in the registry but "Chartreuse" is not an alias for any entry.
    registry = ColorwayRegistry.load()
    result = registry.lookup(sneaker_key="9060", scraped_name="Chartreuse")
    assert result is None


def test_colorway_registry_lookup_finds_alias_no_override():
    # Platypus plain "BLACK" -> canonical "Black", no lookup_key_override.
    registry = ColorwayRegistry.load()
    result = registry.lookup(sneaker_key="9060", scraped_name="BLACK")
    assert result is not None
    assert result.canonical_name == "Black"
    assert result.lookup_key_override is None


def test_colorway_registry_lookup_finds_alias_with_override():
    # Platypus "BLACK (000)" -> canonical "Black (000)", override key "black000".
    registry = ColorwayRegistry.load()
    result = registry.lookup(sneaker_key="9060", scraped_name="BLACK (000)")
    assert result is not None
    assert result.canonical_name == "Black (000)"
    assert result.lookup_key_override == "black000"


def test_colorway_registry_lookup_second_override():
    # Hype DC "Black (001)" -> canonical "Black (001)", override key "black001".
    registry = ColorwayRegistry.load()
    result = registry.lookup(sneaker_key="9060", scraped_name="Black (001)")
    assert result is not None
    assert result.canonical_name == "Black (001)"
    assert result.lookup_key_override == "black001"
```

- [ ] **Step 2: Run, verify red**

```bash
python -m pytest tests/test_canonicalize.py -v -k "lookup"
```

Expected: all FAIL with `NotImplementedError`.

- [ ] **Step 3: Implement `lookup()`**

Replace the `lookup` stub in `colorway_overrides.py`:

```python
    def lookup(self, sneaker_key: str, scraped_name: str) -> Optional[OverrideResult]:
        """Return canonical name + optional key override for scraped_name, or None.

        Returns None if:
        - this sneaker_key has no registry entry, OR
        - scraped_name is not listed in any aliases list for this sneaker.

        Caller should fall back to colorway_lookup_key(scraped_name) when None.
        """
        sneaker_entry = self._sneakers.get(sneaker_key)
        if not sneaker_entry:
            return None
        colorways = sneaker_entry.get("colorways") or {}
        for canonical_name, cw_data in colorways.items():
            aliases = cw_data.get("aliases") or []
            if scraped_name in aliases:
                override_key = cw_data.get("lookup_key_override")
                return OverrideResult(
                    canonical_name=canonical_name,
                    lookup_key_override=override_key,
                )
        return None
```

- [ ] **Step 4: Run, verify green**

```bash
python -m pytest tests/test_canonicalize.py -v -k "lookup"
```

Expected: all PASS.

- [ ] **Step 5: Run all tests**

```bash
python -m pytest tests/test_canonicalize.py -v
```

Expected: all 47 tests pass (40 old + 7 new).

- [ ] **Step 6: Commit**

```bash
git -C /workspace/sneaker-scout-backend add data_upload/colorway_overrides.py tests/test_canonicalize.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-kzc): implement ColorwayRegistry.lookup()"
```

### Sub-cycle 2.4 — key collision demonstrates the problem

- [ ] **Step 1: Add a regression test that documents the NB 9060 collision**

Append to `tests/test_canonicalize.py`:

```python
def test_nb9060_three_black_colorways_get_distinct_keys():
    # Root cause: all three NB 9060 black variants collapse to "black"
    # algorithmically. The registry must give them distinct keys.
    from data_upload.canonicalize import colorway_lookup_key

    registry = ColorwayRegistry.load()
    scraped = {
        "BLACK":        "black",   # algorithmic baseline (no override)
        "BLACK (000)":  "black",   # algorithmic — SAME as above = collision
        "Black (001)":  "black",   # algorithmic — SAME = collision
    }
    # Verify the algorithm alone produces collisions:
    for name, expected_algo_key in scraped.items():
        assert colorway_lookup_key(name) == expected_algo_key, (
            f"algorithm changed for {name!r}"
        )

    # Now verify the registry gives them distinct effective keys:
    def effective_key(scraped_name: str) -> str:
        result = registry.lookup("9060", scraped_name)
        if result and result.lookup_key_override:
            return result.lookup_key_override
        return colorway_lookup_key(scraped_name)

    black_key   = effective_key("BLACK")
    black000_key = effective_key("BLACK (000)")
    black001_key = effective_key("Black (001)")

    assert black_key   == "black",    f"plain Black key changed: {black_key!r}"
    assert black000_key == "black000", f"Black (000) key wrong: {black000_key!r}"
    assert black001_key == "black001", f"Black (001) key wrong: {black001_key!r}"
    assert len({black_key, black000_key, black001_key}) == 3, (
        "three distinct colorways must have three distinct effective keys"
    )
```

- [ ] **Step 2: Run, verify green (no code change needed)**

```bash
python -m pytest tests/test_canonicalize.py::test_nb9060_three_black_colorways_get_distinct_keys -v
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git -C /workspace/sneaker-scout-backend add tests/test_canonicalize.py
git -C /workspace/sneaker-scout-backend commit -m "test(sneaker_scout-kzc): lock NB 9060 three-black collision fix"
```

---

## Task 3: Wire registry into `update_supabase_daily.py`

**Files:**
- Modify: `sneaker-scout-backend/data_upload/update_supabase_daily.py`
- Modify: `sneaker-scout-backend/tests/test_canonicalize.py`

The colorway-upsert block is at lines 217–253 in the current file. We replace it with a block that:
1. Loads the registry once at module level (not per-item).
2. Consults the registry before computing `colorway_lookup`.
3. On an unrecognised collision, writes to `jsons/pending_review.jsonl`.

### Step-by-step

- [ ] **Step 1: Add the module-level registry and `_write_pending_review` helper**

Open `update_supabase_daily.py`. After the existing imports (around line 14, after the `.canonicalize` import), add:

```python
from .colorway_overrides import ColorwayRegistry

# Loaded once at module import; file is read-only during a run.
_colorway_registry = ColorwayRegistry.load()
```

Then, after the `decimal_to_float` helper function (around line 107), add this new helper:

```python
import datetime as _dt

def _write_pending_review(
    sneaker_key: str,
    sneaker_display: str,
    scraped_colorway: str,
    computed_lookup_key: str,
    colliding_existing_name: str,
    retailer: str,
) -> None:
    """Append one pending-review record to jsons/pending_review.jsonl."""
    import json as _json
    record = {
        "sneaker_key": sneaker_key,
        "sneaker_display": sneaker_display,
        "scraped_colorway": scraped_colorway,
        "computed_lookup_key": computed_lookup_key,
        "colliding_existing_name": colliding_existing_name,
        "retailer": retailer,
        "timestamp": _dt.datetime.now(tz=_dt.timezone.utc).isoformat(),
    }
    path = "jsons/pending_review.jsonl"
    with open(path, "a") as f:
        f.write(_json.dumps(record) + "\n")
    logger.warning(
        "PENDING REVIEW: colorway %r (sneaker=%r, retailer=%r) would collide "
        "with existing %r under key %r. Written to %s. "
        "Run: python -m data_upload.review_colorways",
        scraped_colorway, sneaker_display, retailer,
        colliding_existing_name, computed_lookup_key, path,
    )
```

Note: `import json as _json` is inside the function to avoid shadowing the module-level `json` import that already exists at line 2.

- [ ] **Step 2: Replace the colorway-upsert block**

Find this exact block (lines 222–253):

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

Replace it with:

```python
            # 3. Resolve colorway display name and lookup key.
            # Consult the human-reviewed override registry first
            # (data_upload/colorway_overrides.yaml). If the scraped
            # name is a known alias, use the canonical name and any
            # lookup_key_override to avoid false algorithmic collisions
            # (e.g. NB 9060 "Black" vs "Black (000)" vs "Black (001)"
            # all hash to "black" algorithmically). See sneaker_scout-kzc.
            override = _colorway_registry.lookup(
                sneaker_key=lookup_key,  # sneaker's lookup_key, set at line ~176
                scraped_name=colorway_name,
            )
            if override:
                colorway_display = override.canonical_name
                colorway_lookup = (
                    override.lookup_key_override
                    or colorway_lookup_key(colorway_display)
                )
                logger.info(
                    f"Registry override: {colorway_name!r} -> "
                    f"{colorway_display!r} (lookup_key={colorway_lookup!r})"
                )
            else:
                colorway_display = colorway_name
                colorway_lookup = colorway_lookup_key(colorway_name)

            colorway_response = supabase.table("colorways").select(
                "id, name, image_url"
            ).eq("lookup_key", colorway_lookup).eq("sneaker_id", sneaker_id).execute()

            if not colorway_response.data:
                colorway_response = supabase.table("colorways").insert({
                    "sneaker_id": sneaker_id,
                    "name": colorway_display,
                    "lookup_key": colorway_lookup,
                    "image_url": colorway_image,
                }).execute()
                logger.info(
                    f"Inserted colorway: {colorway_display!r} "
                    f"(lookup_key={colorway_lookup!r})"
                )
            else:
                existing = colorway_response.data[0]
                # Detect unrecognised collisions: the algorithmic key matched
                # an existing row whose display name differs from the scraped
                # name, and this scraped name is NOT in any alias list. Queue
                # for human review via jsons/pending_review.jsonl.
                if existing["name"] != colorway_display and override is None:
                    _write_pending_review(
                        sneaker_key=lookup_key,
                        sneaker_display=sneaker_data["name"],
                        scraped_colorway=colorway_name,
                        computed_lookup_key=colorway_lookup,
                        colliding_existing_name=existing["name"],
                        retailer=retailer_data.get("name", "unknown"),
                    )
                logger.info(
                    f"Matched colorway: {colorway_display!r} -> existing "
                    f"row {existing['name']!r} (lookup_key={colorway_lookup!r}); "
                    f"first-write-wins, no update applied"
                )

            colorway_id = colorway_response.data[0]["id"]
```

**Important:** The `retailer_data` reference here is safe because `retailer_data = item["retailer"]` is assigned just after this block at line ~262 in the current code. Check that `retailer_data` is defined **before** the colorway block in the file — if not, move the retailer extraction before the colorway block, or pass `item["retailer"].get("name", "unknown")` inline.

Actually, looking at the current file structure, `retailer_data` is defined AFTER the colorway block (around line 262). Use `item.get("retailer", {}).get("name", "unknown")` inline in `_write_pending_review` to avoid this ordering dependency.

Update the `_write_pending_review` call accordingly:

```python
                    _write_pending_review(
                        sneaker_key=lookup_key,
                        sneaker_display=sneaker_data["name"],
                        scraped_colorway=colorway_name,
                        computed_lookup_key=colorway_lookup,
                        colliding_existing_name=existing["name"],
                        retailer=item.get("retailer", {}).get("name", "unknown"),
                    )
```

- [ ] **Step 3: Add import guard test**

Append to `tests/test_canonicalize.py`:

```python
def test_update_supabase_daily_imports_colorway_registry():
    from data_upload import update_supabase_daily
    assert hasattr(update_supabase_daily, "_colorway_registry")
    from data_upload.colorway_overrides import ColorwayRegistry
    assert isinstance(update_supabase_daily._colorway_registry, ColorwayRegistry)
```

- [ ] **Step 4: Run all tests**

```bash
cd /workspace/sneaker-scout-backend
python -m pytest tests/test_canonicalize.py -v
```

Expected: all 49 tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /workspace/sneaker-scout-backend add data_upload/update_supabase_daily.py data_upload/colorway_overrides.py tests/test_canonicalize.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-kzc): wire registry into colorway upsert, write pending_review on unrecognised collision"
```

---

## Task 4: Interactive review CLI

**Files:**
- Create: `sneaker-scout-backend/data_upload/review_colorways.py`

No automated tests for the interactive CLI (it prompts stdin). Manual test by running it against a synthetic `pending_review.jsonl`.

- [ ] **Step 1: Create `data_upload/review_colorways.py`**

```python
"""Interactive review tool for colorway collision pending items.

Reads jsons/pending_review.jsonl (written by update_supabase_daily.py when
it detects a colorway that would collide algorithmically but isn't in the
override registry). Prompts for each item:

  s = same     → add scraped name to the existing colorway's aliases list
  d = different → create a new registry entry with a disambiguating key
  x = skip     → leave in pending for later

After review, clears the items that were resolved from pending_review.jsonl
and saves changes to data_upload/colorway_overrides.yaml.

Usage (from sneaker-scout-backend/):
    python -m data_upload.review_colorways
"""
from __future__ import annotations

import json
import pathlib
import sys
from typing import Any

import yaml

_REGISTRY_PATH = pathlib.Path(__file__).parent / "colorway_overrides.yaml"
_PENDING_PATH = pathlib.Path("jsons/pending_review.jsonl")


def _load_registry() -> dict:
    if not _REGISTRY_PATH.exists():
        return {"sneakers": {}}
    data = yaml.safe_load(_REGISTRY_PATH.read_text()) or {}
    if "sneakers" not in data:
        data["sneakers"] = {}
    return data


def _save_registry(data: dict) -> None:
    _REGISTRY_PATH.write_text(
        yaml.dump(data, default_flow_style=False, allow_unicode=True, sort_keys=False)
    )


def _load_pending() -> list[dict]:
    if not _PENDING_PATH.exists():
        return []
    lines = _PENDING_PATH.read_text().strip().splitlines()
    return [json.loads(line) for line in lines if line.strip()]


def _save_pending(items: list[dict]) -> None:
    if not items:
        _PENDING_PATH.write_text("")
        return
    _PENDING_PATH.write_text("\n".join(json.dumps(r) for r in items) + "\n")


def _ensure_sneaker_entry(registry: dict, sneaker_key: str) -> dict:
    sneakers = registry.setdefault("sneakers", {})
    if sneaker_key not in sneakers:
        sneakers[sneaker_key] = {"colorways": {}}
    if "colorways" not in sneakers[sneaker_key]:
        sneakers[sneaker_key]["colorways"] = {}
    return sneakers[sneaker_key]["colorways"]


def _find_entry_for_existing_name(
    colorways: dict, existing_name: str
) -> tuple[str, dict] | None:
    """Find the registry entry whose canonical_name matches existing_name."""
    for canon, cw_data in colorways.items():
        if canon == existing_name:
            return canon, cw_data
    return None


def _prompt_suffix(scraped: str, computed_key: str) -> str:
    """Prompt for the lookup_key suffix to disambiguate a 'different' decision."""
    # Try to auto-detect from trailing parens code: 'Black (001)' → '001'
    import re
    m = re.search(r"\((\w+)\)\s*$", scraped)
    auto = m.group(1).lower() if m else None
    suggestion = f"{computed_key}_{auto}" if auto else f"{computed_key}_2"
    raw = input(
        f"  Lookup key override for {scraped!r} (Enter for {suggestion!r}): "
    ).strip()
    return raw if raw else suggestion


def main() -> int:
    pending = _load_pending()
    if not pending:
        print("No pending items in jsons/pending_review.jsonl. Nothing to review.")
        return 0

    registry = _load_registry()
    resolved = []
    skipped = []

    for i, item in enumerate(pending, 1):
        sneaker_key = item["sneaker_key"]
        sneaker_display = item["sneaker_display"]
        scraped = item["scraped_colorway"]
        computed_key = item["computed_lookup_key"]
        existing_name = item["colliding_existing_name"]
        retailer = item.get("retailer", "unknown")

        print(f"\n[{i}/{len(pending)}] Sneaker: {sneaker_display!r} (key={sneaker_key!r})")
        print(f"  Retailer:       {retailer!r}")
        print(f"  Scraped:        {scraped!r}")
        print(f"  Algo key:       {computed_key!r}")
        print(f"  Collides with:  {existing_name!r}")
        print("  Choose: [s]ame (alias)  [d]ifferent (new entry)  [x] skip")

        while True:
            choice = input("  > ").strip().lower()
            if choice in ("s", "d", "x"):
                break
            print("  Please enter s, d, or x")

        if choice == "x":
            skipped.append(item)
            print("  Skipped.")
            continue

        colorways = _ensure_sneaker_entry(registry, sneaker_key)

        if choice == "s":
            # Add scraped name to the existing entry's aliases.
            entry = _find_entry_for_existing_name(colorways, existing_name)
            if entry:
                canon, cw_data = entry
                aliases = cw_data.setdefault("aliases", [])
                if scraped not in aliases:
                    aliases.append(scraped)
                    print(f"  Added {scraped!r} to aliases of {canon!r}.")
                else:
                    print(f"  {scraped!r} already in aliases of {canon!r}.")
            else:
                # Existing name not yet in registry — create it with both names.
                colorways[existing_name] = {"aliases": [existing_name, scraped]}
                print(
                    f"  Created entry {existing_name!r} with aliases "
                    f"[{existing_name!r}, {scraped!r}]."
                )

        elif choice == "d":
            # Create a new entry for scraped name with a disambiguating key.
            override_key = _prompt_suffix(scraped, computed_key)
            colorways[scraped] = {
                "aliases": [scraped],
                "lookup_key_override": override_key,
            }
            print(
                f"  Created new entry {scraped!r} "
                f"(lookup_key_override={override_key!r})."
            )

        resolved.append(item)

    _save_registry(registry)
    _save_pending(skipped)

    print(
        f"\nDone. Resolved {len(resolved)}, skipped {len(skipped)}. "
        f"Registry saved to {_REGISTRY_PATH}."
    )
    if skipped:
        print(f"  {len(skipped)} item(s) remain in {_PENDING_PATH}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Manual smoke test with a synthetic pending file**

```bash
cd /workspace/sneaker-scout-backend
mkdir -p jsons
cat > jsons/pending_review.jsonl << 'EOF'
{"sneaker_key": "9060", "sneaker_display": "New Balance 9060", "scraped_colorway": "GREY (020)", "computed_lookup_key": "grey", "colliding_existing_name": "Grey", "retailer": "Platypus", "timestamp": "2026-05-17T10:00:00Z"}
EOF
python -m data_upload.review_colorways
```

At the prompt, enter `d` then accept the suggested override key (should be `grey_020`). Verify:

```bash
python -c "
import yaml, pathlib
data = yaml.safe_load(pathlib.Path('data_upload/colorway_overrides.yaml').read_text())
nb9060 = data['sneakers'].get('9060', {}).get('colorways', {})
print('9060 colorways:', list(nb9060.keys()))
grey020 = nb9060.get('GREY (020)')
print('GREY (020) entry:', grey020)
"
```

Expected: the 9060 colorways list now includes `"GREY (020)"` with `lookup_key_override: grey_020`. Then verify pending is cleared:

```bash
cat jsons/pending_review.jsonl
# Should be empty or absent
```

- [ ] **Step 3: Restore YAML to known-good state after the smoke test**

The smoke test added a `GREY (020)` entry. Remove it so only the three original entries remain:

```bash
python -c "
import yaml, pathlib
path = pathlib.Path('data_upload/colorway_overrides.yaml')
data = yaml.safe_load(path.read_text())
nb9060_cw = data['sneakers']['9060']['colorways']
nb9060_cw.pop('GREY (020)', None)
path.write_text(yaml.dump(data, default_flow_style=False, allow_unicode=True, sort_keys=False))
print('Cleaned. Remaining:', list(nb9060_cw.keys()))
"
```

Expected: `Remaining: ['Black', 'Black (000)', 'Black (001)']`

- [ ] **Step 4: Run all tests to confirm nothing broke**

```bash
python -m pytest tests/test_canonicalize.py -v
```

Expected: all 49 tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /workspace/sneaker-scout-backend add data_upload/review_colorways.py data_upload/colorway_overrides.yaml
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-kzc): add interactive review_colorways CLI"
```

---

## Task 5: Dry-run sanity check against real JSONs

**Files:** none (read-only verification).

This task verifies that the NB 9060 collision is resolved by running the algorithm + registry lookup against the existing JSON snapshots.

- [ ] **Step 1: Run the dry-run script**

```bash
cd /workspace/sneaker-scout-backend
python -c "
import json, pathlib
from data_upload.canonicalize import colorway_lookup_key, sneaker_lookup_key, canonicalize_brand
from data_upload.colorway_overrides import ColorwayRegistry

registry = ColorwayRegistry.load()

collisions = {}   # (sneaker_key, effective_key) -> list of scraped names

for p in pathlib.Path('jsons').glob('*_products.json'):
    items = json.load(open(p))
    for item in items:
        raw_brand = item.get('brand', {}).get('name')
        raw_sneaker = item.get('sneaker', {}).get('name')
        raw_colorway = (
            item.get('colorway', {}).get('name')
            or item.get('colorway', {}).get('colorway_name')
        )
        if not raw_brand or not raw_sneaker or not raw_colorway:
            continue
        cb = canonicalize_brand(raw_brand)
        sk = sneaker_lookup_key(raw_sneaker, cb)

        override = registry.lookup(sneaker_key=sk, scraped_name=raw_colorway)
        if override:
            eff_key = override.lookup_key_override or colorway_lookup_key(override.canonical_name)
        else:
            eff_key = colorway_lookup_key(raw_colorway)

        bucket = (sk, eff_key)
        collisions.setdefault(bucket, set()).add(raw_colorway)

print()
print('=== Effective-key groups (** = more than one scraped name) ===')
any_collision = False
for (sk, eff_key), names in sorted(collisions.items()):
    marker = '** ' if len(names) > 1 else '   '
    if len(names) > 1:
        any_collision = True
    print(f'{marker}sneaker={sk!r:15} key={eff_key!r:20} <- {sorted(names)}')

if not any_collision:
    print()
    print('No unresolved collisions in the JSON snapshots.')
"
```

- [ ] **Step 2: Confirm NB 9060 black colorways are no longer colliding**

Look for lines with `sneaker='9060'`. There should be **three separate entries** with keys `black`, `black000`, `black001` — each with exactly one name in the `<-` list.

If they still collide (all three under `key='black'`), the registry wiring in Task 3 is not working. Re-check Step 2 of Task 3.

- [ ] **Step 3: Investigate any remaining `**` lines**

For each `**` line that appears, decide: is this a legitimate cross-retailer normalisation (desired — same colorway, same key) or a genuine collision (different colorways sharing a key)?

- Legitimate: `key='blackblackftwsilver'` ← `['Black/Black/FTW Silver', 'black/black/ftwsilver']` — same colorway, different capitalisation. Fine, first-write-wins handles it.
- Collision: `key='black'` ← `['Black', 'BLACK (000)']` under the same sneaker_key — different colorways. Add the new sneaker to `colorway_overrides.yaml` and re-run.

No commit for this task — it's read-only validation.

---

## Task 6: Close issue and recap commit

**Files:** git + bd operations.

- [ ] **Step 1: Run full test suite one final time**

```bash
cd /workspace/sneaker-scout-backend
python -m pytest tests/test_canonicalize.py -v
```

Expected: all 49 tests pass.

- [ ] **Step 2: Status check**

```bash
git -C /workspace/sneaker-scout-backend status --short
```

All kzc work should be committed; only pre-existing dirty state (if any) should show.

- [ ] **Step 3: Close the bd issue**

```bash
bd close sneaker_scout-kzc --reason="ColorwayRegistry loads colorway_overrides.yaml; lookup() returns OverrideResult(canonical_name, lookup_key_override) for known aliases. update_supabase_daily.py consults registry before colorway upsert, writes pending_review.jsonl on unrecognised collision. NB 9060 three-black collision (black/black000/black001) resolved in initial YAML. review_colorways.py CLI processes pending items interactively."
```

- [ ] **Step 4: Beads state commit in /workspace**

```bash
cd /workspace
git add .beads/.bv.lock .beads/export-state.json .beads/interactions.jsonl .beads/issues.jsonl
git commit -m "$(cat <<'EOF'
feat(sneaker_scout-kzc): colorway override registry with human-in-the-loop review

Algorithmic colorway_lookup_key() strips trailing parens codes which is
correct for most Platypus SKU metadata but breaks when those codes
distinguish genuinely different colorways. NB 9060 'Black', 'Black (000)',
and 'Black (001)' all hashed to 'black' and the second two silently merged
into the first DB row.

Added a human-reviewed YAML registry (data_upload/colorway_overrides.yaml)
that maps per-sneaker scraped colorway name aliases to a canonical display
name and optional lookup_key_override. Initial entries: NB 9060 three-way
black disambiguation (plain Black=black, Black (000)=black000, Black
(001)=black001).

Python module data_upload/colorway_overrides.py exposes ColorwayRegistry
with load() and lookup(sneaker_key, scraped_name). update_supabase_daily.py
consults the registry before the colorway upsert: override wins if found,
otherwise algorithmic key is used. Unrecognised collisions (same algorithmic
key, different display name, not in registry) are written to
jsons/pending_review.jsonl with a WARNING log — ingest does not block.

Interactive CLI data_upload/review_colorways.py processes pending items
one-by-one: s=same (adds alias), d=different (creates new override entry
with disambiguating lookup_key_override suffix), x=skip. Writes decisions
back to colorway_overrides.yaml.

Closes: sneaker_scout-kzc
EOF
)"
```

---

## Self-Review

### Spec coverage

| Requirement | Covered by |
|---|---|
| Version-controlled YAML registry | Task 1 (colorway_overrides.yaml) |
| Per-sneaker alias lists | Task 1 (YAML schema) + Task 2 (lookup()) |
| `lookup_key_override` for disambiguation | Task 1 YAML + Task 2 OverrideResult |
| Ingest consults registry before algorithm | Task 3 Step 2 (update_supabase_daily.py) |
| NB 9060 three-way black collision fixed | Task 1 YAML + Task 2 Sub-cycle 2.4 test |
| Unknown collision → pending_review.jsonl + WARNING | Task 3 Step 2 (_write_pending_review) |
| Ingest does not block on pending items | Task 3 (continues with existing match) |
| Interactive review CLI | Task 4 |
| s=same adds alias to YAML | Task 4 (_choice == "s" branch) |
| d=different creates new entry with override key | Task 4 (_choice == "d" branch) |
| Pending file cleared after review | Task 4 (_save_pending with resolved items removed) |
| jsons/pending_review.jsonl gitignored | Task 1 Step 4 |
| pyyaml added to requirements.txt | Task 1 Step 1 |

### Placeholder scan

All code steps contain actual code. No "TBD", "similar to Task N", or "add validation" patterns.

### Type consistency

- `ColorwayRegistry.lookup(sneaker_key: str, scraped_name: str) -> Optional[OverrideResult]` — consistent across Task 2 tests and Task 3 integration.
- `OverrideResult.canonical_name: str`, `OverrideResult.lookup_key_override: Optional[str]` — consistent across Task 2 (definition) and Task 3 (usage: `override.canonical_name`, `override.lookup_key_override`).
- `lookup_key` = sneaker key, `colorway_lookup` = colorway key — naming preserved from existing code.

### Things to flag at execution time

1. **`retailer_data` ordering**: The original code defines `retailer_data = item["retailer"]` AFTER the colorway block. Task 3 uses `item.get("retailer", {}).get("name", "unknown")` inline to avoid a `NameError` — verify this is correct at execution time by reading the exact line numbers around the replacement.

2. **`_write_pending_review` uses `import json as _json`** inside the function body because `json` is already imported at module level (line 2). Double-check no name shadowing occurs.

3. **YAML dump key ordering**: `yaml.dump(..., sort_keys=False)` is essential to preserve the human-authored ordering in the YAML. If the review CLI saves with `sort_keys=True` (default), the file order may surprise the human editor. Task 4 uses `sort_keys=False`.

4. **`jsons/` directory must exist** when `_write_pending_review` appends to `jsons/pending_review.jsonl`. The directory already exists (it holds the scraped JSON files), so no `os.makedirs` needed. If running in a fresh checkout with no `jsons/` yet, add `os.makedirs("jsons", exist_ok=True)` to `_write_pending_review`.
