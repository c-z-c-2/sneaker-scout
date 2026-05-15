# Sale / price-drop page (sneaker_scout-5qf) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a new public route `/sale` that lists colorways with at least one `prices` row where `is_on_sale=true` or `is_lowest_ever=true` (the flags landed in 7bl). One card per colorway, badges, sort, filters shared with `/`, header link, Index hero chip.

**Architecture:** A single PostgREST query anchored on `colorways` with an `inner` join on `prices` filtered by `or=(is_on_sale.eq.true,is_lowest_ever.eq.true)`. Per-colorway rollup happens client-side: pick the cheapest qualifying retailer, render its `was → NOW` pricing, list the other qualifying retailers as chips, derive `[On Sale]` / `[Lowest Ever]` badges from the inline rows. Sort runs post-rollup. Pagination is client-side. No new tables, no migrations.

**Tech Stack:** React 18, TypeScript, Vite, `@tanstack/react-query`, `@supabase/supabase-js`, `react-router-dom` v6, shadcn/ui, Tailwind.

Source spec: `docs/superpowers/specs/2026-05-15-sale-price-drop-page-design.md` (commit `bdb8630`).

**Note on test discipline:** The frontend has no test harness (no Vitest/Jest/Playwright). Per the spec's acceptance criterion 10, establishing one is its own bead. Tasks here use `npm run lint` + `npm run build` (the latter type-checks via `vite build`'s tsc step) as compile-gate substitutes, plus targeted manual browser checks. Don't introduce a test framework as part of this plan.

---

## File Structure

| Path | Responsibility |
|---|---|
| `aussie-kicks-tracker/src/lib/sneakerQueries.ts` (modify) | Add `fetchSaleColorways` + `fetchSaleColorwaysCount`. Pure query + rollup functions, no React. |
| `aussie-kicks-tracker/src/hooks/useSneakers.tsx` (modify) | Add `useSaleColorways` + `useSaleColorwaysCount` react-query hooks. Sort + page applied here over the cached rollup. |
| `aussie-kicks-tracker/src/components/SaleColorwayCard.tsx` (new) | Card: image, name, `was → NOW` block, `[On Sale]`/`[Lowest Ever]` badges, `Cheapest: …` + `Also: …` retailer chip rows. Click → `/sneaker/<id>?colorway=<id>` preserving filters. |
| `aussie-kicks-tracker/src/components/SignalChips.tsx` (new) | `All` / `On Sale` / `Lowest Ever` chip group. Reads + writes `?signal=`. |
| `aussie-kicks-tracker/src/components/SortDropdown.tsx` (new) | `% off` / `$ off` / `recent` dropdown. Reads + writes `?sort=`. |
| `aussie-kicks-tracker/src/pages/Sale.tsx` (new) | The route. Mounts FilterSidebar + SignalChips + SortDropdown + SaleColorwayCard grid + Pagination. Empty states. |
| `aussie-kicks-tracker/src/App.tsx` (modify) | Register `/sale` route. |
| `aussie-kicks-tracker/src/components/Header.tsx` (modify) | Add `Sale` button between brand and search. |
| `aussie-kicks-tracker/src/pages/Index.tsx` (modify) | Add the `🔥 N deals →` hero chip alongside the existing tiles. |
| `aussie-kicks-tracker/SITEMAP.md` (modify) | Add `/sale` to the route table + a full page section. |
| `spec.yaml` (modify) | Document the new `colorways` select shape used by `fetchSaleColorways`. |

---

## Task 1: Data layer — fetchSaleColorways, fetchSaleColorwaysCount, hooks

The data layer ships first because every later task depends on its types and signatures. The rollup is the central piece of logic; getting it right here lets the page consume a clean, fully-typed shape.

**Files:**
- Modify: `aussie-kicks-tracker/src/lib/sneakerQueries.ts`
- Modify: `aussie-kicks-tracker/src/hooks/useSneakers.tsx`

- [ ] **Step 1: Add types + `fetchSaleColorways` + `fetchSaleColorwaysCount` to sneakerQueries.ts**

Open `aussie-kicks-tracker/src/lib/sneakerQueries.ts`. At the bottom of the file (after `findCheapestRetailer`), append:

