# fsd: Card vertical alignment — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sneaker cards on `/`, `/sale`, and `/favorites` keep their price row aligned across a grid row regardless of whether the name fits on 1 or 2 lines.

**Architecture:** All three active card components render the sneaker name in `<h3 className="font-semibold text-sm line-clamp-2">`. `line-clamp-2` caps long names at 2 lines but leaves short names taking only 1 line — that's what causes the misalignment seen in `/workspace/image.png`, where the 2-line "Vans Classic Slip-On Checkerboard" pushed its `$49.99` lower than the `$109.99` / `$139.99` / `$139.99` in adjacent cards. The fix is a single Tailwind utility — `min-h-[2.5rem]` (= 2 × line-height of `text-sm`) — added to each h3 so the name container always reserves 2-line height. No structural changes.

**Tech Stack:** React + TypeScript + Tailwind CSS + shadcn/ui Card primitives.

---

## Reference

- Bug screenshot: `/workspace/image.png` — pre-fix state, 4-up grid showing the Checkerboard card's price sitting ~24px lower than its neighbours.
- Beads issue: `sneaker_scout-fsd`.

## Why `min-h-[2.5rem]`

Tailwind's `text-sm` is `font-size: 0.875rem; line-height: 1.25rem;`. Two lines = 2 × 1.25rem = **2.5rem**. Reserving that height matches the `line-clamp-2` ceiling exactly: short names still occupy 1 line of text but 2 lines of vertical space, so the row below (Colors / Price) starts at the same Y-position on every card.

This is the canonical product-grid pattern (Shopify, Etsy, Nike, Allbirds all use the same `clamp-2 + min-h` shape). It's a single utility per card — no flexbox restructure or fixed card height required.

## File Map

- Modify: `aussie-kicks-tracker/src/components/SneakerCardNew.tsx` (line 73) — used by `/` grouped view and `/favorites`
- Modify: `aussie-kicks-tracker/src/components/ColorwayCard.tsx` (line 81) — used by `/` split view
- Modify: `aussie-kicks-tracker/src/components/SaleColorwayCard.tsx` (line 84) — used by `/sale`
- **Not touched** — `aussie-kicks-tracker/src/components/SneakerCard.tsx`: confirmed dead code, no remaining imports. Follow-up cleanup, not this plan's scope.

## Padding / margin audit

Surveyed the three active cards. Current tokens:

| Card | Container | Name block | Inter-block |
|---|---|---|---|
| `SneakerCardNew` | `CardContent className="p-4"` | `mb-2` | `mb-3` between Colors and Price |
| `ColorwayCard` | `CardContent className="p-4"` | `mb-2` | no explicit gap before Price |
| `SaleColorwayCard` | `CardContent className="p-4 space-y-3"` | (inherits `space-y-3`) | uniform 0.75rem |

