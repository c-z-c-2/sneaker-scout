# Price-drop detection (sneaker_scout-7bl) — design

**Status:** approved 2026-05-13. Implementation plan to follow under writing-plans.
**Blocks:** sneaker_scout-5qf (sale / price-drop page).
**Owner:** Chris.

## Goal

Detect two distinct kinds of price drops at ingest time and expose them
as boolean columns on `public.prices` so the frontend (5qf) can render a
sale/price-drop page with a single `SELECT … WHERE is_on_sale OR is_lowest_ever`
query. 7bl ships the data layer only; 5qf renders it.

## Definitions

Two independent flags, both stored on each `prices` row (one row per
colorway × retailer):

- **`is_on_sale`** — `true` when `original_price IS NOT NULL AND price < original_price`.
  Mirrors what the retailer itself labels "on sale" on the PDP.
  Per-(colorway, retailer); independent of all other rows.

- **`is_lowest_ever`** — `true` when this row's `price` is at or below the
  minimum price ever recorded for this colorway across **all retailers**.
  Stronger marketing claim. Sticky: once set on a row, it stays until that
  retailer's *next* scrape recomputes the flag against a fresh historical
  min. Competitor rows are not modified when one retailer drops lower.

The two flags are independent. A row can be `is_on_sale` without being
`is_lowest_ever` (this retailer marked it down, but another retailer's
price is still cheaper). It can be `is_lowest_ever` without being
`is_on_sale` (this is the cheapest the shoe has ever been but the
retailer hasn't crossed out an original price). It can be both.

## Schema

Migration adds two columns to `public.prices`:

```sql
ALTER TABLE public.prices
  ADD COLUMN is_on_sale     boolean NOT NULL DEFAULT false,
  ADD COLUMN is_lowest_ever boolean NOT NULL DEFAULT false;

-- Backfill is_on_sale from existing data (cheap, no history needed).
UPDATE public.prices
   SET is_on_sale = (original_price IS NOT NULL AND price < original_price);

-- is_lowest_ever stays false; the next ingest pass per retailer recomputes
-- it correctly from the price_history union prices comparison.
```

Mirror both columns in `init.sql` so fresh-DB setup matches production.

No new tables, no view, no separate `price_drops` table. The flags live
with the row they describe; reads are one SELECT.

## Detection logic (bulk_upload)

The change lands in `data_upload/bulk_upload.bulk_upload`, in the prices
loop between the existing pre-SELECT and the upsert. Pseudocode:

```python
# Already exists: pre-SELECT existing prices for price_history diffing.
# NEW: also fetch existing min(price) per colorway across all retailers,
# from both prices (current state) and price_history (changes log).
colorway_ids = [r["id"] for r in colorway_rows]
if colorway_ids:
    prices_min_rows  = supabase.table("prices") \
        .select("colorway_id, price") \
        .in_("colorway_id", colorway_ids).execute().data
    history_min_rows = supabase.table("price_history") \
        .select("colorway_id, price") \
        .in_("colorway_id", colorway_ids).execute().data
else:
    prices_min_rows, history_min_rows = [], []

# Build {colorway_id: Decimal(min_price)} from union of both.
historical_min_by_colorway: dict[str, Decimal] = {}
for row in (*prices_min_rows, *history_min_rows):
    cid = row["colorway_id"]
    p = Decimal(str(row["price"]))
    if cid not in historical_min_by_colorway or p < historical_min_by_colorway[cid]:
        historical_min_by_colorway[cid] = p
```

Then in the per-product loop where `price_payload` is built:

```python
historical_min = historical_min_by_colorway.get(colorway_id)
is_on_sale = (
    p["original_price"] is not None
    and new_price is not None
    and new_price < p["original_price"]
)
is_lowest_ever = (
    new_price is not None
    and (historical_min is None or new_price <= historical_min)
)
price_payload.append({
    …existing fields…,
    "is_on_sale": is_on_sale,
    "is_lowest_ever": is_lowest_ever,
})
```

Two extra HTTPS round trips per upload (the two SELECTs), regardless of
product count. Negligible compared to the per-row uploader's 25-45 per
product.

## Why union the prices + price_history tables?

`price_history` only logs *changes* — a colorway/retailer pair that has
been ingested once but never changed has no `price_history` row. So
`min(price_history)` alone misses the initial-ingest prices.

`prices` is the current state and always has one row per (colorway,
retailer) that's been ingested. So `min(prices)` captures every
known price point at least once.

`price_history` adds value when a price *has* changed: it preserves the
old min that's no longer reflected in `prices`. For example: retailer A
scrapes at $300 (min). Retailer A rescrapes at $400 — `prices` now only
shows $400 for retailer A. But the historical min was $300, and
`price_history` still has that row.

Union of both → true historical min over every recorded price.

## Sticky semantics for is_lowest_ever

When retailer A's row is set to `is_lowest_ever=true` and then retailer B
drops to a lower price, retailer A's flag is **not** unset. Rationale:

- The flag's meaning is "at the moment this row was last upserted, the
  price was at the historical min." That's true at the moment, even if
  later events make it stale.
- Unsetting competitors on every upload would require an extra UPDATE
  per upload and could thrash the flag when retailers leapfrog each
  other day-to-day.
- A's flag gets refreshed correctly on A's *own* next scrape, when the
  detection logic compares A's new price against the new historical min.

Consequence the frontend should know about: at any given moment, multiple
retailers can carry `is_lowest_ever=true` for the same colorway (each
was the min at their own ingest moment). The sale page query is
`WHERE is_lowest_ever = true`, which will return all of them. The page
can either dedupe by colorway (show one card per colorway, choose the
cheapest current price) or show every flagged row — that's a 5qf
decision, not 7bl's.

## Out of scope for 7bl

- The `/sale` page itself (that's 5qf).
- Rewiring `useSneakers` home-grid mocks to use real `is_on_sale` /
  `is_lowest_ever`. The home grid keeps using random mocks until 5qf or
  a separate frontend issue addresses it.
- User-facing notifications (email/push). The bd title says "notification"
  but the description is detection + a category page; if push
  notifications are wanted later, that's a separate issue.
- Backfilling `is_lowest_ever` for existing rows. Migration leaves it
  `false`; the next scrape per retailer flips the right rows.

## Tests

In `sneaker-scout-backend/tests/test_bulk_upload.py`:

- Extend the existing payload tests for the two new columns under the
  default (no pre-existing history) case — every new row should be
  `is_lowest_ever=true` because there's nothing to compare against;
  `is_on_sale` is driven by the fixture's `original_price` vs `price`.
- Add a test with a `_FakeSupabase` variant that returns pre-existing
  `prices` and `price_history` rows when `bulk_upload` pre-SELECTs.
  Assert: new row with price *below* the mocked historical min gets
  `is_lowest_ever=true`; new row with price *above* gets `is_lowest_ever=false`.
- Add a test for `is_on_sale`: original_price > price → true; original_price
  null → false; original_price <= price → false.

No live-DB tests required for the data layer — the mocks cover the
detection logic exhaustively. Smoke against a real JSON happens at
implementation close.

## spec.yaml + SITEMAP

`spec.yaml` gets the two new columns documented under the prices schema
section. No new CLI entries. No SITEMAP changes (no routes touched).

## Acceptance criteria

1. Migration applies cleanly to live DB; both columns exist on `public.prices`.
2. `init.sql` mirrors the columns.
3. Running `python -m data_upload.run_update --file=jsons/<retailer>_products.json`
   on a previously-uploaded JSON sets `is_on_sale=true` on rows where
   `price < original_price`, and `is_lowest_ever=true` on rows whose
   price is at or below the historical min.
4. `pytest tests/test_bulk_upload.py` passes — all existing + new tests
   green; xfail for cnu remains xfail.
5. `spec.yaml` mentions both columns in the prices schema section.
6. bd close 7bl with a one-line reason summarizing what shipped.
