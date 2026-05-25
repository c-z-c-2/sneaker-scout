# Comprehensive Testing Suite — Salomon Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lock in salomon's listing parser, PDP parser, and `combine_product_info` against committed HTML fixtures so silent regressions (like `sneaker_scout-9wg` — the strike-price selector typo that ran broken for months) get caught immediately. This is the first slice of a per-retailer template; the other four retailers get their own follow-up beads issues.

**Architecture:**

- **Fixtures** live under `tests/fixtures/salomon/` as raw HTML files captured from the live site once and committed. Two listing-card snippets (regular + on-sale) and two full PDPs (regular + on-sale).
- **Tests** use BeautifulSoup directly on listing-card fixtures (the parser operates on a single product container, so a single card is the natural unit) and a tiny `FakeDriver` returning fixture HTML for PDP tests (matches the pattern already used in `tests/test_custom_url_cli.py`).
- **No production refactor.** The existing `extract_basic_info(product_container)` and `extract_detailed_info(product_url, driver, ...)` are testable as-is once we monkeypatch `WebDriverWait` to a no-op (same trick used in this session's platypus LOAD MORE tests).
- **Layer coverage** for this slice: listing parser (highest-leverage, where 9wg hid), PDP parser (most complex selectors), and `combine_product_info` (the seam where the singular/plural-key bug in `CLAUDE.md` lived). End-to-end smoke and uploader-side gender-PK regression are deferred — uploader regression belongs with the `sneaker_scout-4kx` fix.

**Tech Stack:** pytest, BeautifulSoup4, monkeypatch (for FakeDriver / WebDriverWait), the existing salomon scraper modules.

**Beads issue:** filed at start of Task 1 as `sneaker_scout-???` (assign after creating). Follow-up retailer issues filed in Task 6.

---

## File Structure

```
sneaker-scout-backend/
  tests/
    fixtures/
      __init__.py                       # NEW (empty, makes it importable)
      _helpers.py                       # NEW: load_fixture("salomon/...") helper
      salomon/
        listing_card_regular.html       # NEW: captured single product card
        listing_card_on_sale.html       # NEW: captured single product card w/ strike-price
        pdp_regular.html                # NEW: captured full PDP, no sale
        pdp_on_sale.html                # NEW: captured full PDP, with strike-through
    test_salomon_listing_parser.py      # NEW
    test_salomon_pdp_parser.py          # NEW
    test_salomon_combine.py             # NEW
  scripts/
    capture_salomon_fixtures.py         # NEW: one-shot helper, run manually to refresh fixtures
```

Files NOT touched by this slice:
- `salomon/pagination_scraper.py`, `salomon/single_product_page_scraper.py` — must remain bug-for-bug as-is so the tests lock in CURRENT (correct, post-9wg-fix) behavior, not aspirational behavior.

---

## Task 1: Beads issue + fixture infrastructure

**Files:**
- Create: `sneaker-scout-backend/tests/fixtures/__init__.py` (empty)
- Create: `sneaker-scout-backend/tests/fixtures/_helpers.py`
- Create: `sneaker-scout-backend/tests/fixtures/salomon/` (directory, populated in Task 2)

- [ ] **Step 1: File the umbrella beads issue**

Run from `/workspace`:
```bash
bd create \
  --title="Comprehensive testing suite (salomon slice)" \
  --description="First slice of the cross-retailer parser test suite. Locks in salomon's listing parser, PDP parser, and combine_product_info against committed HTML fixtures under tests/fixtures/salomon/. Designed to catch regressions like sneaker_scout-9wg (silent strike-price selector typo). Per-retailer follow-ups filed in Task 6 of this plan. Plan: docs/superpowers/plans/2026-05-21-comprehensive-testing-suite-salomon.md" \
  --type=task --priority=2
bd update <new-id> --claim
```

Record the issue ID — every commit in this plan uses it in the subject.

- [ ] **Step 2: Write the fixture-loader helper**

Create `sneaker-scout-backend/tests/fixtures/_helpers.py`:

```python
"""Tiny helper for loading HTML fixtures committed under tests/fixtures/.

Tests should call ``load_fixture("salomon/listing_card_on_sale.html")``
rather than computing paths inline — keeps the import surface small and
makes a future move of the fixtures tree a one-line edit."""
from pathlib import Path

_FIXTURES_DIR = Path(__file__).resolve().parent


def load_fixture(relative_path: str) -> str:
    """Return the text content of ``tests/fixtures/<relative_path>``.

    Raises FileNotFoundError if the fixture is missing — fail loud,
    don't silently return an empty string. UTF-8 is assumed (every
    retailer site we scrape is UTF-8)."""
    path = _FIXTURES_DIR / relative_path
    return path.read_text(encoding="utf-8")
```

Create `sneaker-scout-backend/tests/fixtures/__init__.py` as an empty file (makes the directory a package so the helper imports cleanly).

- [ ] **Step 3: Write a tiny smoke test for the helper**

Create `sneaker-scout-backend/tests/test_fixture_helpers.py`:

```python
import pytest
from tests.fixtures._helpers import load_fixture


def test_load_fixture_raises_on_missing():
    with pytest.raises(FileNotFoundError):
        load_fixture("salomon/does_not_exist.html")
```

- [ ] **Step 4: Run the smoke test**

Run from `sneaker-scout-backend/`:
```bash
python -m pytest tests/test_fixture_helpers.py -v
```

Expected: 1 passed.

- [ ] **Step 5: Commit**

Check the index first (per the [[feedback-nested-repo-dirty-index]] memory):
```bash
git -C /workspace/sneaker-scout-backend status -s
```

If any unrelated files are staged, `git reset HEAD` first. Then:
```bash
git -C /workspace/sneaker-scout-backend add \
  tests/fixtures/__init__.py \
  tests/fixtures/_helpers.py \
  tests/test_fixture_helpers.py
git -C /workspace/sneaker-scout-backend commit -m "test(<bd-id>): add fixture-loader helper under tests/fixtures/

Introduces tests/fixtures/_helpers.py with a single load_fixture(\"...\")
helper used by the salomon parser tests (and, eventually, every other
retailer's tests). Helper raises FileNotFoundError on a missing file
so a stale fixture path can't silently degrade a test into a no-op."
```

---

## Task 2: Capture salomon HTML fixtures

**Files:**
- Create: `sneaker-scout-backend/scripts/capture_salomon_fixtures.py`
- Create: `sneaker-scout-backend/tests/fixtures/salomon/listing_card_regular.html`
- Create: `sneaker-scout-backend/tests/fixtures/salomon/listing_card_on_sale.html`
- Create: `sneaker-scout-backend/tests/fixtures/salomon/pdp_regular.html`
- Create: `sneaker-scout-backend/tests/fixtures/salomon/pdp_on_sale.html`

This task captures live HTML once, commits it, and never re-runs in CI. The capture script is committed so anyone can refresh fixtures after a site redesign without re-deriving URLs.

- [ ] **Step 1: Write the capture script**

Create `sneaker-scout-backend/scripts/capture_salomon_fixtures.py`:

```python
"""One-shot helper: fetch salomon listing + PDP HTML and save under
tests/fixtures/salomon/.

Run manually when fixtures need refreshing (e.g. after a site redesign
breaks the existing fixtures). NOT imported by the test suite — the
captured *.html files are the test inputs, not this script.

Usage:
    cd sneaker-scout-backend
    python -m scripts.capture_salomon_fixtures
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

from bs4 import BeautifulSoup

# Reuse the production driver setup so capture matches the real scrape
# (headless, anti-detection flags, etc.). If salomon ever needs headed
# mode like HypeDC, that single change in salomon.pagination_scraper
# propagates here.
from salomon.pagination_scraper import setup_driver
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC


LISTING_URL = "https://salomon.com.au/collections/mens"
# Two PDP URLs: one regular-priced, one on-sale. If salomon's catalogue
# rotates these out, replace with current equivalents — only the HTML
# shape matters, not the specific products.
PDP_REGULAR_URL = "https://salomon.com.au/products/xt-6"
PDP_ON_SALE_URL = "https://salomon.com.au/products/xa-pro-3d-v9-gtx"

FIXTURES_DIR = Path(__file__).resolve().parents[1] / "tests" / "fixtures" / "salomon"


def _wait_for_listing(driver):
    WebDriverWait(driver, 20).until(
        EC.presence_of_element_located((By.CSS_SELECTOR, ".ss__results"))
    )


def _wait_for_pdp(driver):
    WebDriverWait(driver, 20).until(
        EC.presence_of_element_located(
            (By.CSS_SELECTOR, ".row.product-single, .product-single__title")
        )
    )


def capture_listing_cards(driver) -> tuple[str, str]:
    """Return (regular_card_html, on_sale_card_html) — two single product
    card snippets pulled from a live listing page. We isolate single
    cards so the fixtures match the unit of `extract_basic_info`, which
    operates on one product_container at a time."""
    driver.get(LISTING_URL)
    _wait_for_listing(driver)
    time.sleep(2)  # let lazy-loaded prices settle
    soup = BeautifulSoup(driver.page_source, "html.parser")

    # Salomon's grid uses .product-grid-item wrappers around each card.
    cards = soup.select(".product-grid-item")
    if not cards:
        sys.exit("No .product-grid-item containers found — selector drift?")

    # Pick one card with a strike-through price and one without.
    on_sale = next(
        (c for c in cards if c.select_one("[data-compare-price]")),
        None,
    )
    regular = next(
        (c for c in cards if not c.select_one("[data-compare-price]")),
        None,
    )
    if on_sale is None or regular is None:
        sys.exit(
            f"Could not find both a regular-priced AND on-sale card on {LISTING_URL}. "
            f"Pick a listing page that has both (try a seasonal collection)."
        )
    return str(regular), str(on_sale)


def capture_pdp(driver, url: str) -> str:
    driver.get(url)
    _wait_for_pdp(driver)
    time.sleep(2)
    return driver.page_source


def main():
    FIXTURES_DIR.mkdir(parents=True, exist_ok=True)
    driver = setup_driver()
    try:
        regular_card, on_sale_card = capture_listing_cards(driver)
        (FIXTURES_DIR / "listing_card_regular.html").write_text(regular_card, encoding="utf-8")
        (FIXTURES_DIR / "listing_card_on_sale.html").write_text(on_sale_card, encoding="utf-8")
        print(f"Wrote listing card fixtures to {FIXTURES_DIR}")

        (FIXTURES_DIR / "pdp_regular.html").write_text(
            capture_pdp(driver, PDP_REGULAR_URL), encoding="utf-8",
        )
        (FIXTURES_DIR / "pdp_on_sale.html").write_text(
            capture_pdp(driver, PDP_ON_SALE_URL), encoding="utf-8",
        )
        print(f"Wrote PDP fixtures to {FIXTURES_DIR}")
    finally:
        driver.quit()


if __name__ == "__main__":
    main()
```

Also create `sneaker-scout-backend/scripts/__init__.py` as an empty file so the script can be invoked with `python -m scripts.capture_salomon_fixtures`.

- [ ] **Step 2: Run the capture script**

```bash
cd sneaker-scout-backend
python -m scripts.capture_salomon_fixtures
```

Expected output:
```
Wrote listing card fixtures to .../tests/fixtures/salomon
Wrote PDP fixtures to .../tests/fixtures/salomon
```

If `PDP_ON_SALE_URL` doesn't currently point at an on-sale product, the script will succeed but the on-sale fixture will be regular-priced. Quickly verify the fixture file contains `data-compare-price` before continuing:
```bash
grep -c 'data-compare-price' tests/fixtures/salomon/pdp_on_sale.html
```
Expected: at least 1. If 0, pick a different `PDP_ON_SALE_URL` (browse https://salomon.com.au/collections/sale for current sale items), edit the script, re-run.

- [ ] **Step 3: Verify fixtures aren't tiny error pages**

```bash
wc -l tests/fixtures/salomon/*.html
```

Each file should be at least a few hundred lines. If any file is suspiciously small (say, < 50 lines), it's likely a captcha or error page — re-capture with a longer warm-up delay or in headed mode.

- [ ] **Step 4: Commit**

```bash
git -C /workspace/sneaker-scout-backend status -s   # check the index
# reset any unrelated pre-staged files: git reset HEAD <file>
git -C /workspace/sneaker-scout-backend add \
  scripts/__init__.py \
  scripts/capture_salomon_fixtures.py \
  tests/fixtures/salomon/
git -C /workspace/sneaker-scout-backend commit -m "test(<bd-id>): capture salomon HTML fixtures (listing + PDP, regular + on-sale)

Adds scripts/capture_salomon_fixtures.py and the four committed HTML
fixtures it produces. Listing fixtures are single product cards (the
unit extract_basic_info operates on); PDP fixtures are full pages.
The on-sale variants exist specifically to lock in the strike-through
original_price extraction (regression guard for sneaker_scout-9wg)."
```

---

## Task 3: Salomon listing parser tests

**Files:**
- Create: `sneaker-scout-backend/tests/test_salomon_listing_parser.py`

- [ ] **Step 1: Write the failing tests**

Create `sneaker-scout-backend/tests/test_salomon_listing_parser.py`:

```python
"""Unit tests for salomon.pagination_scraper.extract_basic_info.

Each test operates on a single product-card HTML fixture, parses it
with BeautifulSoup, and feeds the resulting tag into the parser. The
on-sale test is the regression guard for sneaker_scout-9wg (the
silently-dropped strike-through price)."""
from bs4 import BeautifulSoup

from salomon.pagination_scraper import extract_basic_info
from tests.fixtures._helpers import load_fixture


def _card(filename: str):
    """Parse a fixture file containing exactly one product card and
    return the root element. The capture script saves cards as the
    outer .product-grid-item element, so parsing the whole file and
    grabbing the first card matches what the production iterator
    feeds extract_basic_info."""
    soup = BeautifulSoup(load_fixture(filename), "html.parser")
    card = soup.select_one(".product-grid-item") or soup
    return card


def test_listing_regular_card_has_name_url_image_and_price():
    info = extract_basic_info(_card("salomon/listing_card_regular.html"))
    assert info.get("name"), "name must be present"
    assert info.get("url", "").startswith("https://salomon.com.au"), (
        "url must be absolute and salomon-hosted"
    )
    assert info.get("image_url"), "image_url must be present"
    assert info.get("price"), "price must be present"


def test_listing_regular_card_has_no_original_price_or_discount():
    """No sale → no strike-through, no percent-off chip. The combine
    fallback (original_price ← price) is intentional; the listing
    parser itself should not invent an original_price."""
    info = extract_basic_info(_card("salomon/listing_card_regular.html"))
    assert "original_price" not in info
    assert "discount_percentage" not in info


def test_listing_on_sale_card_extracts_sale_price():
    """The .product__price-single element is the current/sale price."""
    info = extract_basic_info(_card("salomon/listing_card_on_sale.html"))
    assert info.get("price"), "sale price must be extracted"


def test_listing_on_sale_card_extracts_strike_through_original_price():
    """REGRESSION GUARD for sneaker_scout-9wg.

    The strike-through <s> element carries data-compare-price='true'
    and both .product__price--strike and .ss__pricing--strike classes.
    If this assertion fails, someone broke the selector again — see
    commit bf7a06b for the original fix."""
    info = extract_basic_info(_card("salomon/listing_card_on_sale.html"))
    assert info.get("original_price"), (
        "strike-through compare-at price must be extracted as original_price "
        "(this was silently dropped pre-sneaker_scout-9wg)"
    )
    # Sanity: original price should not equal sale price on a discounted item.
    assert info["original_price"] != info.get("price"), (
        "original_price equals sale price — extraction likely fell back to "
        "the .product__price-single value (the 9wg regression)"
    )


def test_listing_on_sale_card_has_discount_percentage():
    info = extract_basic_info(_card("salomon/listing_card_on_sale.html"))
    assert info.get("discount_percentage"), (
        "discount percentage chip should be extracted on sale items"
    )
```

- [ ] **Step 2: Run the tests**

```bash
cd sneaker-scout-backend
python -m pytest tests/test_salomon_listing_parser.py -v
```

Expected: 5 passed. If any fail, the fixture doesn't match the parser's expectations — inspect the fixture file vs the parser's selectors, fix whichever is wrong, re-run.

Common gotcha: if the on-sale-card fixture turns out to be regular-priced (capture-time drift), `test_listing_on_sale_card_extracts_strike_through_original_price` will fail. In that case the **fixture** is wrong, not the test — re-capture with a different on-sale product.

- [ ] **Step 3: Commit**

```bash
git -C /workspace/sneaker-scout-backend status -s
git -C /workspace/sneaker-scout-backend add tests/test_salomon_listing_parser.py
git -C /workspace/sneaker-scout-backend commit -m "test(<bd-id>): salomon listing-parser tests w/ strike-price regression guard

Five tests against tests/fixtures/salomon/listing_card_{regular,on_sale}.html.
The on-sale tests are the regression guard for sneaker_scout-9wg: if the
strike-through compare-at price ever stops landing in original_price (or
silently equals the sale price), these tests fail immediately instead of
the bug shipping to prod and running broken for months."
```

---

## Task 4: Salomon PDP parser tests

**Files:**
- Create: `sneaker-scout-backend/tests/test_salomon_pdp_parser.py`

- [ ] **Step 1: Write the failing tests**

Create `sneaker-scout-backend/tests/test_salomon_pdp_parser.py`:

```python
"""Unit tests for salomon.single_product_page_scraper.extract_detailed_info.

The parser takes a Selenium driver, navigates to product_url, and reads
driver.page_source. We swap in a FakeDriver that returns fixture HTML
on .page_source and monkeypatch WebDriverWait so the wait calls don't
need a real DOM. This is the same trick test_custom_url_cli.py uses."""
import pytest

from salomon import single_product_page_scraper
from tests.fixtures._helpers import load_fixture


class _FakeDriver:
    """Selenium stand-in: get() is a no-op, page_source returns the
    HTML we were initialised with. Anything else the parser touches
    (find_elements, etc.) returns an empty list — salomon's PDP parser
    works through page_source, so the surface area stays small."""

    def __init__(self, html: str):
        self.page_source = html

    def get(self, url):  # noqa: D401 — Selenium contract, not a getter
        pass

    def find_elements(self, *_a, **_kw):
        return []

    def quit(self):
        pass


class _FakeWait:
    def __init__(self, *_a, **_kw):
        pass

    def until(self, *_a, **_kw):
        return True


def _patch_wait(monkeypatch):
    """Swap the WebDriverWait *imported into the scraper module* so
    the parser's wait calls become no-ops."""
    monkeypatch.setattr(single_product_page_scraper, "WebDriverWait", _FakeWait)


def test_pdp_regular_extracts_name_and_description(monkeypatch):
    _patch_wait(monkeypatch)
    driver = _FakeDriver(load_fixture("salomon/pdp_regular.html"))
    info = single_product_page_scraper.extract_detailed_info(
        "https://salomon.com.au/products/xt-6", driver
    )
    assert info.get("name"), "PDP must extract product name from .product-single__title"
    assert info.get("description"), (
        "PDP must extract description from .product__specifications-description"
    )


def test_pdp_regular_extracts_price(monkeypatch):
    _patch_wait(monkeypatch)
    driver = _FakeDriver(load_fixture("salomon/pdp_regular.html"))
    info = single_product_page_scraper.extract_detailed_info(
        "https://salomon.com.au/products/xt-6", driver
    )
    assert info.get("price"), "PDP must extract a current price"


def test_pdp_regular_has_no_original_price(monkeypatch):
    """Regular-priced PDPs should NOT carry a compare-at price."""
    _patch_wait(monkeypatch)
    driver = _FakeDriver(load_fixture("salomon/pdp_regular.html"))
    info = single_product_page_scraper.extract_detailed_info(
        "https://salomon.com.au/products/xt-6", driver
    )
    assert "original_price" not in info, (
        "regular-priced PDP unexpectedly emitted original_price — "
        "either the fixture is on-sale or the parser is over-eager"
    )


def test_pdp_on_sale_extracts_original_price(monkeypatch):
    """PDP-side companion to sneaker_scout-9wg. The PDP parser uses
    [data-compare-price] directly so it never had the listing bug, but
    we lock that contract in so it stays correct."""
    _patch_wait(monkeypatch)
    driver = _FakeDriver(load_fixture("salomon/pdp_on_sale.html"))
    info = single_product_page_scraper.extract_detailed_info(
        "https://salomon.com.au/products/xa-pro-3d-v9-gtx", driver
    )
    assert info.get("price"), "on-sale PDP must extract current price"
    assert info.get("original_price"), (
        "on-sale PDP must extract compare-at price as original_price"
    )
    assert info["original_price"] != info["price"], (
        "PDP original_price equals price — extraction likely fell through"
    )


def test_pdp_extracts_sizes(monkeypatch):
    """Sizes are the highest-churn part of the PDP — colour-coded
    availability classes shift any time salomon redesigns the size
    picker. Asserting a non-empty list keeps us honest."""
    _patch_wait(monkeypatch)
    driver = _FakeDriver(load_fixture("salomon/pdp_regular.html"))
    info = single_product_page_scraper.extract_detailed_info(
        "https://salomon.com.au/products/xt-6", driver
    )
    sizes = info.get("sizes")
    assert isinstance(sizes, list), "sizes must be a list"
    assert len(sizes) > 0, "PDP must extract at least one size entry"
```

- [ ] **Step 2: Run the tests**

```bash
cd sneaker-scout-backend
python -m pytest tests/test_salomon_pdp_parser.py -v
```

Expected: 6 passed. Likely failure modes and fixes:
- `name`/`description` missing → fixture may be a CAPTCHA / error page. Re-capture with a longer warm-up.
- `original_price` missing on the on-sale fixture → `PDP_ON_SALE_URL` in the capture script wasn't on sale at capture time. Update the URL and re-run Task 2 Step 2.
- `sizes` empty → salomon may have JS-hydrated the size picker after our `time.sleep(2)`. Bump the sleep in `capture_salomon_fixtures.py` and re-capture.

- [ ] **Step 3: Commit**

```bash
git -C /workspace/sneaker-scout-backend status -s
git -C /workspace/sneaker-scout-backend add tests/test_salomon_pdp_parser.py
git -C /workspace/sneaker-scout-backend commit -m "test(<bd-id>): salomon PDP-parser tests with FakeDriver + fixture HTML

Six tests against tests/fixtures/salomon/pdp_{regular,on_sale}.html.
Uses a FakeDriver returning fixture page_source and monkeypatches
WebDriverWait so the parser's wait calls no-op (same shape as the
custom-URL CLI tests). Locks in name/description/price/original_price/
sizes contracts so a future selector refactor can't silently drop
fields the uploader depends on."
```

---

## Task 5: Salomon combine_product_info tests

**Files:**
- Create: `sneaker-scout-backend/tests/test_salomon_combine.py`

- [ ] **Step 1: Write the failing tests**

Create `sneaker-scout-backend/tests/test_salomon_combine.py`:

```python
"""Unit tests for salomon.pagination_scraper.combine_product_info.

This is the seam between the scraper's intermediate dicts and the
uploader's expected JSON shape. The singular-vs-plural-key bug noted
in CLAUDE.md ('combine_product_info writes sneakers/brands/retailers
plural while update_supabase_daily reads sneaker/brand/retailer
singular') is the kind of drift these tests prevent."""
from salomon.pagination_scraper import combine_product_info


# A minimal but realistic pair of inputs. Keep these synthetic so the
# tests stay readable — the parser tests already cover real-HTML cases;
# these tests cover the JOIN logic.
_BASIC_REGULAR = {
    "name": "Salomon XT-6",
    "url": "https://salomon.com.au/products/xt-6",
    "image_url": "https://salomon.com.au/cdn/xt6.jpg",
    "image_alt": "Salomon XT-6 in Black",
    "image_title": "Salomon XT-6",
    "price": "$269.99",
    # No original_price / discount_percentage — regular-priced item.
}

_BASIC_ON_SALE = {
    **_BASIC_REGULAR,
    "price": "$188.99",
    "original_price": "$269.99",
    "discount_percentage": "-30",
}

_DETAILED = {
    "description": "Trail-running shoe.",
    "release_date": None,
    "brand": {"name": "Salomon", "logo_url": ""},
    "colorway": {"name": "Black"},
    "is_available": True,
    "retailer": {
        "name": "Salomon Australia",
        "website_url": "https://salomon.com.au",
        "logo_url": "",
    },
    "sizes": [{"uk": "9", "is_available": True}],
}


def test_combine_emits_singular_top_level_keys():
    """REGRESSION GUARD for the singular/plural-key bug in CLAUDE.md.

    The uploader expects 'sneaker', 'brand', 'retailer' (singular).
    If a future refactor ever switches these back to plural, this
    test catches it before the JSON hits Supabase."""
    out = combine_product_info(_BASIC_REGULAR, _DETAILED, gender="mens")
    for key in ("sneaker", "brand", "colorway", "prices", "retailer", "sizes"):
        assert key in out, f"missing top-level key {key!r}"
    for forbidden in ("sneakers", "brands", "retailers"):
        assert forbidden not in out, (
            f"{forbidden!r} appeared in combined output — uploader expects singular"
        )


def test_combine_propagates_gender_into_colorway():
    out = combine_product_info(_BASIC_REGULAR, _DETAILED, gender="womens")
    assert out["colorway"]["gender"] == "womens", (
        "colorway.gender must reflect the caller-supplied gender (sneaker_scout-v7h)"
    )


def test_combine_regular_price_fills_original_price_with_current_price():
    """When the listing parser didn't emit an original_price (regular-
    priced item), combine_product_info falls back to current price. This
    preserves a non-null original_price for downstream consumers."""
    out = combine_product_info(_BASIC_REGULAR, _DETAILED, gender="mens")
    assert out["prices"]["price"] == "$269.99"
    assert out["prices"]["original_price"] == "$269.99"


def test_combine_on_sale_preserves_distinct_original_price():
    """REGRESSION GUARD for sneaker_scout-9wg at the combine layer.

    Even if the listing parser correctly extracted original_price, a
    broken combine could collapse the two. Lock the contract: on-sale
    items end up in the combined dict with prices.price < original_price."""
    out = combine_product_info(_BASIC_ON_SALE, _DETAILED, gender="mens")
    assert out["prices"]["price"] == "$188.99"
    assert out["prices"]["original_price"] == "$269.99"
    assert out["prices"]["price"] != out["prices"]["original_price"]


def test_combine_carries_through_sizes_and_availability():
    out = combine_product_info(_BASIC_REGULAR, _DETAILED, gender="mens")
    assert out["sizes"] == _DETAILED["sizes"]
    assert out["prices"]["is_available"] is True
    assert out["prices"]["currency"] == "AUD"
```

- [ ] **Step 2: Run the tests**

```bash
cd sneaker-scout-backend
python -m pytest tests/test_salomon_combine.py -v
```

Expected: 5 passed.

- [ ] **Step 3: Commit**

```bash
git -C /workspace/sneaker-scout-backend status -s
git -C /workspace/sneaker-scout-backend add tests/test_salomon_combine.py
git -C /workspace/sneaker-scout-backend commit -m "test(<bd-id>): salomon combine_product_info contract tests

Five tests covering the scraper/uploader seam: singular top-level keys
(regression guard for the singular/plural-key bug noted in CLAUDE.md),
gender propagation into colorway (sneaker_scout-v7h contract),
original_price fallback when no sale, and the on-sale case (9wg
regression guard at the combine layer)."
```

---

## Task 6: File follow-up issues for the other four retailers

This task closes the loop — every retailer should get the same coverage shape. We file the issues now (while the salomon template is fresh) but defer the implementation to a future session.

- [ ] **Step 1: File four follow-up beads issues**

Run from `/workspace`, four `bd create` commands (one per retailer). The descriptions are deliberately near-identical — the implementation shape is the same; only the retailer module names change.

```bash
bd create --title="Testing suite: hypedc parser fixtures + tests" --type=task --priority=3 --description="Mirror the salomon template (docs/superpowers/plans/2026-05-21-comprehensive-testing-suite-salomon.md). Capture tests/fixtures/hypedc/{listing_card_regular,listing_card_on_sale,pdp_regular,pdp_on_sale}.html via a scripts/capture_hypedc_fixtures.py, then write tests/test_hypedc_listing_parser.py, tests/test_hypedc_pdp_parser.py, tests/test_hypedc_combine.py. Hypedc-specific note: DataDome bot protection — capture must run in headed mode (HYPEDC_HEADLESS=false), see sneaker-scout-backend/CLAUDE.md."

bd create --title="Testing suite: platypus parser fixtures + tests" --type=task --priority=3 --description="Mirror the salomon template (docs/superpowers/plans/2026-05-21-comprehensive-testing-suite-salomon.md). Capture tests/fixtures/platypus/{listing_card_regular,listing_card_on_sale,pdp_regular,pdp_on_sale}.html via scripts/capture_platypus_fixtures.py, then write tests/test_platypus_listing_parser.py, tests/test_platypus_pdp_parser.py, tests/test_platypus_combine.py. Platypus-specific note: LOAD MORE expansion is irrelevant for fixture capture; capture the first-page render."

bd create --title="Testing suite: footlocker parser fixtures + tests" --type=task --priority=3 --description="Mirror the salomon template (docs/superpowers/plans/2026-05-21-comprehensive-testing-suite-salomon.md). Capture tests/fixtures/footlocker/{listing_card_regular,listing_card_on_sale,pdp_regular,pdp_on_sale}.html via scripts/capture_footlocker_fixtures.py, then write tests/test_footlocker_listing_parser.py, tests/test_footlocker_pdp_parser.py, tests/test_footlocker_combine.py. Footlocker-specific note: Akamai BMP + OneTrust cookie banner — capture path must include warm_up_session() so cookies are set; otherwise the PDP returns an interstitial."

bd create --title="Testing suite: jdsports parser fixtures + tests" --type=task --priority=3 --description="Mirror the salomon template (docs/superpowers/plans/2026-05-21-comprehensive-testing-suite-salomon.md). Capture tests/fixtures/jdsports/{listing_card_regular,listing_card_on_sale,pdp_regular,pdp_on_sale}.html via scripts/capture_jdsports_fixtures.py, then write tests/test_jdsports_listing_parser.py, tests/test_jdsports_pdp_parser.py, tests/test_jdsports_combine.py. JD Sports-specific note: pagination is ?from=N (72/page), but fixture capture only needs the first page."
```

Record the four new IDs. Each will be picked up independently from `bd ready` later.

- [ ] **Step 2: Add a dependency from each new issue back to this slice's umbrella issue (optional, low-effort tracking)**

```bash
bd dep add <hypedc-id> <salomon-slice-id>
bd dep add <platypus-id> <salomon-slice-id>
bd dep add <footlocker-id> <salomon-slice-id>
bd dep add <jdsports-id> <salomon-slice-id>
```

This way `bd show <salomon-slice-id>` lists the follow-ups, and the four follow-ups won't appear in `bd ready` until the salomon slice closes — keeping the queue accurate.

- [ ] **Step 3: No commit** — this task only touches the bd database, not the codebase.

---

## Task 7: Full-suite smoke + bd close + closing commit

- [ ] **Step 1: Run the full backend test suite to confirm no regressions**

```bash
cd sneaker-scout-backend
python -m pytest tests/ --ignore=tests/test_import.py -q
```

Expected: previous baseline (159 passed before this plan) + the new tests from Tasks 1, 3, 4, 5 = 159 + 1 (Task 1 smoke) + 5 (Task 3) + 6 (Task 4) + 5 (Task 5) = **176 passed**, 1 xfailed (pre-existing).

If any pre-existing test broke, that's a regression introduced by the fixture/import setup — investigate before closing.

- [ ] **Step 2: Close the umbrella beads issue**

```bash
cd /workspace
bd close <salomon-slice-id>
```

- [ ] **Step 3: Closing commit**

There may or may not be a docs change required. If `sneaker-scout-backend/CLAUDE.md` should mention the test layout, add a brief section now and include it in this commit; otherwise the closing commit is empty (in which case skip it — the test commits already cover the work, see the per-issue commit protocol's "already shipped" clause).

If adding a docs note, append a section like this to `sneaker-scout-backend/CLAUDE.md` under "Running Scrapers":

```markdown
### Testing the parsers

Each retailer's listing parser, PDP parser, and `combine_product_info`
have unit tests under `tests/test_<retailer>_*.py` driven by committed
HTML fixtures at `tests/fixtures/<retailer>/`. To refresh a retailer's
fixtures after a site redesign:

```bash
python -m scripts.capture_<retailer>_fixtures
python -m pytest tests/test_<retailer>_*.py -v
```

Salomon is currently the only retailer with the full suite — see beads
issues hypedc/platypus/footlocker/jdsports follow-ups for the others.
```

Then commit:

```bash
git -C /workspace/sneaker-scout-backend status -s
git -C /workspace/sneaker-scout-backend add sneaker-scout-backend/CLAUDE.md   # if modified
git -C /workspace/sneaker-scout-backend commit -m "docs(<bd-id>): document the per-retailer parser test layout

Adds a brief 'Testing the parsers' section to the backend CLAUDE.md
covering the tests/fixtures/<retailer>/ pattern and the
scripts/capture_<retailer>_fixtures.py refresh workflow.

Closes: <bd-id>"
```

If no docs change is needed, instead annotate the bd close with `--reason="already covered by commits across this slice"` and skip the closing commit.

---

## Self-Review

**Spec coverage:**
- [x] Listing parser tests — Task 3 (5 tests, including 9wg regression guard).
- [x] PDP parser tests — Task 4 (6 tests, including sizes + on-sale).
- [x] `combine_product_info` tests — Task 5 (5 tests, including the singular/plural-key regression guard + 9wg at combine layer).
- [x] Fixtures captured live + committed — Task 2 (capture script + 4 HTML files).
- [x] Salomon-first, template-rest rollout — Task 6 (four follow-up bd issues filed).
- [x] Uploader gender-PK regression test — DEFERRED to the `sneaker_scout-4kx` fix issue per the plan's Architecture section (correct call: the test needs the fix to know what shape "fixed" looks like).
- [x] End-to-end smoke — DEFERRED per the Architecture note (low value for this slice, expensive to maintain).

**Placeholder scan:** searched for "TBD", "TODO", "implement later", "Add appropriate", "Similar to Task N" — none present.

**Type / name consistency:**
- `load_fixture` used consistently in Tasks 1, 3, 4 (defined in Task 1).
- `_FakeDriver` / `_FakeWait` only used in Task 4 (PDP); Task 3 uses BeautifulSoup directly because the listing parser takes an HTML tag, not a driver.
- Fixture filenames identical everywhere (`listing_card_regular.html`, `listing_card_on_sale.html`, `pdp_regular.html`, `pdp_on_sale.html`).
- BD-issue placeholders (`<bd-id>`, `<salomon-slice-id>`) are intentional — the implementer fills them in after Task 1 Step 1.

No issues found. Plan is ready.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-21-comprehensive-testing-suite-salomon.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