These are functionally close (all on Tailwind's spacing scale, `p-4` + ~`0.5rem`–`0.75rem` gaps). They use different idioms (`mb-*` vs `space-y-*`) but the actual rendered rhythm is consistent enough. **Token-normalization is out of scope for this fix** — it's a separate refactor and risks regression. If the price-row alignment still looks off after Task 1, file a follow-up bead. Don't bundle.

---

## Task 1: Reserve 2-line min-height on all active card name h3s

**Files:**
- Modify: `aussie-kicks-tracker/src/components/SneakerCardNew.tsx`
- Modify: `aussie-kicks-tracker/src/components/ColorwayCard.tsx`
- Modify: `aussie-kicks-tracker/src/components/SaleColorwayCard.tsx`

- [ ] **Step 1: Edit `SneakerCardNew.tsx`**

At line 73, change:

```tsx
<h3 className="font-semibold text-sm line-clamp-2">{sneaker.name}</h3>
```

to:

```tsx
<h3 className="font-semibold text-sm line-clamp-2 min-h-[2.5rem]">{sneaker.name}</h3>
```

- [ ] **Step 2: Edit `ColorwayCard.tsx`**

At line 81, change:

```tsx
<h3 className="font-semibold text-sm line-clamp-2">{sneaker.name}</h3>
```

to:

```tsx
<h3 className="font-semibold text-sm line-clamp-2 min-h-[2.5rem]">{sneaker.name}</h3>
```

- [ ] **Step 3: Edit `SaleColorwayCard.tsx`**

At line 84, change:

```tsx
<h3 className="font-semibold text-sm line-clamp-2">{row.sneakerName}</h3>
```

to:

```tsx
<h3 className="font-semibold text-sm line-clamp-2 min-h-[2.5rem]">{row.sneakerName}</h3>
```

- [ ] **Step 4: Build verification**

```bash
cd /workspace/aussie-kicks-tracker && npm run build
```

Expected: clean build. This is a pure className-string change — no TypeScript surface affected.

- [ ] **Step 5: Commit**

```bash
git -C /workspace/aussie-kicks-tracker add \
  src/components/SneakerCardNew.tsx \
  src/components/ColorwayCard.tsx \
  src/components/SaleColorwayCard.tsx
git -C /workspace/aussie-kicks-tracker commit -m "fix(sneaker_scout-fsd): reserve 2-line height on card name h3 so prices align in grid"
```

---

## Task 2: Browser smoke (no edits — verification only)

- [ ] **Step 1: Start the dev server**

```bash
cd /workspace/aussie-kicks-tracker && npm run dev
```

- [ ] **Step 2: Verify `/`**

Open http://localhost:8080/. Find a grid row that mixes 1-line and 2-line sneaker names (the Vans 4-up from `/workspace/image.png` is the reference). Confirm:

- All four price rows in the same grid row sit at the same Y-position
- 1-line names still render on a single line (only the *space below* is reserved)
- 2-line names still clamp at 2 lines (no overflow)

Toggle the `Grouped / Split` view to confirm the fix applies to both `SneakerCardNew` (grouped) and `ColorwayCard` (split).

- [ ] **Step 3: Verify `/sale`**

Open http://localhost:8080/sale. Same alignment check — `SaleColorwayCard` instances in each grid row should have their `$ XX.XX` price line aligned across columns.

- [ ] **Step 4: Verify `/favorites`**

Sign in, favourite at least one sneaker with a 1-line name and one with a 2-line name. Open http://localhost:8080/favorites. Confirm the same alignment behaviour (the page uses `SneakerCardNew`, so this is mostly a no-regression check).

- [ ] **Step 5: Close the bead**

```bash
cd /workspace
bd close sneaker_scout-fsd --reason="reserved 2-line min-height on sneaker card name h3 across SneakerCardNew, ColorwayCard, SaleColorwayCard"
git -C /workspace add .beads/
git -C /workspace commit -m "chore: bd state for sneaker_scout-fsd close"
```

---

## Risks and rollback

- **Empty name** — if `sneaker.name` is empty, the h3 reserves 2.5rem of empty space. Schema says `sneakers.name` is `NOT NULL`, so this can't happen. Acceptable.
- **Design-system font change** — if the name is ever bumped to `text-base` (line-height 1.5rem) or `text-lg`, the magic `2.5rem` becomes mismatched. Mitigation: switch to `min-h-[2lh]` (CSS `lh` unit, supported in evergreen browsers since ~2023). Don't pre-emptively switch — `text-sm` is the current truth and `2.5rem` is clearer to a reader.
- **Cards still misaligned after fix** — would mean a sibling element (Colors row, sub-name) also has variable height. Re-audit and file a follow-up if so. Initial inspection shows the second-line `<p>` in `ColorwayCard` and `SaleColorwayCard` is `line-clamp-1`, which always renders exactly 1 line — safe.
- **Rollback:** revert the single commit. CSS-only, zero data risk.

## Self-review checklist

- **Spec coverage:** Reserve 2-line min-height ✓ (Task 1). Audit padding/margin tokens ✓ (table above shows tokens are already on Tailwind's spacing scale; full normalization would be a separate refactor and is explicitly out of scope). Apply across all active card components ✓ (3 cards, with `SneakerCard.tsx` flagged as unused / dead-code follow-up).
- **Placeholders:** None — every step contains the actual className string and the exact diff.
- **Type consistency:** N/A — pure presentational change, no types touched.
- **Living docs:** No SITEMAP / spec.yaml / CLAUDE.md update needed (no route, schema, or CLI surface change).
- **Beads + commits:** One bd issue (`sneaker_scout-fsd`), one feature commit prefixed `fix(sneaker_scout-fsd)`, one bd-state commit on close.