```ts
// ===================================================================
// /sale (sneaker_scout-5qf)
// ===================================================================

export type SaleSignal = 'all' | 'sale' | 'lowest';

export interface SaleColorwayRetailer {
  id: string;
  name: string;
  price: number;
  originalPrice: number | null;
  isOnSale: boolean;
  isLowestEver: boolean;
}

export interface SaleColorway {
  colorwayId: string;
  colorwayName: string;
  imageUrl: string | null;
  sneakerId: string;
  sneakerName: string;
  brandId: string;
  brandName: string;
  // Cheapest qualifying retailer; everything else hangs off this row.
  cheapest: SaleColorwayRetailer;
  // Other qualifying retailers (price asc, then name asc).
  alsoRetailers: SaleColorwayRetailer[];
  // Aggregates over all qualifying rows for the colorway.
  isOnSale: boolean;
  isLowestEver: boolean;
  // null when cheapest.originalPrice is null (lowest-ever-only qualifier).
  pctOff: number | null;
  absOff: number | null;
  // Latest last_updated across qualifying rows; drives `recent` sort.
  lastUpdated: string;
}

/** Maps the `signal` URL param to the prices `or=` filter expression. */
const SIGNAL_TO_FILTER: Record<SaleSignal, string> = {
  all: 'is_on_sale.eq.true,is_lowest_ever.eq.true',
  sale: 'is_on_sale.eq.true',
  lowest: 'is_lowest_ever.eq.true',
};

interface SaleRawColorway {
  id: string;
  name: string;
  image_url: string | null;
  sneakers: {
    id: string;
    name: string;
    brand: { id: string; name: string } | null;
  } | null;
  prices: Array<{
    price: number;
    original_price: number | null;
    is_on_sale: boolean;
    is_lowest_ever: boolean;
    last_updated: string;
    retailer: { id: string; name: string } | null;
  }>;
}

/**
 * Fetch every colorway that has at least one qualifying `prices` row, plus
 * the qualifying rows themselves. Returns one `SaleColorway` per colorway
 * with the cheapest qualifying retailer expanded and the rest listed as
 * `alsoRetailers`. Sort + page are applied by the calling hook.
 */
export async function fetchSaleColorways(
  signal: SaleSignal,
  retailerIds: string[],
  sizes: number[]
): Promise<SaleColorway[]> {
  const hasRetailer = retailerIds.length > 0;
  const hasSize = sizes.length > 0;

  // When a size filter is active, additionally inner-join sneaker_sizes
  // so the colorway only surfaces if it stocks one of those sizes.
  // Pattern copied verbatim from useSneakers.
  const selectShape = hasSize
    ? `
      id, name, image_url,
      sneakers!inner ( id, name, brand:brands ( id, name ) ),
      prices!inner (
        price, original_price, is_on_sale, is_lowest_ever, last_updated,
        retailer:retailers ( id, name )
      ),
      sneaker_sizes!inner ( retailer_id, is_available, sizes!inner(us_size) )
    `
    : `
      id, name, image_url,
      sneakers!inner ( id, name, brand:brands ( id, name ) ),
      prices!inner (
        price, original_price, is_on_sale, is_lowest_ever, last_updated,
        retailer:retailers ( id, name )
      )
    `;

  let query = supabase
    .from('colorways')
    .select(selectShape)
    .or(SIGNAL_TO_FILTER[signal], { foreignTable: 'prices' });

  if (hasRetailer) {
    query = query.in('prices.retailer_id', retailerIds);
  }
  if (hasSize) {
    query = query
      .in('sneaker_sizes.sizes.us_size', sizes)
      .eq('sneaker_sizes.is_available', true);
    if (hasRetailer) {
      query = query.in('sneaker_sizes.retailer_id', retailerIds);
    }
  }

  const { data, error } = await query;
  if (error) {
    console.error('fetchSaleColorways error:', error);
    return [];
  }

  return ((data ?? []) as unknown as SaleRawColorway[])
    .map(rolledUpFromRaw)
    .filter((x): x is SaleColorway => x !== null);
}

function rolledUpFromRaw(raw: SaleRawColorway): SaleColorway | null {
  if (!raw.sneakers || !raw.sneakers.brand) return null;
  if (!raw.prices || raw.prices.length === 0) return null;

  // Cheapest qualifying row: lowest price, ties broken by last_updated desc
  // then retailer.name asc. (Spec: "ties broken by last_updated desc (most
  // recent wins), then by retailer.name asc for stable rendering.")
  const rowsWithRetailer = raw.prices.filter((p) => p.retailer);
  if (rowsWithRetailer.length === 0) return null;

  const sorted = [...rowsWithRetailer].sort((a, b) => {
    if (a.price !== b.price) return a.price - b.price;
    if (a.last_updated !== b.last_updated) {
      return a.last_updated < b.last_updated ? 1 : -1;
    }
    const an = a.retailer!.name;
    const bn = b.retailer!.name;
    return an < bn ? -1 : an > bn ? 1 : 0;
  });

  const toRetailer = (p: SaleRawColorway['prices'][number]): SaleColorwayRetailer => ({
    id: p.retailer!.id,
    name: p.retailer!.name,
    price: p.price,
    originalPrice: p.original_price,
    isOnSale: p.is_on_sale,
    isLowestEver: p.is_lowest_ever,
  });

  const cheapest = toRetailer(sorted[0]);
  const alsoRetailers = sorted.slice(1).map(toRetailer);

  const isOnSale = rowsWithRetailer.some((p) => p.is_on_sale);
  const isLowestEver = rowsWithRetailer.some((p) => p.is_lowest_ever);

  // pctOff/absOff are computed from the cheapest row only.
  // Null when the cheapest row has no original_price (lowest-ever-only).
  let pctOff: number | null = null;
  let absOff: number | null = null;
  if (cheapest.originalPrice !== null && cheapest.originalPrice > 0) {
    absOff = cheapest.originalPrice - cheapest.price;
    pctOff = absOff / cheapest.originalPrice;
  }

  const lastUpdated = rowsWithRetailer.reduce(
    (acc, p) => (p.last_updated > acc ? p.last_updated : acc),
    rowsWithRetailer[0].last_updated
  );

  return {
    colorwayId: raw.id,
    colorwayName: raw.name,
    imageUrl: raw.image_url,
    sneakerId: raw.sneakers.id,
    sneakerName: raw.sneakers.name,
    brandId: raw.sneakers.brand.id,
    brandName: raw.sneakers.brand.name,
    cheapest,
    alsoRetailers,
    isOnSale,
    isLowestEver,
    pctOff,
    absOff,
    lastUpdated,
  };
}

/**
 * Cheap COUNT of qualifying colorways for one signal, optionally scoped by
 * retailers/sizes. Drives the chip totals on /sale. head:true so no rows
 * are pulled. When `retailerIds` and `sizes` are both empty and `signal`
 * is `'all'` this is also the unfiltered count for the Index hero chip.
 */
export async function fetchSaleColorwaysSignalCount(
  signal: SaleSignal,
  retailerIds: string[] = [],
  sizes: number[] = []
): Promise<number> {
  const hasRetailer = retailerIds.length > 0;
  const hasSize = sizes.length > 0;

  const selectShape = hasSize
    ? 'id, prices!inner(is_on_sale, is_lowest_ever), sneaker_sizes!inner(retailer_id, is_available, sizes!inner(us_size))'
    : 'id, prices!inner(is_on_sale, is_lowest_ever)';

  let query = supabase
    .from('colorways')
    .select(selectShape, { count: 'exact', head: true })
    .or(SIGNAL_TO_FILTER[signal], { foreignTable: 'prices' });

  if (hasRetailer) {
    query = query.in('prices.retailer_id', retailerIds);
  }
  if (hasSize) {
    query = query
      .in('sneaker_sizes.sizes.us_size', sizes)
      .eq('sneaker_sizes.is_available', true);
    if (hasRetailer) {
      query = query.in('sneaker_sizes.retailer_id', retailerIds);
    }
  }

  const { count, error } = await query;
  if (error) {
    console.error('fetchSaleColorwaysSignalCount error:', error);
    return 0;
  }
  return count ?? 0;
}

/**
 * Unfiltered, signal='all' count for the Index hero chip. Thin wrapper
 * around fetchSaleColorwaysSignalCount so the hero query has its own
 * cache key (it doesn't share filters with /sale).
 */
export async function fetchSaleColorwaysCount(): Promise<number> {
  return fetchSaleColorwaysSignalCount('all', [], []);
}
```

- [ ] **Step 2: Add `useSaleColorways` + `useSaleColorwaysCount` to useSneakers.tsx**

Open `aussie-kicks-tracker/src/hooks/useSneakers.tsx`. Add this import at the top of the file (alongside the existing import from `@/lib/sneakerQueries`):

```ts
import {
  fetchRetailersForSneaker as fetchRetailers,
  fetchPriceHistory as fetchHistory,
  fetchSaleColorways,
  fetchSaleColorwaysCount,
  fetchSaleColorwaysSignalCount,
  type SaleColorway,
  type SaleSignal,
} from '@/lib/sneakerQueries';
```

(Replace the existing `import { fetchRetailersForSneaker ... } from '@/lib/sneakerQueries';` line with the block above.)

Then at the bottom of the file (after `useRetailers`), append:

