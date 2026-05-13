# Price-drop detection (sneaker_scout-7bl) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two boolean columns to `public.prices` (`is_on_sale`, `is_lowest_ever`) and populate them at ingest in `data_upload/bulk_upload.bulk_upload`. Unblocks 5qf (the /sale page) by providing a one-SELECT data contract.

**Architecture:** A migration adds the two columns and backfills `is_on_sale` from `(original_price IS NOT NULL AND price < original_price)`. `bulk_upload` is extended with two cheap pre-SELECTs that compute the historical cross-retailer min for each colorway in the upload (union of `prices.price` and `price_history.price`). The detection is per-row in the existing prices loop: `is_on_sale` from local fields; `is_lowest_ever` from the colorway's historical min. No new tables, no view; the flags live with the row.

**Tech Stack:** Python 3.11, `supabase-py` (PostgREST), pytest, PostgreSQL via Supabase.

Source spec: `docs/superpowers/specs/2026-05-13-price-drop-detection-design.md`.

---

## File Structure

| Path | Responsibility |
|---|---|
| `aussie-kicks-tracker/supabase/migrations/20260513120000-7bl-add-price-drop-columns.sql` (new) | Add `is_on_sale` + `is_lowest_ever` to `public.prices`; backfill `is_on_sale`. |
| `init.sql` (modify) | Mirror the two columns in the `CREATE TABLE public.prices` block. |
| `sneaker-scout-backend/data_upload/bulk_upload.py` (modify) | Extend `bulk_upload` with the two pre-SELECTs and per-row flag computation. |
| `sneaker-scout-backend/tests/test_bulk_upload.py` (modify) | Add tests covering both flags (no history, with history, with competitor prices). |
| `spec.yaml` (modify) | Document the two new prices columns under the Supabase REST surface. |

---

## Task 1: Migration — add columns and backfill is_on_sale

PostgREST will tolerate selecting columns the schema cache doesn't know about with a refresh, but writing to them needs the schema. Adding the columns first lets `bulk_upload` later write them on every upload. The backfill on `is_on_sale` is pure computation from existing columns (no history needed).

**Files:**
- Create: `aussie-kicks-tracker/supabase/migrations/20260513120000-7bl-add-price-drop-columns.sql`

- [ ] **Step 1: Write the migration**

Create `aussie-kicks-tracker/supabase/migrations/20260513120000-7bl-add-price-drop-columns.sql` with exactly:

```sql
-- sneaker_scout-7bl: add price-drop detection flags to public.prices.
--
-- is_on_sale       — set when this retailer's price < their own original_price.
-- is_lowest_ever   — set when this row's price is at or below the historical
--                    minimum across all retailers (computed from the union of
--                    public.prices and public.price_history).
--
-- Backfill is_on_sale here (pure computation from existing columns).
-- Leave is_lowest_ever = false on existing rows; the next scrape per retailer
-- recomputes it correctly against the historical union.

BEGIN;

ALTER TABLE public.prices
  ADD COLUMN is_on_sale     boolean NOT NULL DEFAULT false,
  ADD COLUMN is_lowest_ever boolean NOT NULL DEFAULT false;

UPDATE public.prices
   SET is_on_sale = (original_price IS NOT NULL AND price < original_price);

COMMENT ON COLUMN public.prices.is_on_sale IS
  'True when the retailer marked this product down: price < original_price. Computed at ingest by data_upload.bulk_upload.bulk_upload. See sneaker_scout-7bl.';
COMMENT ON COLUMN public.prices.is_lowest_ever IS
  'True when this row''s price is at or below the historical cross-retailer minimum recorded in public.prices and public.price_history for this colorway. Computed at ingest; sticky (not unset on competitor drops). See sneaker_scout-7bl.';

COMMIT;
```

- [ ] **Step 2: Apply the migration to the live DB**

I (Claude) cannot apply DDL directly (no DB password, no SQL-exec RPC). Tell the user to paste the migration into the Supabase SQL editor at the dashboard. Wait for confirmation, then proceed to Step 3.

