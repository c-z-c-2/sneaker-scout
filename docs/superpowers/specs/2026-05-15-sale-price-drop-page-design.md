# Sale / price-drop page (sneaker_scout-5qf) — design

**Status:** approved 2026-05-15. Implementation plan to follow under writing-plans.
**Depends on:** sneaker_scout-7bl (closed) — `prices.is_on_sale` and `prices.is_lowest_ever` columns.
**Owner:** Chris.

## Goal

A new public route `/sale` that surfaces colorways with a current price-drop
signal. Two signals coexist on the page:

- `prices.is_on_sale` — retailer marked the row down (`price < original_price`).
- `prices.is_lowest_ever` — this row is at-or-below the cross-retailer historical minimum.

Both are computed at ingest in `data_upload/bulk_upload.bulk_upload` and live
on each `prices` row (per `(colorway_id, retailer_id)`). 5qf renders them; 5qf
ships no schema or backend changes.

## Out of scope (deferred to other beads)

These were considered and split out so v1 can ship cleanly:

- **Gender schema + filter.** No `colorways.gender` today. The 505 migration
  standardised sizes to US-Men, so a women's-only shoe is currently mis-sized.
  Filed as its own bead covering: add column, backfill existing rows as `'mens'`
  (every current listing URL is mens-only), update each scraper to emit gender,
  layer gender chip onto `/` and `/sale`. 5qf does **not** depend on this.
- **Brand filter** on `/sale`. Defer to a v2 enhancement bead.
- **Price-band (min/max) filter** on `/sale`. Same.
- **Promote client rollup to a Postgres RPC.** Tracking bead only; not blocking v1.

## Route + URL contract

| Path | Auth | Purpose |
|---|---|---|
| `/sale` | public | List colorways where at least one prices row has `is_on_sale=true` OR `is_lowest_ever=true`. |

URL params (all optional, all shareable):

| Param | Format | Default | Shared with |
|---|---|---|---|
| `retailers` | `<id>,<id>` UUIDs | none | `/`, `/sneaker/:id`, `/admin` (FilterContext) |
| `sizes` | `<us>,<us>` numbers | none | same as above |
| `signal` | `all` \| `sale` \| `lowest` | `all` | `/sale` only |
| `sort` | `pct` \| `abs` \| `recent` | `pct` | `/sale` only |

Pagination is local component state (matches `/`); not URL-synced. 20 per page.
Resets to page 1 on any filter/signal/sort change.

## Page semantics

One card per **colorway**. A colorway is shown when at least one of its
`prices` rows satisfies the active `signal`:

- `signal=all` → `is_on_sale = true OR is_lowest_ever = true`
- `signal=sale` → `is_on_sale = true`
- `signal=lowest` → `is_lowest_ever = true`

Within a qualifying colorway, the card displays:

- **Cheapest qualifying retailer's row** drives `was → NOW`, `% off`, `$ off`,
  the "Cheapest: <retailer>" chip.
- **All other qualifying retailers** appear as "Also: <retailer>, …" chips.
- **Badges row** — `[On Sale]` if any qualifying row has `is_on_sale=true`;
  `[Lowest Ever]` if any has `is_lowest_ever=true`. Both can appear together.

Clicking a card navigates to `/sneaker/<sneakerId>?colorway=<colorwayId>` and
preserves any active `retailers` / `sizes` params (FilterContext does this
automatically — same as the `/` split view).

## UI components

```
+-----------------------------------------------+
| Header  [Home] [Sale] [Favorites] [Admin]      |
+-----------------------------------------------+
| /sale                                          |
| [Filter chips: All | On Sale | Lowest Ever]    |
|                              [Sort: % off ▾]   |
|                                                |
| [FilterSidebar]    [Grid of SaleColorwayCard]  |
|  - Retailers       +------------+ +-----------+|
|  - Sizes           | card       | | card      ||
|                    +------------+ +-----------+|
|                    [Pagination 1 2 3 ...]      |
+-----------------------------------------------+
```

**New components:**

- `pages/Sale.tsx` — the route component. Mounts FilterSidebar + grid + pagination.
- `components/SaleColorwayCard.tsx` — derived from existing `ColorwayCard`.
  Adds the strikethrough pricing block, the `[On Sale]` / `[Lowest Ever]`
  badge row, and the "Cheapest" / "Also" retailer chip row.