```ts
export type SaleSort = 'pct' | 'abs' | 'recent';

export interface PaginatedSaleColorways {
  data: SaleColorway[];
  total: number;
  totalPages: number;
  currentPage: number;
}

/**
 * Sale-page hook. Pulls every qualifying colorway via fetchSaleColorways,
 * applies `sort` over the rollup result, then slices for `page`. Pagination
 * is client-side per the spec (sort runs on a computed field; server-side
 * pagination would need a Postgres RPC, deferred).
 *
 * Cache key intentionally excludes page + sort: the rollup is the expensive
 * bit and we want a single fetch per (signal, retailerIds, sizes) tuple.
 */
export const useSaleColorways = (
  page: number = 1,
  limit: number = 20,
  retailerIds: string[] = [],
  sizes: number[] = [],
  signal: SaleSignal = 'all',
  sort: SaleSort = 'pct'
) => {
  const retailerKey = [...retailerIds].sort().join(',');
  const sizeKey = [...sizes].sort((a, b) => a - b).join(',');

  return useQuery({
    queryKey: ['saleColorways', signal, retailerKey, sizeKey],
    queryFn: () => fetchSaleColorways(signal, retailerIds, sizes),
    select: (rows): PaginatedSaleColorways => {
      const sorted = [...rows].sort((a, b) => compareForSort(a, b, sort));
      const total = sorted.length;
      const offset = (page - 1) * limit;
      return {
        data: sorted.slice(offset, offset + limit),
        total,
        totalPages: Math.max(1, Math.ceil(total / limit)),
        currentPage: page,
      };
    },
  });
};

function compareForSort(a: SaleColorway, b: SaleColorway, sort: SaleSort): number {
  if (sort === 'recent') {
    // last_updated desc
    return a.lastUpdated < b.lastUpdated ? 1 : a.lastUpdated > b.lastUpdated ? -1 : 0;
  }
  // pct + abs: rows with null pctOff/absOff (lowest-ever-only) sort last.
  // Within ranked rows, tiebreak by lastUpdated desc.
  const aKey = sort === 'pct' ? a.pctOff : a.absOff;
  const bKey = sort === 'pct' ? b.pctOff : b.absOff;
  if (aKey === null && bKey === null) {
    return a.lastUpdated < b.lastUpdated ? 1 : -1;
  }
  if (aKey === null) return 1;
  if (bKey === null) return -1;
  if (aKey !== bKey) return bKey - aKey; // desc
  return a.lastUpdated < b.lastUpdated ? 1 : -1;
}

/** Total qualifying colorways with no filters — for the Index hero chip. */
export const useSaleColorwaysCount = () => {
  return useQuery({
    queryKey: ['saleColorwaysCount'],
    queryFn: fetchSaleColorwaysCount,
  });
};

/**
 * Per-signal qualifying count with the active retailer/size filters
 * applied. Drives the (N) numbers next to each chip on /sale. head:true
 * count under the hood — cheap.
 */
export const useSaleColorwaysSignalCount = (
  signal: SaleSignal,
  retailerIds: string[] = [],
  sizes: number[] = []
) => {
  const retailerKey = [...retailerIds].sort().join(',');
  const sizeKey = [...sizes].sort((a, b) => a - b).join(',');
  return useQuery({
    queryKey: ['saleColorwaysSignalCount', signal, retailerKey, sizeKey],
    queryFn: () => fetchSaleColorwaysSignalCount(signal, retailerIds, sizes),
  });
};
```

- [ ] **Step 3: Type-check + lint**

```bash
cd /workspace/aussie-kicks-tracker
npm run lint 2>&1 | tail -30
npm run build 2>&1 | tail -20
```

Expected: lint shows 0 new errors/warnings attributable to the new code; build completes with `✓ built in …ms`. If `build` reports type errors in `sneakerQueries.ts` or `useSneakers.tsx`, FIX before proceeding — most likely culprit is the `as unknown as SaleRawColorway[]` cast or a missing field.

Common gotcha: PostgREST returns inner-joined relations as objects when single-row, arrays when many. The `SaleRawColorway` interface declares `sneakers` as a single object and `brand` as a single object, matching the embed shape (`!inner` resolves single relations as objects). If the runtime gives an array, the rollup will return null and the colorway gets dropped — verify with a manual query in Step 4 if needed.

- [ ] **Step 4: Smoke the query in a dev console**

Run the dev server and exercise the hook in the browser before any UI exists:

```bash
npm run dev
```

Open `http://localhost:8080`, open devtools console, paste and run:

```js
// Borrowed from window.supabase? It's not exposed by default. Easier:
// just import the function via dynamic import.
const { fetchSaleColorways, fetchSaleColorwaysCount } = await import('/src/lib/sneakerQueries.ts');
console.table((await fetchSaleColorways('all', [], [])).slice(0, 5).map(r => ({
  name: r.colorwayName,
  cheapestPrice: r.cheapest.price,
  was: r.cheapest.originalPrice,
  pctOff: r.pctOff,
  onSale: r.isOnSale,
  lowest: r.isLowestEver,
  alsoCount: r.alsoRetailers.length,
})));
console.log('count:', await fetchSaleColorwaysCount());
```

Expected: prints a table of up to 5 qualifying colorways with sensible values, and a count >= the number of rows. If `fetchSaleColorways` returns `[]` and `fetchSaleColorwaysCount` returns 0, the live DB has no `is_on_sale=true` / `is_lowest_ever=true` rows yet — re-run the hypedc upload (`python -m data_upload.run_update --file=jsons/hypedc_products.json` from `sneaker-scout-backend/`) to populate flags.

If you see Postgres errors about unknown columns `is_on_sale` / `is_lowest_ever`, the 7bl migration didn't apply — STOP and surface to the user.

Stop the dev server (Ctrl+C) before committing.

- [ ] **Step 5: Commit**

```bash
cd /workspace
git add aussie-kicks-tracker/src/lib/sneakerQueries.ts \
        aussie-kicks-tracker/src/hooks/useSneakers.tsx
git commit -m "$(cat <<'EOF'
feat(sneaker_scout-5qf): data layer for /sale page

fetchSaleColorways anchors on colorways with an inner join on prices,
filtered by or=(is_on_sale.eq.true,is_lowest_ever.eq.true) on the
foreign table. Per-colorway rollup picks the cheapest qualifying
retailer for the headline row, lists the rest as alsoRetailers,
derives onSale/lowestEver from the inline rows, and computes
pctOff/absOff from the cheapest row's original_price.

useSaleColorways wraps that in react-query and applies sort + page
client-side over the cached rollup. useSaleColorwaysCount is a cheap
head:true count for the Index hero chip.

Sort runs post-rollup because the sort keys (pctOff, absOff) only
exist after the rollup. Pagination is therefore client-side; a
Postgres RPC would let us paginate server-side and is filed as a
follow-up.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: UI primitives — SignalChips, SortDropdown, SaleColorwayCard

Three independent components. None depend on each other; the page assembles them in Task 3. Building them in one task keeps related work together and lets a single lint+build catch any cross-component type drift early.

**Files:**
- Create: `aussie-kicks-tracker/src/components/SignalChips.tsx`
- Create: `aussie-kicks-tracker/src/components/SortDropdown.tsx`
- Create: `aussie-kicks-tracker/src/components/SaleColorwayCard.tsx`

- [ ] **Step 1: Create SignalChips**

Create `aussie-kicks-tracker/src/components/SignalChips.tsx`:

```tsx
import { Button } from '@/components/ui/button';
import { useSearchParams } from 'react-router-dom';
import type { SaleSignal } from '@/lib/sneakerQueries';

interface SignalChipsProps {
  totals: Record<SaleSignal, number>;
}

const ORDER: SaleSignal[] = ['all', 'sale', 'lowest'];
const LABELS: Record<SaleSignal, string> = {
  all: 'All',
  sale: 'On Sale',
  lowest: 'Lowest Ever',
};

export const SignalChips = ({ totals }: SignalChipsProps) => {
  const [searchParams, setSearchParams] = useSearchParams();
  const current: SaleSignal =
    (searchParams.get('signal') as SaleSignal) || 'all';

  const setSignal = (next: SaleSignal) => {
    setSearchParams((prev) => {
      const params = new URLSearchParams(prev);
      if (next === 'all') params.delete('signal');
      else params.set('signal', next);
      return params;
    });
  };

  return (
    <div className="inline-flex items-center rounded-md border bg-muted/30 p-0.5">
      {ORDER.map((s) => (
        <Button
          key={s}
          variant={current === s ? 'default' : 'ghost'}
          size="sm"
          onClick={() => setSignal(s)}
          aria-pressed={current === s}
        >
          {LABELS[s]} ({totals[s]})
        </Button>
      ))}
    </div>
  );
};
```

- [ ] **Step 2: Create SortDropdown**

Create `aussie-kicks-tracker/src/components/SortDropdown.tsx`:

```tsx
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { useSearchParams } from 'react-router-dom';
import type { SaleSort } from '@/hooks/useSneakers';