If the user has direct `supabase db push` workflow, that's fine too. Either way: block until they confirm.

- [ ] **Step 3: Verify columns exist**

Run from `sneaker-scout-backend/`:

```bash
source .venv/bin/activate
python -c "
import os
from dotenv import load_dotenv
from supabase import create_client
load_dotenv()
sb = create_client(os.environ['SUPABASE_URL'], os.environ['SUPABASE_SERVICE_KEY'])
row = sb.table('prices').select('id, price, original_price, is_on_sale, is_lowest_ever').limit(1).execute()
print('columns visible:', sorted(row.data[0].keys()) if row.data else 'no rows')
"
```

Expected: keys include both `is_on_sale` and `is_lowest_ever`.

If you get a `'is_on_sale' column not found` error, the migration didn't apply — STOP and surface to the user.

- [ ] **Step 4: Verify backfill worked**

```bash
python -c "
import os
from dotenv import load_dotenv
from supabase import create_client
load_dotenv()
sb = create_client(os.environ['SUPABASE_URL'], os.environ['SUPABASE_SERVICE_KEY'])
on_sale = sb.table('prices').select('id', count='exact').eq('is_on_sale', True).execute()
not_on_sale = sb.table('prices').select('id', count='exact').eq('is_on_sale', False).execute()
print(f'is_on_sale=true: {on_sale.count}')
print(f'is_on_sale=false: {not_on_sale.count}')
"
```

Expected: at least one of the two counts is non-zero; together they sum to the total rows in `prices`. (If every row has the same price and original_price, on_sale=true count could legitimately be 0.)

- [ ] **Step 5: Commit the migration file**

```bash
cd /workspace/aussie-kicks-tracker
git add supabase/migrations/20260513120000-7bl-add-price-drop-columns.sql
git commit -m "$(cat <<'EOF'
chore(sneaker_scout-7bl): add is_on_sale + is_lowest_ever to prices

is_on_sale flips when a retailer marks a product down (price <
original_price). Backfilled in the migration from existing columns.

is_lowest_ever flips when this row's price is at or below the
historical cross-retailer minimum (union of prices + price_history).
Computed at ingest by data_upload.bulk_upload; existing rows default
to false and get the correct flag on each retailer's next scrape.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Mirror columns in init.sql

`init.sql` is what a fresh dev DB gets — it must match production after the migration. Open `/workspace/init.sql` and add the two columns to the `CREATE TABLE public.prices` block.

**Files:**
- Modify: `init.sql`

- [ ] **Step 1: Edit init.sql**

Find the `CREATE TABLE public.prices` block. The current block (after the 172 commit) ends with:

```sql
  product_url    text,
  UNIQUE (colorway_id, retailer_id)
);
```

Change it to:

```sql
  product_url    text,
  is_on_sale     boolean     NOT NULL DEFAULT false,
  is_lowest_ever boolean     NOT NULL DEFAULT false,
  UNIQUE (colorway_id, retailer_id)
);
```

- [ ] **Step 2: Commit**

```bash
cd /workspace
git add init.sql
git commit -m "$(cat <<'EOF'
chore(sneaker_scout-7bl): mirror is_on_sale + is_lowest_ever in init.sql

Keeps the fresh-DB setup matching production after migration
20260513120000-7bl-add-price-drop-columns.sql lands.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: TDD — add is_on_sale tests + minimal implementation

Start with `is_on_sale` because it's pure computation, no pre-SELECT, no mocks beyond what's already in the test file.

**Files:**
- Modify: `sneaker-scout-backend/tests/test_bulk_upload.py`
- Modify: `sneaker-scout-backend/data_upload/bulk_upload.py`

- [ ] **Step 1: Write the failing tests**

Open `sneaker-scout-backend/tests/test_bulk_upload.py`. Below the existing `test_bulk_upload_returns_row_counts` test (the orchestrator section), add:

```python
def test_is_on_sale_set_when_price_below_original():
    sb = _FakeSupabase()
    item = _item(price="$200.00")
    item["prices"]["original_price"] = "$300.00"
    bulk_upload(sb, [item])
    prices_upserts = [
        c for c in sb.calls if c[0] == "prices" and c[1] == "upsert"
    ]
    assert len(prices_upserts) == 1
    row = prices_upserts[0][2][0]
    assert row["is_on_sale"] is True


def test_is_on_sale_false_when_price_equals_original():
    sb = _FakeSupabase()
    item = _item(price="$300.00")
    item["prices"]["original_price"] = "$300.00"
    bulk_upload(sb, [item])
    row = next(
        c[2][0] for c in sb.calls if c[0] == "prices" and c[1] == "upsert"
    )
    assert row["is_on_sale"] is False


def test_is_on_sale_false_when_original_price_missing():
    sb = _FakeSupabase()
    item = _item(price="$200.00")
    item["prices"]["original_price"] = None
    bulk_upload(sb, [item])
    row = next(
        c[2][0] for c in sb.calls if c[0] == "prices" and c[1] == "upsert"
    )
    assert row["is_on_sale"] is False
```

- [ ] **Step 2: Run, expect failure**

```bash
cd /workspace/sneaker-scout-backend
source .venv/bin/activate
python -m pytest tests/test_bulk_upload.py::test_is_on_sale_set_when_price_below_original -v
```

Expected: FAIL with `KeyError: 'is_on_sale'` (the row dict has no such field yet).

- [ ] **Step 3: Implement is_on_sale in bulk_upload**

Open `sneaker-scout-backend/data_upload/bulk_upload.py`. Find the `price_payload.append({` block inside `bulk_upload`. The current block looks like:

```python
        price_payload.append({
            "colorway_id": colorway_id,
            "retailer_id": retailer_id,
            "price": _decimal_to_float(new_price),
            "original_price": _decimal_to_float(p["original_price"]),
            "currency": p["currency"],
            "is_available": p["is_available"],
            "product_url": p["product_url"],
        })
```

Just above it, add the `is_on_sale` computation (still inside the `for p in plan.prices:` loop, after the FK-resolution lines). Replace the whole block with:

```python
        is_on_sale = (
            p["original_price"] is not None
            and new_price is not None
            and new_price < p["original_price"]
        )
        price_payload.append({
            "colorway_id": colorway_id,
            "retailer_id": retailer_id,
            "price": _decimal_to_float(new_price),
            "original_price": _decimal_to_float(p["original_price"]),
            "currency": p["currency"],
            "is_available": p["is_available"],
            "product_url": p["product_url"],
            "is_on_sale": is_on_sale,
            "is_lowest_ever": False,  # placeholder — Task 4 wires the real check
        })
```

