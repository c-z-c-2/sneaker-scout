# Distilled recommendation: mirror Hype DC's listing order

**Beads issue:** `sneaker-scout-j26`
**Date:** 2026-05-23

## Goal

Replace the all-view's current alphabetical ordering with one that mirrors Hype DC's own listing order, so the first page of `/` looks like the first page of `hypedc.com/au/categories/<gender>/footwear/sneakers`. Products not carried by Hype DC are mixed in further down using a steepest-recent-price-drop fallback.

This is a deliberate shortcut: we don't build a recommendation model. We borrow Hype's curation, which already encodes popularity, marketing priority, and seasonality.

## Scope

- **Target page:** `aussie-kicks-tracker/src/pages/Index.tsx` (the all-view, powered by `useSneakers`).
- **Out of scope:** `Sale.tsx`, `SneakerDetail.tsx`, search results, sale-page ranking. Those use different hooks and aren't touched.
- **Out of scope:** search-frequency tracking, user-preference modelling, clustering — these belong in `sneaker-scout-1wv` (the broader recommendation-exploration issue).

## Decisions captured during brainstorming

| Question | Decision |
|---|---|
| Where does rank live? | Column on `prices` (`(colorway_id, retailer_id)` join row) |
| Per-gender ranks? | Yes — driven by `colorway.gender`, not by extra columns |
| Fallback signal for non-Hype products | Steepest recent price drop (`price_change` from latest two `price_history` rows) |
| Sort location | Client-side, fetch-all + paginate after sort (matches existing `useSaleColorways` pattern) |
| Interleave pattern | Burst of 12 pure-Hype slots, then 3 Hype : 1 fallback stripe |
| Cross-gender aggregation when `gender='all'` | Min Hype rank across genders for that sneaker |

## Architecture

```
hypedc/pagination_scraper.py
  └── tracks scrape_rank (1..N), emits `prices.listing_rank` in JSON

data_upload/update_supabase_daily.py
  └── clears stale ranks for (Hype DC, this gender), then upserts new ranks

prices table (Supabase)
  └── new column: listing_rank int NULL

aussie-kicks-tracker/src/hooks/useSneakers.tsx
  └── fetch-all + client-side composite sort + striped paginate
```

No new tables. No new RPCs. One DDL change, three code changes.

## Schema change

```sql
ALTER TABLE prices ADD COLUMN listing_rank int NULL;

COMMENT ON COLUMN prices.listing_rank IS
  'Position this colorway occupied in the retailer''s listing page on the last scrape (1 = first). NULL when not captured. Refreshed wholesale per (retailer, gender) on every scrape run.';
```

`prices.last_updated` (already present) is the scrape recency — no separate timestamp column.

Applied as a Supabase migration via `supabase migration new add_listing_rank_to_prices` so it appears in `supabase migration list`.

## Backend changes

### `hypedc/pagination_scraper.py`

1. In `scrape_all_pages`, add a `scrape_rank` counter, initialised to 1, incremented for every product appended to `all_products`.
2. Pass `scrape_rank` into `combine_product_info` as a new argument.
3. In `combine_product_info`, emit it as `prices.listing_rank` in the returned dict.

The dict shape becomes:

```python
"prices": {
    "price": price,
    "original_price": original_price,
    "currency": "AUD",
    "is_available": ...,
    "product_url": basic.get("url", ""),
    "listing_rank": scrape_rank,   # new
},
```

Other retailer scrapers are untouched — they continue to emit no `listing_rank`, which the uploader maps to NULL.

### `data_upload/update_supabase_daily.py`

Before upserting any prices rows for a given run:

```python
# Reset Hype DC ranks for the gender we're about to overwrite. Without this,
# products that fell out of the top N (no longer scraped) would keep their
# stale rank from the previous run and continue dominating the listing.
supabase.from('prices').update({'listing_rank': None}) \
    .eq('retailer_id', HYPEDC_RETAILER_ID) \
    .in_('colorway_id',
         supabase.from('colorways').select('id').eq('gender', this_run_gender)) \
    .execute()
```

(Exact `.in_` shape may need a two-step fetch-IDs-then-update if PostgREST nested filters are awkward — confirmed during implementation.)

Then upsert the prices rows normally, with `listing_rank` flowing through from the JSON.

The uploader only clears ranks for the retailer + gender being uploaded. If the womens run fails, mens ranks survive untouched.

## Frontend changes

### `useSneakers.tsx` — composite sort

Replace the current per-page query (line 89-104) with:

1. **Embed `listing_rank`** in the `colorways → prices` select. (Already embedding `prices` when a retailer filter is active; widen to always-embed `colorways(prices(listing_rank, retailer_id))` when computing the rank, and join the Hype DC retailer_id at fetch time.)
2. **Drop `.order('name')`** and `.range(offset, offset + limit - 1)` from the server-side query. Fetch the full filtered set instead.
3. **After fetch, compute per-sneaker Hype rank:**
   - For each sneaker, walk every `colorway → prices` row where `retailer_id == HYPEDC_RETAILER_ID` and `listing_rank != null`.
   - When `gender='all'`: take min rank across all matching rows.
   - When `gender='mens'` or `gender='womens'`: take min rank across rows whose colorway.gender matches.
   - If no rank exists for that sneaker → it's a fallback item.