const OPTIONS: { value: SaleSort; label: string }[] = [
  { value: 'pct', label: '% off' },
  { value: 'abs', label: '$ off' },
  { value: 'recent', label: 'Most recent' },
];

export const SortDropdown = () => {
  const [searchParams, setSearchParams] = useSearchParams();
  const current: SaleSort =
    (searchParams.get('sort') as SaleSort) || 'pct';

  const setSort = (next: SaleSort) => {
    setSearchParams((prev) => {
      const params = new URLSearchParams(prev);
      if (next === 'pct') params.delete('sort');
      else params.set('sort', next);
      return params;
    });
  };

  return (
    <Select value={current} onValueChange={(v) => setSort(v as SaleSort)}>
      <SelectTrigger className="w-[160px]">
        <SelectValue />
      </SelectTrigger>
      <SelectContent>
        {OPTIONS.map((o) => (
          <SelectItem key={o.value} value={o.value}>
            Sort: {o.label}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  );
};
```

- [ ] **Step 3: Create SaleColorwayCard**

Create `aussie-kicks-tracker/src/components/SaleColorwayCard.tsx`:

```tsx
import { Card, CardContent } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Star } from 'lucide-react';
import { useNavigate, useLocation } from 'react-router-dom';
import { useAuth } from '@/hooks/useAuth';
import { useIsFavorite, useToggleFavorite } from '@/hooks/useFavorites';
import type { SaleColorway } from '@/lib/sneakerQueries';

interface SaleColorwayCardProps {
  row: SaleColorway;
}

const formatMoney = (n: number) => `$${n.toFixed(2).replace(/\.00$/, '')}`;

export const SaleColorwayCard = ({ row }: SaleColorwayCardProps) => {
  const { user } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();
  const isFavorited = useIsFavorite(row.sneakerId);
  const toggleFavorite = useToggleFavorite();

  const handleFavoriteClick = (e: React.MouseEvent) => {
    e.stopPropagation();
    if (!user) {
      navigate('/auth');
      return;
    }
    toggleFavorite.mutate({ sneakerId: row.sneakerId, isFavorited });
  };

  const handleCardClick = () => {
    // Preserve active retailers/sizes/etc. and pin which colorway is selected.
    const params = new URLSearchParams(location.search);
    params.set('colorway', row.colorwayId);
    // signal/sort are page-local; don't carry them into the detail page.
    params.delete('signal');
    params.delete('sort');
    navigate(`/sneaker/${row.sneakerId}?${params.toString()}`);
  };

  return (
    <Card
      className="cursor-pointer hover:shadow-lg transition-shadow relative group"
      onClick={handleCardClick}
    >
      <div className="relative">
        <img
          src={
            row.imageUrl ||
            'https://images.unsplash.com/photo-1549298916-b41d501d3772?w=400&h=400&fit=crop'
          }
          alt={`${row.sneakerName} — ${row.colorwayName}`}
          className="w-full h-48 object-cover rounded-t-lg"
        />

        <Button
          variant="ghost"
          size="icon"
          className="absolute top-2 right-2 bg-white/80 hover:bg-white"
          onClick={handleFavoriteClick}
        >
          <Star
            className={`h-4 w-4 ${
              isFavorited ? 'fill-yellow-400 text-yellow-400' : 'text-gray-600'
            }`}
          />
        </Button>

        <div className="absolute bottom-2 left-2 flex gap-1.5">
          {row.isOnSale && (
            <Badge className="bg-red-500 hover:bg-red-500 text-white">On Sale</Badge>
          )}
          {row.isLowestEver && (
            <Badge className="bg-emerald-600 hover:bg-emerald-600 text-white">
              Lowest Ever
            </Badge>
          )}
        </div>
      </div>

      <CardContent className="p-4 space-y-3">
        <div>
          <h3 className="font-semibold text-sm line-clamp-2">{row.sneakerName}</h3>
          <p className="text-xs text-muted-foreground">{row.brandName}</p>
          <p className="text-xs text-muted-foreground mt-1 line-clamp-1">
            {row.colorwayName}
          </p>
        </div>

        {/* was → NOW pricing block. If pctOff is null the row qualified via
            is_lowest_ever only and we just show NOW. */}
        <div className="flex items-baseline gap-2">
          {row.cheapest.originalPrice !== null && row.pctOff !== null && (
            <span className="text-xs text-muted-foreground line-through">
              {formatMoney(row.cheapest.originalPrice)}
            </span>
          )}
          <span className="font-bold text-lg">{formatMoney(row.cheapest.price)}</span>
          {row.absOff !== null && row.pctOff !== null && (
            <span className="text-xs text-green-600 font-medium">
              −{formatMoney(row.absOff)} ({Math.round(row.pctOff * 100)}% off)
            </span>
          )}
        </div>

        <div className="text-xs">
          <div className="text-muted-foreground">
            Cheapest: <span className="font-medium text-foreground">{row.cheapest.name}</span>
          </div>
          {row.alsoRetailers.length > 0 && (
            <div className="text-muted-foreground mt-0.5">
              Also: {row.alsoRetailers.map((r) => r.name).join(', ')}
            </div>
          )}
        </div>
      </CardContent>
    </Card>
  );
};
```

- [ ] **Step 4: Lint + build**

```bash
cd /workspace/aussie-kicks-tracker
npm run lint 2>&1 | tail -20
npm run build 2>&1 | tail -10
```

Expected: lint passes; `✓ built in …ms`.

If `useFavorites` import errors, check the actual export name in `src/hooks/useFavorites.tsx`. If `Select` from shadcn isn't installed, `ls src/components/ui/select.tsx` to verify — if missing, swap the SortDropdown implementation to use the existing dropdown-menu primitives (DropdownMenu/DropdownMenuTrigger/DropdownMenuItem) instead. The shadcn select primitive should be present (it's in the project's package.json via `@radix-ui/react-select`).

- [ ] **Step 5: Commit**

```bash
cd /workspace
git add aussie-kicks-tracker/src/components/SignalChips.tsx \
        aussie-kicks-tracker/src/components/SortDropdown.tsx \
        aussie-kicks-tracker/src/components/SaleColorwayCard.tsx
git commit -m "$(cat <<'EOF'
feat(sneaker_scout-5qf): UI primitives for /sale page

Three components, no page yet:
- SignalChips: All / On Sale / Lowest Ever, reads/writes ?signal=
- SortDropdown: % off / $ off / Most recent, reads/writes ?sort=
- SaleColorwayCard: image + name + was→NOW + badges + Cheapest/Also
  retailer chips. Click navigates to /sneaker/<id>?colorway=<id>
  with retailers+sizes preserved (signal/sort dropped — they're
  page-local).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Sale page — pages/Sale.tsx

Assembles the primitives. Has its own local `currentPage` state (same pattern as Index) and resets to page 1 on filter/signal/sort change. Reads `signal` and `sort` from URL params directly (not FilterContext, per spec — those params don't apply to `/` or `/admin`).

**Files:**
- Create: `aussie-kicks-tracker/src/pages/Sale.tsx`

- [ ] **Step 1: Create Sale page**

Create `aussie-kicks-tracker/src/pages/Sale.tsx`:

```tsx
import { useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { Header } from '@/components/Header';
import { FilterSidebar } from '@/components/FilterSidebar';
import { SignalChips } from '@/components/SignalChips';
import { SortDropdown } from '@/components/SortDropdown';
import { SaleColorwayCard } from '@/components/SaleColorwayCard';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import {
  Pagination,
  PaginationContent,
  PaginationItem,
  PaginationLink,
  PaginationNext,
  PaginationPrevious,
} from '@/components/ui/pagination';
import { Flame } from 'lucide-react';
import { useFilters } from '@/contexts/FilterContext';
import {
  useSaleColorways,
  useSaleColorwaysSignalCount,
  type SaleSort,
} from '@/hooks/useSneakers';
import type { SaleSignal } from '@/lib/sneakerQueries';

const ITEMS_PER_PAGE = 20;

const Sale = () => {
  const [searchParams] = useSearchParams();
  const { selectedRetailerIds, selectedSizes, clearAll, hasAnyFilter } = useFilters();
  const signal: SaleSignal = (searchParams.get('signal') as SaleSignal) || 'all';
  const sort: SaleSort = (searchParams.get('sort') as SaleSort) || 'pct';

  const [currentPage, setCurrentPage] = useState(1);
  const filterKey = `${signal}|${sort}|${selectedRetailerIds.join(',')}|${selectedSizes.join(',')}`;
  useEffect(() => {
    setCurrentPage(1);
  }, [filterKey]);

  // Chip totals: three cheap head:true counts (one per signal). These
  // share filter scope with the page but are independent of the active
  // signal — each chip always shows its own total under current filters.
  const { data: allCount = 0 } = useSaleColorwaysSignalCount(
    'all',
    selectedRetailerIds,
    selectedSizes
  );
  const { data: saleCount = 0 } = useSaleColorwaysSignalCount(
    'sale',
    selectedRetailerIds,
    selectedSizes
  );
  const { data: lowestCount = 0 } = useSaleColorwaysSignalCount(
    'lowest',
    selectedRetailerIds,
    selectedSizes
  );

  const totals = useMemo<Record<SaleSignal, number>>(
    () => ({ all: allCount, sale: saleCount, lowest: lowestCount }),
    [allCount, saleCount, lowestCount]
  );

  const { data, isLoading } = useSaleColorways(
    currentPage,
    ITEMS_PER_PAGE,
    selectedRetailerIds,
    selectedSizes,
    signal,
    sort
  );
  const rows = data?.data ?? [];
  const total = data?.total ?? 0;
  const totalPages = data?.totalPages ?? 1;

  const handleClearFilters = () => {
    clearAll(); // retailers + sizes
    // Reset signal/sort via URL nav — clearAll only handles FilterContext params.
    const params = new URLSearchParams(searchParams);
    params.delete('signal');
    params.delete('sort');
    window.history.replaceState(null, '', `${window.location.pathname}?${params.toString()}`);
    setCurrentPage(1);
  };

  return (
    <div className="min-h-screen bg-gradient-to-br from-gray-50 to-gray-100">
      <Header />

      <div className="container mx-auto px-4 py-6">
        <div className="flex items-center gap-3 mb-6">
          <Flame className="h-7 w-7 text-orange-500" />
          <h1 className="text-2xl font-bold">Deals</h1>
          <span className="text-sm text-muted-foreground">
            {total} {total === 1 ? 'deal' : 'deals'} matching your filters
          </span>
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-4 gap-6">
          <div className="lg:col-span-1">
            <FilterSidebar />
          </div>

          <div className="lg:col-span-3 space-y-6">
            <Card>
              <CardHeader>
                <div className="flex items-center justify-between flex-wrap gap-2">
                  <CardTitle>Sale &amp; price drops</CardTitle>
                  <div className="flex items-center gap-2 flex-wrap">
                    <SignalChips totals={totals} />
                    <SortDropdown />
                  </div>
                </div>
              </CardHeader>
              <CardContent>
                {isLoading ? (
                  <div className="py-16 text-center text-muted-foreground">
                    Loading deals…
                  </div>
                ) : rows.length === 0 ? (
                  <div className="py-16 text-center space-y-4">
                    {totals.all === 0 ? (
                      <p className="text-muted-foreground">
                        No deals right now — check back tomorrow.
                      </p>
                    ) : (
                      <>
                        <p className="text-muted-foreground">
                          No deals match your filters.
                        </p>
                        <Button
                          variant="outline"
                          onClick={handleClearFilters}
                          disabled={!hasAnyFilter && signal === 'all'}
                        >
                          Clear filters
                        </Button>
                      </>
                    )}
                  </div>
                ) : (
                  <>
                    <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4">
                      {rows.map((row) => (
                        <SaleColorwayCard key={row.colorwayId} row={row} />
                      ))}
                    </div>

                    {totalPages > 1 && (
                      <div className="mt-8">
                        <Pagination>
                          <PaginationContent>
                            <PaginationItem>
                              <PaginationPrevious
                                href="#"
                                onClick={(e) => {
                                  e.preventDefault();
                                  if (currentPage > 1) setCurrentPage(currentPage - 1);
                                }}
                                className={
                                  currentPage === 1 ? 'pointer-events-none opacity-50' : ''
                                }
                              />
                            </PaginationItem>
                            {Array.from({ length: Math.min(5, totalPages) }, (_, i) => {
                              let pageNum: number;
                              if (totalPages <= 5) pageNum = i + 1;
                              else if (currentPage <= 3) pageNum = i + 1;
                              else if (currentPage >= totalPages - 2)
                                pageNum = totalPages - 4 + i;
                              else pageNum = currentPage - 2 + i;
                              return (
                                <PaginationItem key={pageNum}>
                                  <PaginationLink
                                    href="#"
                                    isActive={pageNum === currentPage}
                                    onClick={(e) => {
                                      e.preventDefault();
                                      setCurrentPage(pageNum);
                                    }}
                                  >
                                    {pageNum}
                                  </PaginationLink>
                                </PaginationItem>
                              );
                            })}
                            <PaginationItem>
                              <PaginationNext
                                href="#"
                                onClick={(e) => {
                                  e.preventDefault();
                                  if (currentPage < totalPages) setCurrentPage(currentPage + 1);
                                }}
                                className={
                                  currentPage === totalPages
                                    ? 'pointer-events-none opacity-50'
                                    : ''
                                }
                              />
                            </PaginationItem>
                          </PaginationContent>
                        </Pagination>
                        <div className="text-center mt-4 text-sm text-muted-foreground">
                          Showing {(currentPage - 1) * ITEMS_PER_PAGE + 1}–
                          {Math.min(currentPage * ITEMS_PER_PAGE, total)} of {total}
                        </div>
                      </div>
                    )}
                  </>
                )}
              </CardContent>
            </Card>
          </div>
        </div>
      </div>
    </div>
  );
};

export default Sale;
```

- [ ] **Step 2: Lint + build**

```bash
cd /workspace/aussie-kicks-tracker
npm run lint 2>&1 | tail -20
npm run build 2>&1 | tail -10
```

Expected: lint passes; build completes.

- [ ] **Step 3: Commit**

```bash
cd /workspace
git add aussie-kicks-tracker/src/pages/Sale.tsx
git commit -m "$(cat <<'EOF'
feat(sneaker_scout-5qf): Sale page assembling primitives

Mounts FilterSidebar + SignalChips + SortDropdown + SaleColorwayCard
grid + Pagination. Reads ?signal= and ?sort= from URL; reuses
FilterContext for ?retailers= and ?sizes= so they're shared with /.
Local currentPage state resets when any filter/signal/sort changes.

Empty states: "No deals right now" when the unfiltered catalog has
nothing flagged, "No deals match your filters" with a Clear filters
button otherwise.

Route registration + Header link + Index hero chip land in the
next commit.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Wire-up — route registration + Header link + Index hero chip

Three small edits that make the page reachable. Doing them together (one commit) because none are useful in isolation.

**Files:**
- Modify: `aussie-kicks-tracker/src/App.tsx`
- Modify: `aussie-kicks-tracker/src/components/Header.tsx`
- Modify: `aussie-kicks-tracker/src/pages/Index.tsx`

- [ ] **Step 1: Register the route in App.tsx**

Open `aussie-kicks-tracker/src/App.tsx`. After the `import TestPage from "./pages/TestPage";` line, add:

```tsx
import Sale from "./pages/Sale";
```

Then in the `<Routes>` block (currently lines 27–35), add the `/sale` route between `/sneaker/:id` and `/admin`:

```tsx
              <Route path="/" element={<Index />} />
              <Route path="/auth" element={<Auth />} />
              <Route path="/favorites" element={<Favorites />} />
              <Route path="/sneaker/:id" element={<SneakerDetail />} />
              <Route path="/sale" element={<Sale />} />
              <Route path="/admin" element={<Admin />} />
              <Route path="/test" element={<TestPage />} />
              <Route path="*" element={<NotFound />} />
```

- [ ] **Step 2: Add the Sale link to Header**

Open `aussie-kicks-tracker/src/components/Header.tsx`. The current Header has a brand block (`<div className="flex items-center space-x-4">`, lines 24–31) followed by a right-aligned block (`<div className="flex flex-1 items-center justify-end space-x-4">`, lines 33+).

Add a nav link inside the brand block, immediately after the brand `<div className="flex items-center space-x-2 cursor-pointer" onClick={() => navigate('/')}>...</div>` block. The brand block becomes:

```tsx
        <div className="flex items-center space-x-4">
          <div className="flex items-center space-x-2 cursor-pointer" onClick={() => navigate('/')}>
            <TrendingUp className="h-6 w-6 text-blue-600" />
            <h1 className="text-xl font-bold bg-gradient-to-r from-blue-600 to-purple-600 bg-clip-text text-transparent">
              SneakTrack AU
            </h1>
          </div>
          <Button
            variant="ghost"
            size="sm"
            onClick={() => navigate('/sale')}
            className="text-sm font-medium"
          >
            Sale
          </Button>
        </div>
```

(`Button` is already imported in Header.tsx — no new import needed.)

- [ ] **Step 3: Add the Index hero chip**

Open `aussie-kicks-tracker/src/pages/Index.tsx`. Add `useSaleColorwaysCount` to the existing `useSneakers` import (line 14):

```tsx
import { useSneakers, useColorwaysCount, useSaleColorwaysCount, type Sneaker } from "@/hooks/useSneakers";
```

Add an import for `Link` from react-router-dom alongside the existing `useSearchParams` import (line 3):

```tsx
import { Link, useSearchParams } from "react-router-dom";
```

Inside the `Index` component, alongside the existing `useColorwaysCount` call (line 48), add:

```tsx
  const { data: dealsCount = 0 } = useSaleColorwaysCount();
```

The Stats Cards section currently has two tiles (Total Sneakers, Total Colorways) in a `grid-cols-1 md:grid-cols-2`. Change the grid to three columns and add a third tile linking to `/sale`. Replace the entire Stats Cards block (lines ~115–139):

```tsx
        {/* Stats Cards */}
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-6">
          <Card className="bg-gradient-to-r from-blue-500 to-blue-600 text-white">
            <CardContent className="p-4">
              <div className="flex items-center justify-between">
                <div>
                  <p className="text-blue-100 text-sm">Total Sneakers</p>
                  <p className="text-2xl font-bold">{totalSneakers}</p>
                </div>
                <Package className="h-8 w-8 text-blue-200" />
              </div>
            </CardContent>
          </Card>

          <Card className="bg-gradient-to-r from-purple-500 to-purple-600 text-white">
            <CardContent className="p-4">
              <div className="flex items-center justify-between">
                <div>
                  <p className="text-purple-100 text-sm">Total Colorways</p>
                  <p className="text-2xl font-bold">{colorwaysTotal}</p>
                </div>
                <Layers className="h-8 w-8 text-purple-200" />
              </div>
            </CardContent>
          </Card>

          <Link to="/sale" className="block">
            <Card className="bg-gradient-to-r from-orange-500 to-red-500 text-white cursor-pointer hover:brightness-110 transition">
              <CardContent className="p-4">
                <div className="flex items-center justify-between">
                  <div>
                    <p className="text-orange-100 text-sm">🔥 Deals</p>
                    <p className="text-2xl font-bold">{dealsCount} →</p>
                  </div>
                  <Package className="h-8 w-8 text-orange-200" />
                </div>
              </CardContent>
            </Card>
          </Link>
        </div>
```

(If `Package` is the wrong icon here, swap to `Flame` from lucide-react and add it to the existing lucide import at the top of the file. The plan picks `Package` to avoid adding a new import; the user can iterate on icon choice during manual review.)

- [ ] **Step 4: Lint + build**

```bash
cd /workspace/aussie-kicks-tracker
npm run lint 2>&1 | tail -20
npm run build 2>&1 | tail -10
```

Expected: lint passes; build completes.

- [ ] **Step 5: Manual browser smoke**

```bash
npm run dev
```

Open `http://localhost:8080`:
1. Confirm the new "🔥 Deals" tile appears in the stats row with a non-zero count.
2. Click the tile → lands on `/sale`. URL has no `signal=` / `sort=` params.
3. Click the `Sale` button in the header from `/sale` → no-op (already on /sale) or back to `/sale`. From `/` → navigates to `/sale`.
4. On `/sale`, click each signal chip (`All` / `On Sale` / `Lowest Ever`) and confirm:
   - The URL updates to `?signal=sale` or `?signal=lowest` (or removes the param for `all`).
   - The card grid changes content.
   - The chip totals stay consistent (each chip's count is the total for that signal, ignoring the active selection).
5. Change the sort dropdown to `% off`, `$ off`, `Most recent`. Confirm `?sort=` updates and card ordering changes.
6. Toggle a retailer in the FilterSidebar — both `/` and `/sale` filter by the same retailers. Navigate between them; the chip stays selected.
7. Click any card → lands on `/sneaker/<id>?colorway=<id>&retailers=...&sizes=...`. Hit browser back → returns to `/sale` with the same filters and signal/sort.
8. Force the empty state: select a retailer that has zero sale rows (or `?signal=lowest` if all qualifying rows are `is_on_sale` only). Confirm `No deals match your filters.` + `Clear filters` button appears. Click `Clear filters` — filters reset, grid repopulates.

If any of (1)–(8) fail, STOP and surface to the user before continuing. Stop the dev server with Ctrl+C.

- [ ] **Step 6: Commit**

```bash
cd /workspace
git add aussie-kicks-tracker/src/App.tsx \
        aussie-kicks-tracker/src/components/Header.tsx \
        aussie-kicks-tracker/src/pages/Index.tsx
git commit -m "$(cat <<'EOF'
feat(sneaker_scout-5qf): wire /sale route + header link + Index hero chip

App.tsx registers /sale under the FilterProvider so retailers/sizes
URL params are shared with /. Header gets a 'Sale' button next to
the brand. Index gets a third stats tile, '🔥 Deals N →', linking
to /sale. Count comes from useSaleColorwaysCount (cheap head:true
PostgREST count, no filters applied).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Living docs — SITEMAP.md + spec.yaml

Both are mandatory in the same diff as the route per CLAUDE.md. Splitting them into a separate task here for review focus; they could merge with Task 4 in a hurry but reviewers prefer to see them as a distinct doc commit.

**Files:**
- Modify: `aussie-kicks-tracker/SITEMAP.md`
- Modify: `spec.yaml`

- [ ] **Step 1: Update SITEMAP.md — route table**

Open `aussie-kicks-tracker/SITEMAP.md`. Add a row to the route table (between `/sneaker/:id` and `/admin`):

```markdown
| `/sale` | `pages/Sale.tsx` | public | Sale / price-drop listing — colorways with at least one `prices.is_on_sale=true` or `prices.is_lowest_ever=true` row |
```

- [ ] **Step 2: Update SITEMAP.md — full page section**

In the same file, add a new section between `/sneaker/:id` and `/admin` (after the `/sneaker/:id` section closes with `---`, before `## /admin — Admin stats`):

```markdown
## `/sale` — Sale / price-drop listing

**Component:** `src/pages/Sale.tsx`

**URL params** (all optional, all shareable):

| Param | Format | Purpose |
|---|---|---|
| `retailers` | `<id>,<id>` (UUIDs, comma-separated) | Restrict to colorways with a qualifying row at the selected retailers. Shared with `/` and `/admin` via `FilterContext`. |
| `sizes` | `<us>,<us>` (numbers, comma-separated) | Restrict to colorways that stock the selected US sizes. Shared via `FilterContext`. |
| `signal` | `all` \| `sale` \| `lowest` | Which signal drives membership: `is_on_sale` OR `is_lowest_ever` (default `all`), `is_on_sale` only, or `is_lowest_ever` only. |
| `sort` | `pct` \| `abs` \| `recent` | Sort order. `pct` (default) = % off desc; `abs` = $ off desc; `recent` = `last_updated` desc on cheapest qualifying row. |

**Pagination:** local component state, 20 per page, resets to page 1 on any filter/signal/sort change. Not URL-synced. Pagination is **client-side**: `useSaleColorways` pulls all qualifying rows for the (signal, retailers, sizes) tuple via react-query cache, then sorts + slices in the `select` callback.

**Data sources:**
- `useSaleColorways(page, limit, retailerIds, sizes, signal, sort)` — paginated qualifying colorways with cheapest-retailer rollup + `alsoRetailers` chips + `[On Sale]` / `[Lowest Ever]` badges + `pctOff` / `absOff` computed from the cheapest row's `original_price`.
- `useSaleColorwaysSignalCount(signal, retailerIds, sizes)` × 3 (one per signal) — cheap `head:true` PostgREST counts that drive the (N) labels on each chip without re-running the rollup.

**Components rendered:** `Header`, `FilterSidebar`, `SignalChips`, `SortDropdown`, `SaleColorwayCard`, `Pagination`.

**Empty states:**
- `No deals right now — check back tomorrow.` — total qualifying colorways (unfiltered) is 0.
- `No deals match your filters.` with a `Clear filters` button — current filter/signal combination yields 0 results.

---
```

- [ ] **Step 3: Also update Index section in SITEMAP.md**

The Index section's **Tiles** line currently reads `Total Sneakers, Total Colorways. (In Stock + Price Drops moved to /admin in sneaker_scout-jwl.)`. Update it to mention the new tile:

```markdown
**Tiles:** Total Sneakers, Total Colorways, 🔥 Deals (links to `/sale`). (In Stock + Price Drops moved to `/admin` in `sneaker_scout-jwl`.)
```

- [ ] **Step 4: Update spec.yaml**

Open `/workspace/spec.yaml`. The `/rest/v1/colorways` block is at line 332. Add a new `x-sale-query-example` field to it documenting the sale query shape. Find the existing `x-curl-example: |` block under `/rest/v1/colorways` (lines 353–355). Right after the `x-curl-example` block, add:

```yaml
      x-sale-query-example: |
        # fetchSaleColorways (src/lib/sneakerQueries.ts), signal=all,
        # no filters. The `or=` is applied on the prices foreign table.
        curl "$SUPABASE_URL/rest/v1/colorways?select=id,name,image_url,sneakers!inner(id,name,brand:brands(id,name)),prices!inner(price,original_price,is_on_sale,is_lowest_ever,last_updated,retailer:retailers(id,name))&prices.or=(is_on_sale.eq.true,is_lowest_ever.eq.true)" \
          -H "apikey: $SUPABASE_ANON_KEY"
      x-sale-count-example: |
        # fetchSaleColorwaysCount — drives the Index '🔥 Deals' tile.
        curl -I "$SUPABASE_URL/rest/v1/colorways?select=id,prices!inner(is_on_sale,is_lowest_ever)&prices.or=(is_on_sale.eq.true,is_lowest_ever.eq.true)" \
          -H "apikey: $SUPABASE_ANON_KEY" \
          -H "Prefer: count=exact"
```

- [ ] **Step 5: Commit**

```bash
cd /workspace
git add aussie-kicks-tracker/SITEMAP.md spec.yaml
git commit -m "$(cat <<'EOF'
docs(sneaker_scout-5qf): document /sale route in SITEMAP + spec.yaml

SITEMAP.md gets a row in the route table and a full section covering
URL params, pagination model, data sources, components, and empty
states. Index's Tiles line updated to reference the new Deals tile.

spec.yaml documents the sale-query shape under /rest/v1/colorways
(x-sale-query-example + x-sale-count-example) — the inner-join on
prices with the or= filter on the foreign table.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: End-to-end verification, file follow-ups, close 5qf

The page is built and committed. This task is the close-out: a final manual sanity check against the spec's acceptance criteria, file the follow-up beads named in the spec, and close 5qf.

- [ ] **Step 1: Re-run full lint + build**

```bash
cd /workspace/aussie-kicks-tracker
npm run lint 2>&1 | tail -10
npm run build 2>&1 | tail -10
```

Expected: lint passes; build completes with no errors.

If either fails, STOP — the work between Tasks 1–5 introduced a regression that needs fixing before close.

- [ ] **Step 2: Walk the acceptance criteria in the browser**

```bash
npm run dev
```

Open `http://localhost:8080` and check each spec acceptance criterion. The list lives in the spec (`docs/superpowers/specs/2026-05-15-sale-price-drop-page-design.md`, "Acceptance criteria" section). Tick each one off — if any fails, fix and add a new commit before continuing:

1. `/sale` loads, shows colorways with at least one qualifying row. ✓ / ✗
2. Signal chips drive `?signal=` and change the visible set. ✓ / ✗
3. Sort dropdown drives `?sort=` and changes order. ✓ / ✗
4. FilterSidebar retailers + sizes work and round-trip via URL; same selection persists between `/` and `/sale`. ✓ / ✗
5. Each card shows the cheapest retailer's `was → NOW` + badges + `Also: …` row when there's >1 qualifying retailer. ✓ / ✗
6. Clicking a card opens `/sneaker/<id>?colorway=<id>` with retailers+sizes preserved. ✓ / ✗
7. Header `Sale` button visible on `/` and `/admin`. ✓ / ✗
8. Index `🔥 Deals N →` tile shows correct count, navigates to `/sale`. ✓ / ✗
9. SITEMAP.md + spec.yaml updated in this branch's commits. ✓ / ✗
10. Lint + build clean; no `Math.random()` in the new code. ✓ / ✗

Stop the dev server with Ctrl+C.

Run a quick grep to confirm criterion 10's Math.random check:

```bash
grep -rn "Math.random" \
  aussie-kicks-tracker/src/pages/Sale.tsx \
  aussie-kicks-tracker/src/components/SaleColorwayCard.tsx \
  aussie-kicks-tracker/src/components/SignalChips.tsx \
  aussie-kicks-tracker/src/components/SortDropdown.tsx \
  aussie-kicks-tracker/src/hooks/useSneakers.tsx \
  aussie-kicks-tracker/src/lib/sneakerQueries.ts 2>&1 | grep -v "Binary file"
```

Expected: no matches. (The hook file has existing `Math.random()`-free code; we don't touch the legacy mock-data section.)

- [ ] **Step 3: File the follow-up beads**

The spec's "Out of scope" section names four follow-ups. File them now so they're not lost:

```bash
cd /workspace

bd create --title="Add colorways.gender + backfill + scraper emit + gender filter on / and /sale" \
  --type=feature --priority=1 \
  --description="No gender column on colorways today. The 505 migration standardised sizes to US-Men, so women's-only shoes are currently mis-sized. Scope: ALTER TABLE colorways ADD COLUMN gender text (enum: 'mens'|'womens'|'unisex'|'kids'), backfill existing rows as 'mens' (every current listing URL is mens-only), update each retailer scraper to emit gender per colorway, add gender filter chip to / and /sale. Spec'd in passing during sneaker_scout-5qf brainstorming — see docs/superpowers/specs/2026-05-15-sale-price-drop-page-design.md 'Out of scope' section."

bd create --title="Brand filter on /sale" \
  --type=feature --priority=3 \
  --description="V2 enhancement on /sale. FilterSidebar has a Brands section already; wire the checkboxes through to fetchSaleColorways via an additional .in('sneakers.brand_id', brandIds) clause. Deferred from sneaker_scout-5qf."

bd create --title="Price-band (min/max) filter on /sale" \
  --type=feature --priority=3 \
  --description="V2 enhancement. FilterSidebar has a Price Range slider that's currently inert; wire it through. Apply post-rollup against SaleColorway.cheapest.price (matches the headline price shown on each card). Deferred from sneaker_scout-5qf."

bd create --title="Promote /sale rollup to a Postgres RPC" \
  --type=task --priority=3 \
  --description="Tracking bead. Today fetchSaleColorways does the rollup client-side; pagination is client-side as a consequence. If query latency exceeds 500ms p95 or the qualifying set grows past a few thousand, define a get_sale_colorways(signal, retailer_ids, sizes, sort, offset, limit) SQL function returning the same SaleColorway shape and swap fetchSaleColorways from .from('colorways')... to .rpc('get_sale_colorways', ...). Hook signature stays unchanged. Deferred from sneaker_scout-5qf."
```

- [ ] **Step 4: Close 5qf and commit bd state**

```bash
cd /workspace
bd close sneaker-scout-5qf --reason="Sale page ships at /sale rendering is_on_sale + is_lowest_ever (per-colorway rollup, signal chips, sort, FilterContext-shared filters, Header link, Index hero chip). SITEMAP.md + spec.yaml updated. Follow-ups (gender schema, brand/price-band filters, RPC promotion) filed as separate beads."
git add .beads/
git commit -m "$(cat <<'EOF'
chore: bd state for sneaker_scout-5qf close + follow-ups filed

Closes sneaker_scout-5qf. Follow-up beads created for: gender
schema/scrapers/filter, brand filter on /sale, price-band filter on
/sale, RPC promotion of the /sale rollup.

Closes: sneaker_scout-5qf

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 5: Verify newly-unblocked work**

```bash
bd ready 2>&1 | head -15
```

Expected: the queue now shows the four newly-filed follow-up beads alongside the previously-blocked `sneaker-scout-adg: test filter persistence` (which was waiting on 5qf — should now be unblocked). Don't claim any of them; report the queue back to the user.

---

## Self-Review

**Spec coverage** (mapping spec sections → tasks):
- Route + URL contract — Task 4 Step 1 (route reg), Task 3 (reads params), Task 1 (hook applies them) ✓
- Page semantics (cheapest rollup, also retailers, badge derivation) — Task 1 Step 1 (`rolledUpFromRaw`) ✓
- UI components (Sale page, SaleColorwayCard, SignalChips, SortDropdown) — Tasks 2 + 3 ✓
- Header link — Task 4 Step 2 ✓
- Index hero chip — Task 4 Step 3 ✓
- Sort (pct/abs/recent + tie-breaks + null pctOff handling) — Task 1 Step 2 (`compareForSort`) ✓
- Data layer (`useSaleColorways`, `useSaleColorwaysCount`, `fetchSaleColorways`, `fetchSaleColorwaysCount`) — Task 1 ✓
- Query strategy v1 (PostgREST + client rollup, or= on foreign table) — Task 1 Step 1 ✓
- Empty states (no deals at all, no deals matching filters) — Task 3 Step 1 ✓
- No mock data (no `Math.random()` in new code) — Task 6 Step 2 grep ✓
- SITEMAP.md + spec.yaml — Task 5 ✓
- Acceptance criteria 1–10 — Task 6 Step 2 walks each one ✓
- Out-of-scope follow-ups (gender, brand filter, price-band filter, RPC promotion) — Task 6 Step 3 files all four ✓

**Placeholder scan:** No "TBD", "TODO", "implement later". Every code block is complete and runnable. The two callouts that flag possible adjustments (the `Package` icon choice in Task 4 Step 3, the SortDropdown fallback in Task 2 Step 4) are explicit conditional instructions, not handwaves.

**Type consistency:**
- `SaleColorway`, `SaleColorwayRetailer`, `SaleSignal`, `SaleRawColorway` defined in Task 1 Step 1; consumed in Task 1 Step 2 (`useSaleColorways`, `compareForSort`), Task 2 Step 1 (`SignalChips`), Task 2 Step 2 (`SortDropdown` uses `SaleSort`), Task 2 Step 3 (`SaleColorwayCard` uses `SaleColorway`), Task 3 Step 1 (`Sale` page uses all of them). Names spelled consistently.
- `SIGNAL_TO_FILTER` (Task 1) and `ORDER`/`LABELS` (Task 2 Step 1 SignalChips) both index by `SaleSignal` — same exhaustive enum.
- `SaleSort` defined in Task 1 Step 2; consumed by `SortDropdown` (Task 2 Step 2) and `Sale` (Task 3 Step 1). Consistent.
- The `useSaleColorways` signature `(page, limit, retailerIds, sizes, signal, sort)` is identical in declaration (Task 1 Step 2) and every call site (Task 3 Step 1).

**Risk to in-flight work:**
- Index.tsx's existing Stats Cards grid changes from 2 to 3 columns — visual layout shift, no behavioural risk. Manual smoke (Task 4 Step 5) catches it.
- Header.tsx adds a button before the brand div's existing children — no removal, no z-index change, no class changes elsewhere.
- App.tsx adds one Route — additive, doesn't touch existing routes.
- spec.yaml is appended-only under an existing path block — no key removal.
- SITEMAP.md additions sit in the same place the existing route conventions live.

**Open assumption to validate during execution:** PostgREST embed-with-array semantics. The `prices!inner(...)` embed on a `colorways` row should produce an array of qualifying prices rows. If runtime testing in Task 1 Step 4 shows the embed shape is different (e.g. single object when only one row matches), update `SaleRawColorway.prices` accordingly and re-run lint+build before continuing.