(`is_lowest_ever` is stubbed as `False` for now so the existing tests that index into `row` don't break; Task 4 replaces this with the real computation.)

- [ ] **Step 4: Re-run all three is_on_sale tests**

```bash
python -m pytest tests/test_bulk_upload.py -k is_on_sale -v
```

Expected: 3 PASS.

- [ ] **Step 5: Run the full test_bulk_upload suite to catch regressions**

```bash
python -m pytest tests/test_bulk_upload.py -v
```

Expected: all PASS or XFAIL as before (no new failures from existing tests).

- [ ] **Step 6: Commit**

```bash
cd /workspace/sneaker-scout-backend
git add data_upload/bulk_upload.py tests/test_bulk_upload.py
git commit -m "$(cat <<'EOF'
feat(sneaker_scout-7bl): compute is_on_sale at ingest

bulk_upload now sets prices.is_on_sale = (original_price is not None
AND price < original_price) on every row it upserts. is_lowest_ever
is stubbed to false; the real cross-retailer min logic lands in the
next commit.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: TDD — is_lowest_ever with historical min pre-SELECTs

This is the meatier change: two new pre-SELECTs (`prices` and `price_history`) per upload, plus per-row min comparison. Tests use the existing `_FakeSupabase` + a new `_FakeWithHistory` variant that returns pre-existing rows.

**Files:**
- Modify: `sneaker-scout-backend/tests/test_bulk_upload.py`
- Modify: `sneaker-scout-backend/data_upload/bulk_upload.py`

- [ ] **Step 1: Write the failing tests**

In `sneaker-scout-backend/tests/test_bulk_upload.py`, below the `is_on_sale` tests added in Task 3, add:

```python
def test_is_lowest_ever_true_when_no_history():
    """With nothing in prices/price_history for the colorway, every
    new ingest row is trivially the lowest ever."""
    sb = _FakeSupabase()
    bulk_upload(sb, [_item(price="$340.00")])
    row = next(
        c[2][0] for c in sb.calls if c[0] == "prices" and c[1] == "upsert"
    )
    assert row["is_lowest_ever"] is True


class _FakeSupabaseWithHistory(_FakeSupabase):
    """Returns pre-existing prices + price_history rows when bulk_upload
    pre-SELECTs to compute the historical cross-retailer min.

    The orchestrator pre-SELECTs by colorway_id, but at the time those
    pre-SELECTs run, the colorways have just been upserted by the fake
    and assigned synthetic ids ('id-0005' etc). To keep the mock simple,
    we ignore the .in_() filter and return the seeded rows unconditionally
    for the prices and price_history pre-SELECT calls.
    """

    def __init__(self, *, prices_rows=(), history_rows=()):
        super().__init__()
        self._seeded_prices = list(prices_rows)
        self._seeded_history = list(history_rows)

    def table(self, name):
        return _FakeTableWithHistory(self, name)


class _FakeTableWithHistory(_FakeTable):
    def execute(self):
        if self._name == "prices":
            return _FakeResult(list(self._sb._seeded_prices))
        if self._name == "price_history":
            return _FakeResult(list(self._sb._seeded_history))
        return _FakeResult([])


def test_is_lowest_ever_false_when_history_below_new_price():
    """A pre-existing price_history row at $200 means a new $340 ingest
    is NOT the lowest ever."""
    sb = _FakeSupabaseWithHistory(
        history_rows=[{"colorway_id": "any", "price": 200.00}],
    )
    bulk_upload(sb, [_item(price="$340.00")])
    row = next(
        c[2][0] for c in sb.calls if c[0] == "prices" and c[1] == "upsert"
    )
    assert row["is_lowest_ever"] is False


def test_is_lowest_ever_true_when_new_price_equals_history_min():
    """At-or-below the historical min counts as lowest ever."""
    sb = _FakeSupabaseWithHistory(
        history_rows=[{"colorway_id": "any", "price": 340.00}],
    )
    bulk_upload(sb, [_item(price="$340.00")])
    row = next(
        c[2][0] for c in sb.calls if c[0] == "prices" and c[1] == "upsert"
    )
    assert row["is_lowest_ever"] is True


def test_is_lowest_ever_uses_union_of_prices_and_history():
    """price_history only has changes; the existing prices row for a
    competitor at $250 must still be considered (even though it's not
    in price_history)."""
    sb = _FakeSupabaseWithHistory(
        prices_rows=[{"colorway_id": "any", "price": 250.00}],
        history_rows=[{"colorway_id": "any", "price": 400.00}],
    )
    bulk_upload(sb, [_item(price="$340.00")])
    row = next(
        c[2][0] for c in sb.calls if c[0] == "prices" and c[1] == "upsert"
    )
    # min of union = $250; new $340 is above → not lowest ever.
    assert row["is_lowest_ever"] is False
```

- [ ] **Step 2: Run, expect failure**

```bash
python -m pytest tests/test_bulk_upload.py -k is_lowest_ever -v
```

Expected: `test_is_lowest_ever_true_when_no_history` PASSES (the stub returns False for all rows... wait, actually it FAILS because the stub is False and the test asserts True). Actually let me think — with no history, the spec says is_lowest_ever should be True. The stub is False. So this test FAILS. Good.

`test_is_lowest_ever_false_when_history_below_new_price` PASSES (stub is False, assertion is False). The other two tests FAIL.

- [ ] **Step 3: Implement the pre-SELECTs and per-row computation**

Open `sneaker-scout-backend/data_upload/bulk_upload.py`. Find the existing prices pre-SELECT block (the one that fetches `existing_prices` for the price_history diff). It looks like:

```python
    colorway_ids = [r["id"] for r in colorway_rows]
    if colorway_ids:
        existing_prices = (
            supabase.table("prices")
            .select("colorway_id, price")
            .eq("retailer_id", retailer_id)
            .in_("colorway_id", colorway_ids)
            .execute()
            .data
        )
    else:
        existing_prices = []
    existing_price_by_colorway = {
        r["colorway_id"]: Decimal(str(r["price"])) for r in existing_prices
    }
```

Right after `existing_price_by_colorway = {...}`, add a new block that computes the historical min per colorway:

```python
    # sneaker_scout-7bl: historical cross-retailer min per colorway.
    # Union of public.prices (current state, all retailers) and
    # public.price_history (changes log). Two SELECTs per upload —
    # cheap compared to the per-product loop's cost.
    if colorway_ids:
        all_retailer_prices = (
            supabase.table("prices")
            .select("colorway_id, price")
            .in_("colorway_id", colorway_ids)
            .execute()
            .data
        )
        history_prices = (
            supabase.table("price_history")
            .select("colorway_id, price")
            .in_("colorway_id", colorway_ids)
            .execute()
            .data
        )
    else:
        all_retailer_prices, history_prices = [], []

    historical_min_by_colorway: dict[Any, Decimal] = {}
    for row in (*all_retailer_prices, *history_prices):
        cid = row["colorway_id"]
        p = Decimal(str(row["price"]))
        cur = historical_min_by_colorway.get(cid)
        if cur is None or p < cur:
            historical_min_by_colorway[cid] = p
```

Then in the `for p in plan.prices:` loop, replace the stubbed `is_lowest_ever: False` line with a real check. The block from Task 3 becomes:

```python
        is_on_sale = (
            p["original_price"] is not None
            and new_price is not None
            and new_price < p["original_price"]
        )
        historical_min = historical_min_by_colorway.get(colorway_id)
        is_lowest_ever = (
            new_price is not None
            and (historical_min is None or new_price <= historical_min)
        )
        price_payload.append({
            "colorway_id": colorway_id,
            "retailer_id": retailer_id,
            "price": _decimal_to_float(new_price),
            "original_price": _decimal_to_float(p["original_price"]),
            "currency": p["currency"],
            "is_available": p["is_available"],
            "product_url": p["product_url"],
            "is_on_sale": is_on_sale,
            "is_lowest_ever": is_lowest_ever,
        })
```

- [ ] **Step 4: Run the new tests, expect pass**

```bash
python -m pytest tests/test_bulk_upload.py -k is_lowest_ever -v
```

Expected: all 4 `is_lowest_ever` tests PASS.

- [ ] **Step 5: Run the full file to verify no regressions**

```bash
python -m pytest tests/test_bulk_upload.py -v
```

Expected: 22 passed, 1 xfailed (the cnu stale-size xfail stays).

- [ ] **Step 6: Commit**

```bash
git add data_upload/bulk_upload.py tests/test_bulk_upload.py
git commit -m "$(cat <<'EOF'
feat(sneaker_scout-7bl): compute is_lowest_ever from historical union

Adds two pre-SELECTs to bulk_upload — one against public.prices, one
against public.price_history — both filtered to the colorways in the
current upload. The min over the union is the historical cross-
retailer min per colorway. Per-row, the new ingest price is flagged
is_lowest_ever when it's at or below that min (or when there's no
history, which makes it trivially the lowest so far).