- `components/SignalChips.tsx` — the All / On Sale / Lowest Ever chip group
  (writes/reads `?signal=`).
- `components/SortDropdown.tsx` — the % off / $ off / recent dropdown
  (writes/reads `?sort=`).

**Reused as-is:**

- `Header` — gains one new nav entry (`Sale`).
- `FilterSidebar` — unchanged; reads/writes `retailers` and `sizes` via
  `FilterContext`.
- `FilterContext` — unchanged; the new params (`signal`, `sort`) live in
  `pages/Sale.tsx` local state synced to URL, not in FilterContext, because
  they don't apply to `/` or `/admin`.

**Index hero chip** — `pages/Index.tsx` gains a small discoverable element in
the hero/tiles area: `🔥 N deals →` linking to `/sale`. N is the colorway
count with at least one on-sale-or-lowest-ever row, fetched via
`useSaleColorwaysCount()`.

## Sort

Default `pct`. Sort is applied **after** the client-side rollup (it sorts on
the computed `pctOff` / `absOff` of the cheapest qualifying row, not on a raw
column). Implication: full sort key is only known after rollup, so pagination
is client-side. This is fine while the qualifying set is bounded by the
catalog (low thousands). See "Why client rollup" below.

| Option | Sort key |
|---|---|
| `pct` | `(original_price - price) / original_price` desc, ties broken by `last_updated` desc |
| `abs` | `(original_price - price)` desc, ties broken by `last_updated` desc |
| `recent` | `last_updated` desc on the cheapest qualifying row |

Rows where `original_price IS NULL` can never be `is_on_sale=true` (the
trigger logic in 7bl is `original_price IS NOT NULL AND price < original_price`),
so `pct`/`abs` are always computable for any row that surfaces here. The only
edge case is a colorway that qualifies **only** via `is_lowest_ever` (no
on-sale row at all) — for those, `% off` and `$ off` are shown as `—` on the
card and they sort last under `pct`/`abs`. Under `signal=lowest` they all sort
under `recent`.

## Data layer

New code in `aussie-kicks-tracker/`:

- `src/hooks/useSneakers.tsx`
  - `useSaleColorways(page, limit, retailerIds, sizes, signal, sort)` —
    react-query hook. Returns `{ rows, total }`.
  - `useSaleColorwaysCount()` — react-query hook for the Index hero chip.
    Returns total qualifying colorway count (no filters).
- `src/lib/sneakerQueries.ts`
  - `fetchSaleColorways(retailerIds, sizes, signal)` — runs the PostgREST
    query, performs the rollup, returns one row per colorway with the
    cheapest-retailer row + aggregates.
  - `fetchSaleColorwaysCount()` — cheap count.

The hook applies `sort` and slices for `page` after `fetchSaleColorways`
resolves (client-side).

### Query strategy (v1: PostgREST + client rollup)

Anchor on `colorways`, inner-join `sneakers`/`brands` and the `prices` foreign
table, filter the prices join by `or=(is_on_sale.eq.true,is_lowest_ever.eq.true)`.

```ts
const pricesFilter = {
  all:    'is_on_sale.eq.true,is_lowest_ever.eq.true',  // OR
  sale:   'is_on_sale.eq.true',
  lowest: 'is_lowest_ever.eq.true',
}[signal];

const query = supabase
  .from('colorways')
  .select(`
    id, name, image_url,
    sneakers!inner ( id, name, brand:brands ( id, name ) ),
    prices!inner (
      price, original_price, is_on_sale, is_lowest_ever,
      last_updated,
      retailer:retailers ( id, name )
    )
  `)
  .or(pricesFilter, { foreignTable: 'prices' });

if (retailerIds?.length) {
  query.in('prices.retailer_id', retailerIds);
}
if (sizes?.length) {
  // Reuse the size-scoping join pattern already in useSneakers /
  // fetchAllSneakers: inner-join sneaker_sizes filtered by us_size IN (...)
  // and is_available=true. Copy the exact PostgREST shape; do not invent a
  // new one.
}
```

Returns each qualifying colorway with 1+ inlined prices rows. Client-side
reduce per colorway:

1. Among the inlined prices rows, pick "cheapest": lowest `price`; ties broken
   by `last_updated` desc (most recent wins), then by `retailer.name` asc for
   stable rendering. That row drives `was → NOW`, `pctOff`, `absOff`,
   `cheapestRetailer`.
2. Remaining rows → `alsoRetailers: { id, name }[]`, sorted by `price` asc
   then `retailer.name` asc.
3. `onSale = rows.some(r => r.is_on_sale)`
4. `lowestEver = rows.some(r => r.is_lowest_ever)`
5. If the cheapest row's `original_price IS NULL` (only possible when it
   qualified via `is_lowest_ever` alone), render `pctOff`/`absOff` as `—`.

The react-query cache key is `['saleColorways', signal, retailerIds, sizes]`.
Sort + page run on the cached result; no refetch on sort/page change.

### Why client rollup over an RPC

- No migration, no Postgres function maintenance.
- Total qualifying colorways is bounded by the catalog (low thousands at most),
  well within client-side reduce range.
- The rollup logic is the kind of thing that will evolve as we add badge
  variants — easier to iterate in TypeScript than a SQL function.
- Promotion path is clean: a future `get_sale_colorways(...)` Postgres
  function returns the already-rolled-up shape, and `fetchSaleColorways`
  switches from `.from('colorways')...` to `.rpc('get_sale_colorways', ...)`
  without changing the hook signature.

## Empty states

- **No matches under current filters** — show `"No deals match your filters."`
  with a `[Clear filters]` button that resets `retailers`, `sizes`, and
  `signal=all`.
- **No deals at all** — show `"No deals right now — check back tomorrow."`
  This is defensive; expected to only show during cold-start before the first
  ingest pass has flagged anything.

## No mock data

The list views on `/` (`useSneakers`) and `/favorites` currently fake
`lowest_price`, `price_change`, and `in_stock` via `Math.random()`. That bug
is documented in SITEMAP.md and is out of scope for this bead. `/sale` MUST
query real data only — every value on a card sources directly from `prices` /
`colorways` / `sneakers`. There is no fallback to random.

## Living-doc updates (in the same PR as the code)

- **`aussie-kicks-tracker/SITEMAP.md`** — add `/sale` to the route table; add
  a full page section matching the format used for `/` and `/admin` (URL
  params table, data sources, components rendered).
- **`spec.yaml`** (repo root) — document the new `colorways` select shape used
  by `fetchSaleColorways`, and the count query used by
  `useSaleColorwaysCount`. Examples in the spec should round-trip.

## Acceptance criteria

The bead is done when:

1. Navigating to `/sale` lists colorways with at least one `is_on_sale=true`
   or `is_lowest_ever=true` prices row.
2. The `All | On Sale | Lowest Ever` chips switch the `signal` filter and
   update the URL (`?signal=…`).
3. The sort dropdown changes ordering and updates the URL (`?sort=…`).
4. Existing `retailers` and `sizes` filters (FilterSidebar) restrict the list
   and round-trip via URL.
5. Each card shows the cheapest qualifying retailer's `was → NOW` pricing,
   correct `[On Sale]` / `[Lowest Ever]` badges, and the "Also: …" retailer
   chip row when more than one retailer qualifies.
6. Clicking a card opens `/sneaker/<sneakerId>?colorway=<colorwayId>` with
   active `retailers`/`sizes` preserved.
7. The Header shows a `Sale` link on `/` and `/admin`.
8. The Index hero shows a `🔥 N deals →` chip linking to `/sale` with the
   correct count.
9. `SITEMAP.md` and `spec.yaml` are updated in the same commit as the route.
10. No `Math.random()` calls anywhere in the new code; `npm run lint` and
    `npm run build` both pass with no new warnings or errors. Manual browser
    verification: visit `/sale`, toggle each signal chip, change sort, apply
    a retailer filter, click a card, hit the back button — all flows behave
    as described above. The project has no frontend test harness today;
    establishing one is its own bead.

## Follow-up beads to file on close

- `feat: add colorways.gender + backfill + scraper emit + filter chip on / and /sale`
- `feat: brand filter on /sale`
- `feat: price-band filter on /sale`
- `perf: promote /sale rollup to Postgres RPC if query latency > 500ms p95`