4. **Compose two queues:**
   - `hypeQueue` = sneakers with a Hype rank, sorted ascending by that rank.
   - `fallbackQueue` = sneakers without a Hype rank, sorted by `price_change` ascending (most negative first; the existing `priceChangeBySneaker` map provides this).
5. **Interleave by stripe rule:**
   - Positions 1–12: drain `hypeQueue`.
   - Position 13 onward: take 3 from `hypeQueue`, then 1 from `fallbackQueue`, repeat.
   - When `hypeQueue` is empty, drain the rest of `fallbackQueue`.
   - When `fallbackQueue` is empty mid-stripe, fill the slot from `hypeQueue` (no gaps).
6. **Paginate client-side**: slice the interleaved list by `[(page-1)*limit, page*limit]`.
7. **Update `count`/`totalPages`** to reflect the interleaved length (same as full filtered set length).

The retailer/size/gender filter logic on the server query is preserved. We're only changing what runs *after* the row set lands.

### Sort function — pseudocode

```ts
interface RankedSneaker { sneaker: Sneaker; hypeRank: number | null; priceChange: number; }

function interleaveStriped(
  ranked: RankedSneaker[],
  opts: { burstSize: number; stripeRatio: number } = { burstSize: 12, stripeRatio: 3 }
): Sneaker[] {
  const hype = ranked.filter(r => r.hypeRank !== null)
                     .sort((a, b) => a.hypeRank! - b.hypeRank!);
  const fallback = ranked.filter(r => r.hypeRank === null)
                         .sort((a, b) => a.priceChange - b.priceChange);
  const out: Sneaker[] = [];
  let i = 0;
  while (hype.length + fallback.length > 0) {
    const useHype = (i < opts.burstSize) ||
                    (i % (opts.stripeRatio + 1) !== opts.stripeRatio) ||
                    fallback.length === 0;
    if (useHype && hype.length > 0) {
      out.push(hype.shift()!.sneaker);
    } else if (fallback.length > 0) {
      out.push(fallback.shift()!.sneaker);
    } else if (hype.length > 0) {
      out.push(hype.shift()!.sneaker);
    }
    i++;
  }
  return out;
}
```

Unit-testable in isolation — that's the point of pulling it out.

## Edge cases

| Case | Handling |
|---|---|
| No Hype scrape has ever run | All ranks NULL → everything goes through fallback → list ordered by price drop. Alphabetical tiebreaker preserves stability. |
| Partial Hype run (1 of 3 pages scraped before captcha) | We still clear-then-write, so products on pages 2-3 lose their ranks for this cycle. Logged. Next cycle restores them. Acceptable. |
| A Hype-listed product disappears from the listing (delisted) | Cleared on the next scrape's reset step, becomes a fallback item. Correct. |
| Unisex product in both Hype mens and womens listings | Two separate colorway rows (different `gender` values) → two separate `prices` rows → two separate ranks. Already handled by the schema. |
| User has gender filter inactive (`gender='all'`) | Min Hype rank across all genders for that sneaker. |
| New scraper for retailer X added later that wants its own listing rank | Same column on prices works — it's per `(colorway, retailer)`. No schema change. We just decide whether the frontend cares about that retailer's order. |

## Testing

### Backend (Python)

- Extend `tests/test_hypedc_pagination.py` (or create) to assert that scraping a multi-page fixture produces products with `listing_rank` 1..N in DOM order across pages.
- Test for `combine_product_info`: passing a `scrape_rank=42` flows through to `prices.listing_rank`.
- Test for upload reset: a dry-run path that confirms the SQL clears only the right retailer + gender slice.

### Frontend (TypeScript)

- Unit-test `interleaveStriped` with synthetic inputs:
  - All Hype, no fallback → identical to `hype.sort(byRank)`.
  - No Hype, all fallback → ordered by price drop.
  - 20 Hype + 5 fallback → first 12 slots Hype only, slots 13-25 follow 3:1 stripe.
  - Mid-stripe fallback exhaustion → fills from Hype.
- Manual smoke test: with the dev server running, open `/`, set gender=mens, compare top of `/` to the live Hype DC mens listing.

### DB migration

- After `supabase db push`, verify with `\d prices` that `listing_rank int` exists.
- Verify advisors with `supabase db advisors` — adding a nullable column shouldn't raise anything.

## Out-of-scope follow-ups (file as separate bd issues if not already filed)

- **Search-frequency tracking** → fits the existing `sneaker-scout-1wv` issue. Required before "most searched" can replace the price-drop fallback.
- **Server-side sort via RPC** → revisit when catalog grows past a few hundred sneakers and client-side fetch-all becomes expensive.
- **Rank history** → if we ever want "rank changed by N positions this week" analytics. Would mirror the `price_history` pattern with a new `listing_rank_history` table.
- **Other retailer rankings** → adding Foot Locker / JD ranks is purely a question of wiring up their scrapers' counters; no schema change needed.

## Definition of done

1. Migration applied; `prices.listing_rank` column exists in production.
2. Hype DC scraper emits `listing_rank` in its JSON output.
3. Uploader clears + writes ranks correctly on every Hype run.
4. `useSneakers` returns sneakers ordered by burst-then-stripe interleave.
5. Manual smoke: first 12 cards on `/?gender=mens` match the first 12 cards on Hype's mens listing.
6. SITEMAP.md updated if Index.tsx's data-fetching contract changed in a user-visible way. (It probably hasn't — same shape, different order.)
7. spec.yaml updated if the embed shape on `colorways → prices` changed in a way that breaks the documented example.