Sticky semantics per the design: competitor rows are not modified
when one retailer drops lower. Each row's flag means "at the moment
this row was last upserted, the price was at-or-below the historical
min." Stale competitor flags refresh on their own next scrape.

Closes: sneaker_scout-7bl (data layer)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Document the columns in spec.yaml

`spec.yaml` describes the Supabase REST surface the frontend reads. Add the two new columns to the `prices` schema section.

**Files:**
- Modify: `spec.yaml`

- [ ] **Step 1: Find the prices schema**

```bash
grep -nE "^\s*prices:|public\.prices" /workspace/spec.yaml | head -10
```

Open `spec.yaml`. Find the YAML block that describes the `prices` table's columns. Find a precedent column entry (e.g. `is_available`) and mirror its shape.

- [ ] **Step 2: Add the two new columns**

In the prices schema block, after the existing `product_url` (or wherever `is_available` lives), add two entries following the same YAML shape. If the precedent looks like:

```yaml
        is_available:
          type: boolean
          nullable: true
          description: |
            Whether this colorway-retailer pair is currently in stock.
```

Then add:

```yaml
        is_on_sale:
          type: boolean
          nullable: false
          description: |
            True when this retailer's price is below the original_price
            they listed for the same product (i.e. the retailer marked
            it down). Computed at ingest by data_upload.bulk_upload;
            backfilled for existing rows in migration
            20260513120000-7bl-add-price-drop-columns.sql. See
            sneaker_scout-7bl.
        is_lowest_ever:
          type: boolean
          nullable: false
          description: |
            True when this row's price is at or below the historical
            cross-retailer minimum recorded for this colorway (union of
            public.prices and public.price_history). Sticky: not unset
            on competitor rows when another retailer drops lower; each
            row's flag is refreshed on its own retailer's next scrape.
            See sneaker_scout-7bl.
```

