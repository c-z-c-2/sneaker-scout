# Present Recommendation Algorithm Workflow

**Status:** Shipped (beads `sneaker-scout-j26`, P1, CLOSED)
**Approach:** Distilled / "pseudo" algorithm — mirror Hype DC's own product
ordering rather than computing our own bespoke ranking.

> Rationale (from the issue): *"instead of creating our own recommendation
> algorithm for now we can just use the same as that of hype so we know that
> our first few pages look the same."*

This is the **current** behaviour. The bespoke, signal-scored algorithm and the
user-personalisation research are tracked separately and are **not** built yet:

| ID | Status | Scope |
|----|--------|-------|
| `sneaker-scout-j26` | ✅ CLOSED | Mirror Hype's listing order (this document) |
| `sneaker_scout-7d9` | open (P2) | Bespoke scoring algorithm (discount %, brand popularity, stock breadth, price-drop recency, retailer reliability) |
| `sneaker-scout-1wv` | open (P2) | Research/planning on user-personalised recommendations (cookies, clustering, user profiles) |

---

## End-to-end pipeline

The ranking signal is **Hype DC's own listing position**, captured at scrape
time, persisted to the DB, and replayed in the frontend listing.

### 1. Scrape — capture Hype's order

`sneaker-scout-backend/hypedc/pagination_scraper.py`

- As the scraper walks Hype DC's listing pages, it assigns a running
  `scrape_rank` (1 = first product on page 1, incrementing across all pages).
- `combine_product_info()` threads this into the output JSON as
  `colorway.listing_rank`.
- This preserves the exact order Hype presents products in (their own
  merchandising / recommendation order).

### 2. Upload — persist to `prices.listing_rank`

`sneaker-scout-backend/data_upload/`

- Adds/uses a `listing_rank` column on the `prices` table
  (added in commit `e40504d`).
- Before each upload run, stale `listing_rank` values are **cleared** so a
  product that drops off Hype's listing doesn't keep a phantom rank.
- The uploader then writes the fresh `listing_rank` onto each Hype DC
  `prices` row.

### 3. Frontend — replay the order with fallback interleave

`aussie-kicks-tracker/src/hooks/useSneakers.tsx`
+ `aussie-kicks-tracker/src/lib/rankInterleave.ts`

1. The listing query embeds `prices(retailer_id, listing_rank)`.
2. `useSneakers` computes a per-sneaker **`hypeRank`** = the *minimum*
   `listing_rank` across the sneaker's colorways for the Hype DC retailer.
   - Gender-aware: when a gender filter is active, only colorways matching
     that gender contribute (so a "mens" filter reflects the mens-listing
     order).
   - Sneakers not carried by Hype DC get `hypeRank = null`.
3. `interleaveStriped()` produces the final ordering.

#### `interleaveStriped()` — the ordering rule

Defaults: `burstSize = 12`, `stripeRatio = 3`.

- **Burst (first 12 slots):** pure Hype-ranked items, in Hype's order. This is
  what makes our first page look like Hype's.
- **After the burst — 3:1 stripe:** repeat [3 Hype items, 1 fallback item].
- **Hype queue:** sorted by `hypeRank` ascending.
- **Fallback queue** (sneakers with `hypeRank === null`): sorted by
  `priceChange` ascending — most-negative (biggest price drop) first.
- **No gaps:** if either queue empties mid-stripe, remaining slots are filled
  from the other queue.
- Pure function: same inputs → same output. Safe to call inside a React Query
  `select` or inline in the hook.

Pagination (`offset`/`limit`) is applied to the fully interleaved list, so
ordering is stable across pages.

---

## Key files

| Layer | File |
|-------|------|
| Scrape | `sneaker-scout-backend/hypedc/pagination_scraper.py` (`combine_product_info`, `scrape_all_pages`) |
| Upload | `sneaker-scout-backend/data_upload/` (writes `prices.listing_rank`, clears stale ranks) |
| DB | `prices.listing_rank` column |
| Frontend hook | `aussie-kicks-tracker/src/hooks/useSneakers.tsx` |
| Frontend sort | `aussie-kicks-tracker/src/lib/rankInterleave.ts` |

## Known fragility

- `useSneakers` hardcodes `HYPEDC_RETAILER_ID`. If the Hype DC retailer row is
  recreated with a new UUID, ranking silently degrades to the fallback path
  (price-drop order only). Tracked in `sneaker_scout-hkw`.

## Tuning

The ordering shape is controlled entirely by `InterleaveOptions`
(`burstSize`, `stripeRatio`) in `rankInterleave.ts` — no backend or DB change
needed to adjust how aggressively the all-view mirrors Hype vs. surfaces
price-drop fallback items.
