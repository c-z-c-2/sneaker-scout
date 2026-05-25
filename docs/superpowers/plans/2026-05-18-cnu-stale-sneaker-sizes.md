# cnu: Delete stale sneaker_sizes when a size disappears from a retailer PDP — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a retailer stops stocking a size between scrapes, the existing `sneaker_sizes` row (still claiming `is_available=True`) is no longer left behind to feed the frontend filter false positives.

**Architecture:** The current `sneaker_sizes` upsert is *additive* — it only writes the (colorway, retailer, size) combinations present in the current scrape payload. A row from yesterday's scrape that's no longer in today's payload is untouched. The fix: before each upsert, DELETE all `sneaker_sizes` rows for the `(colorway_id, retailer_id)` pairs in scope so the new payload becomes ground truth. One scoped DELETE per file in the bulk path, one scoped DELETE per colorway in the legacy per-row path. Both writes go through the existing `supabase.table(...).delete().eq(...).execute()` pattern; no new helpers.

**Tech Stack:** Python 3.11, supabase-py 2.x, pytest.

---

## Reference

- Beads issue: `sneaker_scout-cnu`
- Existing xfail test: `sneaker-scout-backend/tests/test_bulk_upload.py:471` (`test_size_management_relationships_drops_stale_sizes` — marked `strict=True`, so the fix flipping it green will require un-marking)
- Affected code paths:
  - **Default (bulk)** — `sneaker-scout-backend/data_upload/bulk_upload.py:321-338` (sneaker_sizes upsert block)
  - **Legacy `--per-row`** — `sneaker-scout-backend/data_upload/update_supabase_daily.py:398-444` (per-product size loop)
- Per CLAUDE.md, only the **default** path runs in production. Legacy is behind a `--per-row` CLI flag.

## Why DELETE + upsert beats a "diff and update" approach