If the precedent's shape is different (e.g. uses `type: bool` or a flat one-line description), match THAT shape — don't introduce a new convention.

- [ ] **Step 3: Commit**

```bash
cd /workspace
git add spec.yaml
git commit -m "$(cat <<'EOF'
docs(sneaker_scout-7bl): document is_on_sale + is_lowest_ever in spec.yaml

Frontend (and 5qf in particular) reads prices.is_on_sale and
prices.is_lowest_ever; the spec records them as part of the
Supabase REST surface contract.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: End-to-end smoke against a real JSON; close 7bl

Run the bulk path against an already-uploaded JSON and verify the flags get set on real data.

- [ ] **Step 1: Re-upload hypedc and check flag counts**

```bash
cd /workspace/sneaker-scout-backend
source .venv/bin/activate
python -m data_upload.run_update --file=jsons/hypedc_products.json 2>&1 | tail -3
```

Expected: `Bulk upload complete: {...}` with row counts matching the JSON's product count. Any error here means the migration didn't apply or the column names don't match — STOP and investigate.

- [ ] **Step 2: Verify flag counts in Supabase**

```bash
python -c "
import os
from dotenv import load_dotenv
from supabase import create_client
load_dotenv()
sb = create_client(os.environ['SUPABASE_URL'], os.environ['SUPABASE_SERVICE_KEY'])
on_sale = sb.table('prices').select('id', count='exact').eq('is_on_sale', True).execute()
lowest = sb.table('prices').select('id', count='exact').eq('is_lowest_ever', True).execute()
total = sb.table('prices').select('id', count='exact').execute()
print(f'total: {total.count}')
print(f'is_on_sale=true: {on_sale.count}')
print(f'is_lowest_ever=true: {lowest.count}')
"
```

Expected: `total > 0`. `is_on_sale=true` count matches however many hypedc/salomon products have price < original_price. `is_lowest_ever=true` count is at least the number of unique colorways scraped (because each colorway had no history before this run, so every first ingest was trivially the lowest).

If `is_lowest_ever=true` count is 0, the union pre-SELECT logic is wrong — STOP and re-run the tests.

- [ ] **Step 3: Re-upload salomon to verify cross-retailer min works**

Salomon and hypedc share some colorways (e.g. Salomon XT-6). After both runs:

```bash
python -m data_upload.run_update --file=jsons/salomon_products.json 2>&1 | tail -3
```

Then spot-check one colorway that both retailers carry:

```bash
python -c "
import os
from dotenv import load_dotenv
from supabase import create_client
load_dotenv()
sb = create_client(os.environ['SUPABASE_URL'], os.environ['SUPABASE_SERVICE_KEY'])
# Find a colorway carried by both Salomon and Hype DC.
cws = sb.table('colorways').select('id, name, sneaker_id').execute().data
for cw in cws[:20]:
    prices = sb.table('prices').select('retailer_id, price, is_lowest_ever').eq('colorway_id', cw['id']).execute().data
    if len(prices) >= 2:
        print(f'colorway {cw[\"name\"]} ({cw[\"id\"]}):')
        for p in prices:
            print(f'  retailer={p[\"retailer_id\"]} price={p[\"price\"]} lowest_ever={p[\"is_lowest_ever\"]}')
        break
