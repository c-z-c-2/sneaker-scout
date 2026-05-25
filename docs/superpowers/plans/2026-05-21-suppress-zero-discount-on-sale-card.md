# Suppress Zero-Discount Block on Sale Card — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On `SaleColorwayCard`, suppress the strike-through original price and the `−$X (Y% off)` markdown line when the displayed markdown is zero (cheapest row's `originalPrice === price`). Only show the current price in that case.

**Architecture:** Single conditional change in the existing JSX render block (`SaleColorwayCard.tsx:93-105`). The component already computes `pctOff` and `absOff` in `rolledUpFromRaw` (`sneakerQueries.ts:464-469`); we tighten the render-time guard. No query/data changes, no new props, no new types.

**Tech Stack:** React + TypeScript + Tailwind (existing `aussie-kicks-tracker/` frontend stack). No frontend test framework configured — verification is via the dev server in a real browser.

---

## Background & Why

The Sale page (`/sale`, signal `all`) surfaces colorways flagged either `is_on_sale` or `is_lowest_ever` on at least one prices row. `is_lowest_ever` is set by the uploader (`bulk_upload.py:298-302`) when `new_price <= historical_min_by_colorway` — note the `<=`, so a price that **ties** the historical minimum still qualifies. When the cheapest qualifying row has `original_price === price` (the retailer's RRP equals the current price, no markdown vs RRP), the `pctOff` value is `0`, not `null`. The current render guard only checks "is it non-null" so the card renders `$250 → $250  −$0 (0% off)` — a visually loud "discount" that contains no actual discount.

**The discount math is one formula regardless of which flag fired:** `absOff = originalPrice − price; pctOff = absOff / originalPrice`. The "Lowest Ever" badge is a separate label — it does not change the math. When a colorway is both `is_on_sale` AND `is_lowest_ever`, the displayed markdown is still RRP-vs-current.

**Out of scope (filed as follow-up):** Whether `is_lowest_ever` should require *strictly* lower than the historical min, or whether ties should keep qualifying. That's a backend semantics decision separate from this display fix.

## File Structure

- **Modify:** `aussie-kicks-tracker/src/components/SaleColorwayCard.tsx:91-105` — tighten the conditional on the "was → NOW" pricing block so the strike-through and the `−$X (Y% off)` span only render when there's a real markdown.

No other files change. The data shape (`SaleColorway`) already exposes `cheapest.originalPrice`, `cheapest.price`, `absOff`, and `pctOff` — we only adjust how they're rendered.

---

## Task 1: Suppress the markdown block when there's no actual discount

**Files:**
- Modify: `aussie-kicks-tracker/src/components/SaleColorwayCard.tsx:91-105`

- [ ] **Step 1: Read the current pricing block**

Open `aussie-kicks-tracker/src/components/SaleColorwayCard.tsx`. Lines 91-105 contain:

```tsx
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
```

- [ ] **Step 2: Add a single derived flag at the top of the component body**

Inside the `SaleColorwayCard` component (after the `useToggleFavorite()` line and before `handleFavoriteClick`), add:

```tsx
// True only when there's an actual markdown vs the retailer's RRP.
// Guards against rows that qualified for the Sale page via
// is_lowest_ever where originalPrice happens to equal price (yields
// $X → $X / −$0 / 0% off, which is visual noise rather than a deal).
const hasRealMarkdown =
  row.absOff !== null && row.pctOff !== null && row.absOff > 0;
```

- [ ] **Step 3: Replace the two conditionals in the pricing block with the new flag**

Replace the entire `<div className="flex items-baseline gap-2">` block (lines 93-105 of the original file) with:

```tsx
{/* was → NOW pricing block. Hidden entirely (just shows NOW) when
    the row qualified via is_lowest_ever only OR when originalPrice
    equals price (zero markdown). */}
<div className="flex items-baseline gap-2">
  {hasRealMarkdown && (
    <span className="text-xs text-muted-foreground line-through">
      {formatMoney(row.cheapest.originalPrice!)}
    </span>
  )}
  <span className="font-bold text-lg">{formatMoney(row.cheapest.price)}</span>
  {hasRealMarkdown && (
    <span className="text-xs text-green-600 font-medium">
      −{formatMoney(row.absOff!)} ({Math.round(row.pctOff! * 100)}% off)
    </span>
  )}
</div>
```

The non-null assertions (`!`) are safe because `hasRealMarkdown` requires `absOff !== null` and `pctOff !== null`, and `absOff > 0` implies `originalPrice !== null` (because `absOff = originalPrice - price` can only be > 0 when `originalPrice` is non-null — `rolledUpFromRaw` sets both `absOff` and `pctOff` to `null` together when `originalPrice` is null).

- [ ] **Step 4: Type-check the change**

Run from `aussie-kicks-tracker/`:

```bash
cd aussie-kicks-tracker
npm run build
```

Expected: build completes with no TypeScript errors. (Vite + tsc will surface any type issues from the non-null assertions.)

If the build fails with "Property X does not exist" or similar type errors, re-check that the assertions match the `SaleColorway` type in `src/lib/sneakerQueries.ts` (`originalPrice: number | null` on `cheapest`, `absOff: number | null` and `pctOff: number | null` at the row level).

- [ ] **Step 5: Verify in the browser (golden + edge cases)**

Start the dev server:

```bash
cd aussie-kicks-tracker
npm run dev
```

Visit `http://localhost:8080/sale?signal=all` (or whichever route renders the SaleColorwayCard). Verify:

1. **Real markdown** — a card where `original_price > price` still shows `$ORIG (strike) → $NOW  −$X (Y% off)` exactly as before.
2. **Zero markdown (the bug)** — a card where `original_price === price` (the `−$0 (0% off)` case the user reported) now shows only `$NOW` with no strike-through and no green discount line. The "Lowest Ever" badge (top-left, emerald) should still render — only the pricing line is affected.
3. **Lowest-ever-only with null original_price** — a card where `original_price` is null still shows only `$NOW` (unchanged behaviour).
4. **On Sale badge with real markdown** — `On Sale` badge + strike-through + green discount line all render together.

If you can't readily find a card in each state, look at the `Sale` page network response in DevTools and filter — every colorway row includes `cheapest.originalPrice`, `cheapest.price`, `absOff`, and `pctOff` so you can pick a UI sample for each.

- [ ] **Step 6: Commit**

```bash
cd aussie-kicks-tracker
git add src/components/SaleColorwayCard.tsx
git commit -m "$(cat <<'EOF'
fix(sneaker_scout-<id>): hide zero-discount block on SaleColorwayCard

When a colorway qualified for the Sale page via is_lowest_ever and
the retailer's RRP equaled the current price, the card rendered
"$X → $X  −$0 (0% off)" — a visually loud "discount" with no actual
markdown. Tighten the render guard so the strike-through original
price and the green "−$X (Y% off)" span only show when absOff > 0.
The "Lowest Ever" badge still renders separately and is unaffected.

Closes: sneaker_scout-<id>
EOF
)"
```

(Replace `<id>` with the bd issue ID once filed — see "Before starting" below.)

---

## Before starting

This plan assumes a bd issue has been filed for tracking. Run:

```bash
cd /workspace
bd create \
  --title="(BUG) Hide zero-discount markdown block on SaleColorwayCard" \
  --description="On /sale, cards that qualified via is_lowest_ever where original_price === price render the markdown block as '\$X → \$X −\$0 (0% off)'. Suppress the strike-through and discount span when absOff is 0; only show the current price." \
  --type=bug \
  --priority=2
```

Then use the returned ID in the commit trailer in Step 6.

Also file the related backend semantics question as a separate bd issue (do not block this plan on it):

```bash
bd create \
  --title="(DESIGN) Should is_lowest_ever fire on ties with historical_min, or only on strict drops?" \
  --description="bulk_upload.py:298-302 sets is_lowest_ever = (new_price <= historical_min). The <= means a price that ties the previous lowest still qualifies, which is what produces the '\$X → \$X' zero-markdown cards on /sale even after the frontend hides the discount span. Decide whether the flag should be strict (< only) and what the implication is for historical-tying daily re-scrapes." \
  --type=task \
  --priority=3
```

---

## Self-Review (done)

- **Spec coverage:** The user's explicit ask was "remove the discount block if it's the same price as the previous lowest price". The frontend has no "previous lowest price" datum, only `originalPrice` (RRP). The plan suppresses the block when `originalPrice === price` (`absOff === 0`), which is the actionable interpretation. The user's secondary question — what drives the % markdown when both flags fire — is answered in the Background section: it's always `(originalPrice − price) / originalPrice`.
- **Placeholders:** None — every step shows the exact code and command.
- **Type consistency:** `hasRealMarkdown` is declared once and used in both conditionals. Non-null assertions match the `SaleColorway` type in `sneakerQueries.ts` (`originalPrice`, `absOff`, `pctOff` all `number | null` and all set/unset together).
- **Test coverage:** No frontend test framework is set up in `aussie-kicks-tracker/`, so verification is manual via the dev server (Step 5 enumerates the four states).