The alternative — read existing rows, diff against payload, set `is_available=False` for rows not in the new payload — has the same number of round trips (one read, one write) but is more code, more state, and more failure modes. DELETE + upsert is what Postgres is good at: idempotent, atomic (in the bulk path the DELETE and UPSERT are still two distinct statements, but each is scoped to a `retailer_id` that no other process writes during the upload window, so cross-write conflicts don't exist).

The cost is a small window between DELETE and UPSERT where reads would see no `sneaker_sizes` for the colorway+retailer. Since uploads run on a 6-hour cadence and the frontend tolerates "no sizes" gracefully (the filter just returns nothing for that retailer), this is acceptable. Wrapping the DELETE+UPSERT in a Postgres transaction would close even that window, but supabase-py doesn't expose multi-statement transactions through the REST API. YAGNI.

## File Map

- Modify: `sneaker-scout-backend/data_upload/bulk_upload.py` (sneaker_sizes block ~line 335) — issue scoped DELETE before the upsert
- Modify: `sneaker-scout-backend/data_upload/update_supabase_daily.py` (per-product size loop ~line 397) — issue scoped DELETE per colorway before the size loop
- Modify: `sneaker-scout-backend/tests/test_bulk_upload.py` —
  - Extend `_FakeTable` with `.delete()` to record delete calls
  - Un-mark the `@pytest.mark.xfail` on `test_size_management_relationships_drops_stale_sizes`

---

## Task 1: Fix the bulk path (TDD — un-mark xfail, watch it pass)

**Files:**
- Modify: `sneaker-scout-backend/tests/test_bulk_upload.py` (`_FakeTable` class + xfail mark)
- Modify: `sneaker-scout-backend/data_upload/bulk_upload.py` (sneaker_sizes block ~line 335)

The existing xfail test at `tests/test_bulk_upload.py:471` already encodes the expected behaviour:

```python
delete_calls = [c for c in sb.calls if c[1] == "delete"]
sneaker_size_upserts = [c for c in sb.calls if c[0] == "sneaker_sizes" and c[1] == "upsert"]
stale_neutralized = (
    len(delete_calls) > 0
    or any(
        r.get("size_id") == "pre-existing-size-8"
        and r.get("is_available") is False
        for upsert in sneaker_size_upserts
        for r in upsert[2]
    )
)
assert stale_neutralized, ...
```

Our fix will satisfy the **first** clause (`len(delete_calls) > 0`). For that to work, the fake supabase client needs to record `.delete()` invocations.

- [ ] **Step 1: Extend `_FakeTable` to record `.delete()` calls**

In `sneaker-scout-backend/tests/test_bulk_upload.py`, inside the `_FakeTable` class (currently lines 224–263), add a `delete` method between `insert` and `select`. The full new method:

```python
    def delete(self) -> "_FakeTable":
        self._sb.calls.append((self._name, "delete", None))
        return self
```

Rationale: the xfail test only checks `c[1] == "delete"` — it doesn't inspect filters — so recording at `.delete()` invocation time (rather than at `.execute()`) is sufficient and matches the existing pattern of `.upsert()`/`.insert()` which also record on call. The chained `.eq()` / `.in_()` / `.execute()` calls return `self` and `_FakeResult([])` respectively — already implemented.

- [ ] **Step 2: Un-mark the xfail**

In the same file at lines 471–474, **delete** the decorator block:

```python
@pytest.mark.xfail(
    reason="blocked on sneaker_scout-cnu: stale size-deletion not implemented",
    strict=True,
)
```

Leave the test function definition (`def test_size_management_relationships_drops_stale_sizes():`) and body untouched.

- [ ] **Step 3: Run the test — verify it now fails (no delete issued yet)**

```bash
cd /workspace/sneaker-scout-backend && source .venv/bin/activate
pytest tests/test_bulk_upload.py::test_size_management_relationships_drops_stale_sizes -v
```

Expected output (FAIL):

```
FAILED tests/test_bulk_upload.py::test_size_management_relationships_drops_stale_sizes
  AssertionError: stale sneaker_sizes row was left untouched — see sneaker_scout-cnu
```

This confirms the red state — the un-marked test now correctly fails against the unfixed production code.

- [ ] **Step 4: Implement the DELETE in `bulk_upload.py`**

In `sneaker-scout-backend/data_upload/bulk_upload.py`, find the `sneaker_sizes` block. Currently (lines 321–338):

```python
    ss_payload = []
    for s in plan.sneaker_sizes:
        brand_id = brand_id_by_name[s["brand_lookup"]]
        sneaker_id = sneaker_id_by_key[(brand_id, s["sneaker_lookup_key"])]
        colorway_id = colorway_id_by_key[
            (sneaker_id, s["colorway_lookup_key"])
        ]
        size_id = size_id_by_us[s["us_size"]]
        ss_payload.append({
            "colorway_id": colorway_id,
            "retailer_id": retailer_id,
            "size_id": size_id,
            "is_available": s["is_available"],
        })
    if ss_payload:
        supabase.table("sneaker_sizes").upsert(
            ss_payload, on_conflict="colorway_id,size_id,retailer_id"
        ).execute()
```

Replace the `if ss_payload:` block (the last 4 lines above) with:

```python
    if ss_payload:
        # sneaker_scout-cnu: delete any pre-existing sneaker_sizes for the
        # (colorway, retailer) pairs in this payload so the new scrape becomes
        # ground truth. Without this, a row for a size that the retailer no
        # longer stocks lingers with is_available=True and feeds the frontend
        # size filter false positives.
        colorway_ids_in_scope = sorted({r["colorway_id"] for r in ss_payload})
        supabase.table("sneaker_sizes") \
            .delete() \
            .in_("colorway_id", colorway_ids_in_scope) \
            .eq("retailer_id", retailer_id) \
            .execute()
        supabase.table("sneaker_sizes").upsert(
            ss_payload, on_conflict="colorway_id,size_id,retailer_id"
        ).execute()
```

Notes:
- `retailer_id` is the same for the whole `ss_payload` (uploads are per-file = per-retailer), so a single DELETE scoped by `retailer_id` + `in_("colorway_id", [...])` does the entire purge in one round trip.
- `sorted(...)` on the colorway-id set keeps the call deterministic for any future assertion that wants to compare against a fixed ordering.
- The DELETE only runs when `ss_payload` is non-empty — empty upload = nothing to purge.

- [ ] **Step 5: Run the test — verify it now passes**

```bash
pytest tests/test_bulk_upload.py::test_size_management_relationships_drops_stale_sizes -v
```

Expected output (PASS):

```
PASSED tests/test_bulk_upload.py::test_size_management_relationships_drops_stale_sizes
```

- [ ] **Step 6: Run the full bulk_upload suite — confirm no regressions**

```bash
pytest tests/test_bulk_upload.py -v
```

Expected: all tests pass. The new DELETE call adds one entry to `sb.calls`; the existing `test_bulk_upload_chains_tables_in_dependency_order` and `test_bulk_upload_emits_one_upsert_per_table_not_per_product` test against upsert ordering and upsert-counts only — neither is impacted.

- [ ] **Step 7: Commit**

```bash
git -C /workspace/sneaker-scout-backend add \
  data_upload/bulk_upload.py \
  tests/test_bulk_upload.py
git -C /workspace/sneaker-scout-backend commit -m "fix(sneaker_scout-cnu): bulk uploader deletes stale sneaker_sizes before upsert"
```

---

## Task 2: Apply the analogous fix to the legacy `--per-row` path

**Files:**
- Modify: `sneaker-scout-backend/data_upload/update_supabase_daily.py` (~line 397, right before the size loop)

The legacy uploader processes one product at a time. `colorway_id` is bound earlier in the loop (~line 319). The size loop starts at line 399. The fix slots **once per product** at the boundary between "colorway resolved" and "sizes processed".

No new test — the legacy path has no behavioural test today (only import-smoke tests in `test_canonicalize.py`). Building a stub supabase client comparable to `_FakeSupabase` for the much chattier per-row code path is out of scope; the bug is documented, the default path (bulk) is what runs in production, and Task 1's test confirms the architectural fix.

- [ ] **Step 1: Locate the insertion point**

Open `sneaker-scout-backend/data_upload/update_supabase_daily.py`. Find line 398, which contains the comment `# 7. Insert sizes` immediately followed by `for size_item in item["sizes"]:` on line 399. The DELETE goes **above** that comment.

- [ ] **Step 2: Insert the DELETE**

Above line 398's `# 7. Insert sizes` comment, add:

```python
            # sneaker_scout-cnu: delete pre-existing sneaker_sizes for this
            # (colorway, retailer) pair so the current scrape's sizes become
            # ground truth. Without this, a size no longer stocked stays
            # is_available=True and pollutes the frontend filter.
            supabase.table("sneaker_sizes") \
                .delete() \
                .eq("colorway_id", colorway_id) \
                .eq("retailer_id", retailer_id) \
                .execute()

            # 7. Insert sizes
            for size_item in item["sizes"]:
```

(The existing `# 7. Insert sizes` + `for` loop stay exactly as they were — we're just prepending the DELETE block.)

The indentation must be 12 spaces (inside the `try:` block at the level of `# 7. Insert sizes`). Match the indentation of the surrounding `#` comment exactly.

- [ ] **Step 3: Note that the existing INSERT/UPDATE branching becomes partially dead**

The next block (lines 429–444) does:

```python
sneaker_size_response = supabase.table("sneaker_sizes").select("id").eq(...).execute()
if not sneaker_size_response.data:
    supabase.table("sneaker_sizes").insert({...}).execute()
else:
    sneaker_size_id = sneaker_size_response.data[0]["id"]
    supabase.table("sneaker_sizes").update({...}).eq("id", sneaker_size_id).execute()
```

After our DELETE, `sneaker_size_response.data` will always be empty for the active colorway+retailer pair, so only the `insert` branch fires. The `update` branch is now unreachable. **Leave it in place** — removing it is a separate refactor and the code being defensive isn't harmful. (Document this in the commit message body so the reviewer knows it's intentional.)

- [ ] **Step 4: Smoke import + syntax check**

```bash
cd /workspace/sneaker-scout-backend && source .venv/bin/activate
python -c "from data_upload import update_supabase_daily; print('OK')"
```

Expected: `OK`. Catches any indentation or syntax errors before we commit.

- [ ] **Step 5: Run the canonicalize suite (the only suite that touches this module)**

```bash
pytest tests/test_canonicalize.py -v
```

Expected: all tests pass. These are import-shape tests, so the DELETE addition shouldn't affect any of them.

- [ ] **Step 6: Commit**

```bash
git -C /workspace/sneaker-scout-backend add data_upload/update_supabase_daily.py
git -C /workspace/sneaker-scout-backend commit -m "$(cat <<'EOF'
fix(sneaker_scout-cnu): legacy per-row uploader also deletes stale sneaker_sizes

Mirror Task 1's bulk-path fix in the --per-row legacy path. Issues a
scoped DELETE before each colorway's size loop, so any size that
disappeared from the retailer PDP gets removed instead of lingering
with is_available=True.

The existing INSERT/UPDATE branching at lines ~429-444 becomes
effectively dead — after the DELETE, the SELECT will always return
no rows, so only the INSERT branch fires. Left in place; removing it
is a separate refactor.

No new test — legacy path has no behavioural coverage today; bulk
path's test (flipped from xfail in the previous commit) verifies the
shared architectural fix.

Refs: sneaker_scout-cnu
EOF
)"
```

---

## Task 3: Full suite + close the bead

**Files:** (no edits — verification + bookkeeping)

- [ ] **Step 1: Run the entire backend test suite**

```bash
cd /workspace/sneaker-scout-backend && source .venv/bin/activate
pytest -v --ignore=tests/test_import.py
```

(`--ignore=tests/test_import.py` filters out the pre-existing collection error tracked under `sneaker_scout-jr5`.)

Expected: 137 passed, **0 xfailed** (the cnu xfail has been un-marked; everything else stays green).

If anything new fails, stop and investigate before closing the bead.

- [ ] **Step 2: Close the bead**

```bash
cd /workspace
bd close sneaker_scout-cnu --reason="bulk uploader and legacy per-row path both delete stale sneaker_sizes before upsert; xfail test flipped to passing"
```

- [ ] **Step 3: Commit bd state**

```bash
git -C /workspace add .beads/
git -C /workspace commit -m "chore: bd state for sneaker_scout-cnu close"
```

---

## Risks and rollback

- **DELETE happens but UPSERT fails** — leaves the (colorway, retailer) pair with zero sneaker_sizes rows briefly. The next scheduled scrape rebuilds them. Mitigation: monitor the per-file `sneaker_sizes` count; if it stays at 0 across two consecutive runs, something is wrong upstream. This is a brand-new failure mode worth a Grafana alert later — not blocking this fix.
- **Concurrent uploads for the same retailer** — would race on DELETE vs UPSERT and could double-delete or lose data. Today the cron runs one scraper at a time per retailer, so this can't happen. If we ever fan out scrapes, we'll need a per-retailer lock at the queue level (Postgres advisory lock is the cheap option).
- **Tests in `test_bulk_upload.py` that aren't this xfail might also start passing or failing differently** — already covered by Task 1 Step 6 (full bulk_upload suite re-run).
- **Rollback:** revert both feature commits. The xfail mark gets restored along with the test file change in Task 1.

## Self-review checklist

- **Spec coverage:** Bead says "DELETE all rows for the (colorway_id, retailer_id) pairs in scope, so the new payload becomes ground truth" — Task 1 (bulk) ✓ via `.delete().in_("colorway_id", ...).eq("retailer_id", retailer_id)`; Task 2 (legacy) ✓ via per-colorway `.delete().eq("colorway_id", ...).eq("retailer_id", ...)`. Bead also says "the existing xfail test gets flipped to passing" — Task 1 Step 2 + Step 5 ✓.
- **Placeholders:** None — every step has exact paths, exact code, exact commands, exact expected output.
- **Type consistency:** `colorway_id`, `retailer_id`, `ss_payload`, `colorway_ids_in_scope` are all named identically to the surrounding code's existing identifiers.
- **Living docs:** No SITEMAP / spec.yaml change (no route or REST surface change). CLAUDE.md "Known data-format bug" note is unrelated; no update needed.
- **Beads + commits:** Two feature commits prefixed `fix(sneaker_scout-cnu)` (one per task), one chore commit for bd state on close. Task 2's commit uses `Refs:` (not `Closes:`) trailer style since the bd close happens after Task 3.