"
```

Expected: at least one colorway carried by two retailers prints; the retailer with the lower price has `lowest_ever=True`, the one with the higher price has `lowest_ever=False` (or `True` if it was set on a previous run — sticky semantic).

- [ ] **Step 4: Close 7bl and commit bd state**

```bash
cd /workspace
bd close sneaker-scout-7bl --reason="is_on_sale + is_lowest_ever populated at ingest; smoke-tested against hypedc (177 products) and salomon (41 products). 5qf can now SELECT … WHERE is_on_sale OR is_lowest_ever."
git add .beads/
git commit -m "$(cat <<'EOF'
chore: bd state for sneaker_scout-7bl close

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 5: Verify newly-unblocked work**

```bash
bd close sneaker-scout-7bl --suggest-next 2>&1 | tail -10
```

Expected output names `sneaker-scout-5qf` (the /sale page) as newly unblocked. (If close --suggest-next was already run in Step 4, run `bd ready` instead.) Don't claim 5qf — it's the user's call whether to start it next.

---

## Self-Review

**Spec coverage:**
- Schema (two columns + backfill) — Task 1 ✓
- init.sql mirror — Task 2 ✓
- Detection logic (is_on_sale, is_lowest_ever, union of prices + price_history) — Tasks 3 + 4 ✓
- Sticky semantics (no unset on competitors) — implicit in Task 4 implementation (we never UPDATE competitor rows); documented in the commit message ✓
- Tests (no history, with history, with competitor prices) — Task 4 Step 1 covers all three ✓
- spec.yaml docs — Task 5 ✓
- Out-of-scope items (the /sale page, useSneakers rewire, notifications, is_lowest_ever backfill) — not in any task, consistent with the spec's explicit out-of-scope list ✓
- Acceptance criteria 1-6 — Tasks 1-6 map 1:1 ✓

**Placeholder scan:**
- No "TBD" / "TODO" / "implement later".
- All code blocks contain the actual code, not pseudocode.
- The `is_lowest_ever: False` line in Task 3 is explicitly labeled as a placeholder that Task 4 replaces — and Task 4 Step 3 shows the replacement.
- Task 5's spec.yaml YAML shape says "If the precedent's shape is different, match THAT shape" — concrete guidance, not a handwave.

**Type consistency:**
- `is_on_sale` and `is_lowest_ever` spelled identically across Tasks 1 (SQL), 2 (init.sql), 3 (test + impl), 4 (test + impl), 5 (docs).
- `historical_min_by_colorway` defined in Task 4 Step 3, used in Task 4 Step 3 only — no cross-task drift.
- `_FakeSupabaseWithHistory` defined in Task 4 Step 1, used in Task 4 Step 1 only.
- `bulk_upload(sb, [...])` signature consistent everywhere.

**Risk to in-flight work:**
- Migration is additive (`ADD COLUMN ... NOT NULL DEFAULT false`); existing inserts/upserts that don't mention the new columns will get the default. The per-row uploader (`update_supabase_daily.py`) keeps working unchanged.
- `bulk_upload`'s new pre-SELECTs are read-only and scoped to the upload's colorways; they don't touch other data.
- The xfail for cnu remains xfail.
