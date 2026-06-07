# Search-Driven Multi-Retailer Scraper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Bead:** `sneaker_scout-jtv`

**Goal:** Given a sneaker name, drive each retailer's on-page search bar like a human, read the resulting search-results URL, and scrape all results — in bulk, by auto-extracting the names from a Hype DC scrape so the other retailers are covered for every shoe Hype carries, without hand-supplying URLs.

**Architecture:** One **search file per supplier** (`<retailer>/search_scraper.py`) that holds *only* that retailer's search config (the selectors that break) plus a one-line entrypoint. All real logic lives in a shared `utils/search_nav.py`: human-like typing, the search→URL resolver, and the resolve→scrape→merge→save orchestration. Each per-retailer file reuses that retailer's existing `setup_driver` / `warm_up_session` / `scrape_all_pages` / `save_to_json` — no existing scraper internals change. A resolved results page **is** a listing URL, so it flows straight through the existing strict-mode `scrape_all_pages`.

**Tech Stack:** Python 3, Selenium (`undetected-chromedriver` per retailer), pytest, argparse, dataclasses. All work is under `sneaker-scout-backend/`.

---

## Design decisions (from the brainstorm)

- **Per-supplier file, shared logic.** When a scraper breaks it's almost always a changed selector. So each `<retailer>/search_scraper.py` is tiny: a `RetailerSearch` config (home URL, candidate search-box selectors, results-ready selector, pagination param) wired to the retailer's module callables. You fix the broken retailer in one obvious place and smoke-test it with `python -m <retailer>.search_scraper --name "..."`. Everything else is DRY in `utils/search_nav.py`.
- **Human-like navigation, but ~6s/search.** "Human-like" = mechanics, not macro-cadence: type the term character-by-character with randomized inter-key jitter, add randomized think-pauses before/after, and reuse the **persistent search box on the results page** instead of reloading the homepage for every term (faster *and* less robotic). A `Timing` config holds the jitter ranges; defaults average ≈6s/search so 100 searches resolve in ≤10 minutes. The throughput target is encoded as a test (`expected_search_seconds`).
- **Throughput target scope.** The 100-in-10-min budget covers the **URL-resolution phase**. Deep scraping of each result set is bounded by the existing scrapers' per-PDP politeness sleeps and runs as a separate, longer phase.
- **Honest stealth caveat.** Char-jitter + think-pauses + result-box reuse materially lower the bot-detection signal, but 100 searches in one session at high cadence is inherently somewhat detectable. The `Timing` knobs let you trade speed for stealth; HypeDC still needs headed mode + possible CAPTCHA solve.
- **Input/output/filtering (locked earlier):** input via `--names-from` a Hype DC JSON (or single `--name`); one aggregated, de-duped JSON per retailer; scrape all results as-is (no relevance filtering).

## Search-box selectors are best-guess until verified

I cannot inspect the live (bot-protected) sites offline. Each retailer's `SEARCH_CONFIG` ships **candidate** selectors based on its platform (Hype DC & Platypus = Magento 2, Salomon = Shopify, Footlocker & JD Sports AU = custom). `search_to_url` tries each candidate in order, so a wrong guess is a one-line fix in that retailer's file. **Task 8 is the manual headed run that confirms/repairs each retailer's selectors — it cannot be marked done from an assumption.**

## File Structure

**Create (shared):**
- `sneaker-scout-backend/utils/hype_names.py` — extract unique sneaker names from a Hype DC scrape JSON.
- `sneaker-scout-backend/utils/product_merge.py` — merge + de-dupe combined-product dicts by product URL.
- `sneaker-scout-backend/utils/search_nav.py` — `RetailerSearch` + `Timing` dataclasses, human-like typing, `search_to_url`, `resolve_urls`, `run_search`, `run_search_cli`, `expected_search_seconds`.

**Create (per supplier):**
- `sneaker-scout-backend/hypedc/search_scraper.py`
- `sneaker-scout-backend/footlocker/search_scraper.py`
- `sneaker-scout-backend/jdsports/search_scraper.py`
- `sneaker-scout-backend/platypus/search_scraper.py`
- `sneaker-scout-backend/salomon/search_scraper.py`

**Create (tests + fixture):**
- `sneaker-scout-backend/tests/test_hype_names.py`
- `sneaker-scout-backend/tests/test_product_merge.py`
- `sneaker-scout-backend/tests/test_search_nav.py`
- `sneaker-scout-backend/tests/test_search_scraper_cli.py`
- `sneaker-scout-backend/tests/fixtures/search/hype_sample.json`

**Modify:**
- `sneaker-scout-backend/CLAUDE.md` — document the new per-retailer entrypoints (Task 9).
- `spec.yaml` (repo root) — register the new scraper entrypoint (Task 9; mandated by repo CLAUDE.md for any new scraper entrypoint).

All commands below assume the working directory is `sneaker-scout-backend/` unless stated otherwise.

---

### Task 1: Extract sneaker names from a Hype DC scrape JSON

The bulk input is a Hype DC scrape file. Combined-product dicts use **singular** keys (`sneaker`, `brand`) per the uploader contract. We want unique search terms, order-preserving, optionally capped.

**Files:**
- Create: `sneaker-scout-backend/utils/hype_names.py`
- Test: `sneaker-scout-backend/tests/test_hype_names.py`
- Create: `sneaker-scout-backend/tests/fixtures/search/hype_sample.json`

- [ ] **Step 1: Write the fixture**

Create `sneaker-scout-backend/tests/fixtures/search/hype_sample.json`:

```json
[
  {"sneaker": {"name": "Air Max 90"}, "brand": {"name": "Nike"}},
  {"sneaker": {"name": "Air Max 90"}, "brand": {"name": "Nike"}},
  {"sneaker": {"name": "Gel-Kayano 14"}, "brand": {"name": "ASICS"}},
  {"sneaker": {"name": "  "}, "brand": {"name": "Broken"}},
  {"sneaker": {"name": "Samba OG"}, "brand": {"name": "adidas"}}
]
```

- [ ] **Step 2: Write the failing test**

Create `sneaker-scout-backend/tests/test_hype_names.py`:

```python
"""Unit tests for utils.hype_names.extract_names — the seam that turns a
Hype DC scrape JSON into the list of search terms we drive."""
import json
import os

from utils.hype_names import extract_names

FIXTURE = os.path.join(os.path.dirname(__file__), "fixtures", "search", "hype_sample.json")


def test_extracts_unique_names_in_first_seen_order():
    assert extract_names(FIXTURE) == ["Air Max 90", "Gel-Kayano 14", "Samba OG"]


def test_skips_blank_names():
    assert all(n.strip() for n in extract_names(FIXTURE))


def test_limit_caps_result():
    assert extract_names(FIXTURE, limit=2) == ["Air Max 90", "Gel-Kayano 14"]


def test_include_brand_prefixes_brand(tmp_path):
    p = tmp_path / "h.json"
    p.write_text(json.dumps([{"sneaker": {"name": "Air Max 90"}, "brand": {"name": "Nike"}}]))
    assert extract_names(str(p), include_brand=True) == ["Nike Air Max 90"]
```

- [ ] **Step 3: Run test to verify it fails**

Run: `python -m pytest tests/test_hype_names.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'utils.hype_names'`

- [ ] **Step 4: Write the implementation**

Create `sneaker-scout-backend/utils/hype_names.py`:

```python
"""Extract the list of sneaker search terms from a Hype DC scrape JSON.

The per-retailer search scrapers feed these terms into each other
retailer's search bar. Combined-product dicts use the singular
`sneaker`/`brand` keys the uploader expects, so we read those."""
import json


def extract_names(path, limit=None, include_brand=False):
    """Return order-preserving unique sneaker names from a Hype DC scrape
    JSON at `path`. Blank names are skipped; de-dup is case-sensitive on
    the final term. `include_brand` prefixes the brand ("Nike Air Max
    90"); `limit` caps the count after de-dup."""
    with open(path, "r", encoding="utf-8") as f:
        products = json.load(f)

    seen, names = set(), []
    for product in products:
        sneaker = product.get("sneaker") or {}
        name = (sneaker.get("name") or "").strip()
        if not name:
            continue
        if include_brand:
            brand = ((product.get("brand") or {}).get("name") or "").strip()
            if brand:
                name = f"{brand} {name}"
        if name in seen:
            continue
        seen.add(name)
        names.append(name)
        if limit is not None and len(names) >= limit:
            break
    return names
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `python -m pytest tests/test_hype_names.py -v`
Expected: PASS (4 passed)

- [ ] **Step 6: Commit**

```bash
git add utils/hype_names.py tests/test_hype_names.py tests/fixtures/search/hype_sample.json
git commit -m "feat(sneaker_scout-jtv): extract search terms from hypedc scrape JSON"
```

---

### Task 2: Merge + de-dupe products across many searches

Each searched name yields a list of combined-product dicts; the same product reappears across queries. Aggregate into one list, de-duped by product URL, first-seen order.

**Files:**
- Create: `sneaker-scout-backend/utils/product_merge.py`
- Test: `sneaker-scout-backend/tests/test_product_merge.py`

- [ ] **Step 1: Write the failing test**

Create `sneaker-scout-backend/tests/test_product_merge.py`:

```python
"""Unit tests for utils.product_merge.merge_dedupe — aggregates per-search
result lists into one upload-ready list with no duplicate products."""
from utils.product_merge import merge_dedupe


def _p(url, name="x"):
    return {"sneaker": {"name": name, "product_url": url}}


def test_dedupes_by_product_url_first_seen_wins():
    out = merge_dedupe([[_p("https://r/a", "A1"), _p("https://r/b", "B")],
                        [_p("https://r/a", "A2"), _p("https://r/c", "C")]])
    assert [p["sneaker"]["product_url"] for p in out] == ["https://r/a", "https://r/b", "https://r/c"]
    assert out[0]["sneaker"]["name"] == "A1"  # first-seen wins


def test_products_without_url_are_kept_each_time():
    out = merge_dedupe([[{"sneaker": {"name": "no-url"}}], [{"sneaker": {"name": "no-url"}}]])
    assert len(out) == 2


def test_empty_input():
    assert merge_dedupe([]) == []
    assert merge_dedupe([[], []]) == []
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_product_merge.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'utils.product_merge'`

- [ ] **Step 3: Write the implementation**

Create `sneaker-scout-backend/utils/product_merge.py`:

```python
"""Merge per-search product lists into one upload-ready list.

Each retailer search runs many queries; the same physical product
surfaces under several. De-dupe on the combined-product dict's
`sneaker.product_url` so run_update upserts each product once. Products
missing a URL can't be keyed, so they're kept (the uploader's colorway-
key logic dedupes them downstream)."""


def _product_url(product):
    return ((product.get("sneaker") or {}).get("product_url") or "").strip()


def merge_dedupe(result_lists):
    """Flatten `result_lists` into one list, dropping repeats of the same
    `sneaker.product_url`. First occurrence wins; order preserved; URL-less
    products always kept."""
    seen, out = set(), []
    for products in result_lists:
        for product in products:
            url = _product_url(product)
            if url:
                if url in seen:
                    continue
                seen.add(url)
            out.append(product)
    return out
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_product_merge.py -v`
Expected: PASS (3 passed)

- [ ] **Step 5: Commit**

```bash
git add utils/product_merge.py tests/test_product_merge.py
git commit -m "feat(sneaker_scout-jtv): merge+dedupe products across searches by URL"
```

---

### Task 3: Human-like typing + timing primitives

Stealth mechanics, isolated and unit-testable. `time.sleep` and `random.uniform` are injected so tests run instantly and deterministically.

**Files:**
- Create: `sneaker-scout-backend/utils/search_nav.py` (first slice — timing + typing only)
- Test: `sneaker-scout-backend/tests/test_search_nav.py` (first slice)

- [ ] **Step 1: Write the failing test**

Create `sneaker-scout-backend/tests/test_search_nav.py`:

```python
"""Unit tests for utils.search_nav. No live Selenium (matches the house
convention in tests/test_custom_url_cli.py): a FakeDriver/FakeElement
records calls, and sleep/random are injected so tests are instant and
deterministic."""
import pytest

import utils.search_nav as sn


class FakeElement:
    def __init__(self):
        self.cleared = False
        self.typed = []
    def clear(self):
        self.cleared = True
    def send_keys(self, value):
        self.typed.append(value)


def test_human_type_sends_each_char_with_jitter():
    el = FakeElement()
    sleeps = []
    sn.human_type(el, "abc", sn.DEFAULT_TIMING,
                  sleep=sleeps.append, rand=lambda a, b: (a + b) / 2)
    # one send_keys per character (the final ENTER is sent by the caller)
    assert el.typed == ["a", "b", "c"]
    # a jittered pause between keystrokes, each within the configured band
    assert len(sleeps) == 3
    assert all(sn.DEFAULT_TIMING.key_min <= s <= sn.DEFAULT_TIMING.key_max for s in sleeps)


def test_throughput_budget_under_ten_minutes_for_100_searches():
    # ~20-char terms must resolve at <=6s each so 100 fit in 10 minutes.
    per = sn.expected_search_seconds(20, sn.DEFAULT_TIMING)
    assert per <= 6.0
    assert per * 100 <= 600
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_search_nav.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'utils.search_nav'`

- [ ] **Step 3: Write the timing + typing slice**

Create `sneaker-scout-backend/utils/search_nav.py`:

```python
"""Human-like search-bar navigation shared by every retailer's
search_scraper.py.

Two responsibilities:
  1. Make the search interaction look human (char-by-char typing with
     jitter, randomized think-pauses, reusing the results-page search box
     instead of reloading the homepage each term).
  2. Orchestrate resolve(term -> results URL) -> scrape -> merge -> save,
     reusing each retailer's existing scrape_all_pages.

Throughput target: ~6s per search so 100 searches resolve in <=10 min.
The Timing knobs trade speed for stealth; see expected_search_seconds."""
import argparse
import random
import sys
import time
from dataclasses import dataclass, field
from typing import Callable, List, Optional

from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait

from utils.hype_names import extract_names
from utils.product_merge import merge_dedupe
from utils.url_helpers import strip_query_param


@dataclass
class Timing:
    """Delay bands (seconds). Defaults average ~6s/search at ~20 chars."""
    key_min: float = 0.04          # min pause between keystrokes
    key_max: float = 0.16          # max pause between keystrokes
    think_min: float = 0.3         # min think-pause before/after a search
    think_max: float = 1.2         # max think-pause before/after a search
    results_timeout: float = 12.0  # cap waiting for results to render
    typical_results_wait: float = 1.5  # average time results take to render


DEFAULT_TIMING = Timing()


def expected_search_seconds(num_chars, timing=DEFAULT_TIMING):
    """Average-case seconds to resolve one search of `num_chars`: a
    pre-think, char-by-char typing, results render, and a post-think.
    Encodes the throughput requirement so it can be asserted in tests."""
    avg_key = (timing.key_min + timing.key_max) / 2
    avg_think = (timing.think_min + timing.think_max) / 2
    return avg_think + num_chars * avg_key + timing.typical_results_wait + avg_think


def human_type(element, text, timing=DEFAULT_TIMING, sleep=time.sleep, rand=random.uniform):
    """Type `text` into `element` one character at a time with a jittered
    pause between keystrokes. The submitting ENTER is sent by the caller."""
    for ch in text:
        element.send_keys(ch)
        sleep(rand(timing.key_min, timing.key_max))


def human_pause(timing=DEFAULT_TIMING, sleep=time.sleep, rand=random.uniform):
    """A randomized think-pause."""
    sleep(rand(timing.think_min, timing.think_max))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_search_nav.py -v`
Expected: PASS (2 passed)

- [ ] **Step 5: Commit**

```bash
git add utils/search_nav.py tests/test_search_nav.py
git commit -m "feat(sneaker_scout-jtv): human-like typing + throughput-budgeted timing"
```

---

### Task 4: `RetailerSearch` config + `search_to_url`

The config object each per-retailer file fills in, and the resolver that drives the bar. `_find_search_box` / `_wait_for_results` are seams monkeypatched in tests.

**Files:**
- Modify: `sneaker-scout-backend/utils/search_nav.py`
- Test: `sneaker-scout-backend/tests/test_search_nav.py` (add cases)

- [ ] **Step 1: Write the failing test**

Append to `sneaker-scout-backend/tests/test_search_nav.py`:

```python
class FakeDriver:
    def __init__(self, result_url):
        self._result_url = result_url
        self.got = []
        self.element = FakeElement()
    def get(self, url):
        self.got.append(url)
    @property
    def current_url(self):
        return self._result_url


def _cfg():
    return sn.RetailerSearch(
        key="platypus",
        home_url="https://www.platypusshoes.com.au",
        search_box_selectors=["input#search"],
        results_ready_selector="a[href$='.html']",
        page_param="p",
    )


def test_search_to_url_types_term_and_strips_pagination(monkeypatch):
    driver = FakeDriver("https://www.platypusshoes.com.au/catalogsearch/result/?q=samba&p=3")
    monkeypatch.setattr(sn, "_find_search_box", lambda d, sels, t: d.element)
    monkeypatch.setattr(sn, "_wait_for_results", lambda d, sel, t: None)

    url = sn.search_to_url(driver, _cfg(), "Samba OG", navigate_home=True,
                           sleep=lambda s: None)

    assert driver.element.typed == list("Samba OG")  # human_type, char by char
    assert driver.element.cleared is True
    assert driver.got == ["https://www.platypusshoes.com.au"]  # homepage visited
    assert "p=3" not in url and "q=samba" in url


def test_search_to_url_reuses_results_box_when_not_navigating_home(monkeypatch):
    driver = FakeDriver("https://www.platypusshoes.com.au/catalogsearch/result/?q=x")
    monkeypatch.setattr(sn, "_find_search_box", lambda d, sels, t: d.element)
    monkeypatch.setattr(sn, "_wait_for_results", lambda d, sel, t: None)
    sn.search_to_url(driver, _cfg(), "x", navigate_home=False, sleep=lambda s: None)
    assert driver.got == []  # no homepage reload on subsequent searches
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_search_nav.py -v`
Expected: FAIL with `AttributeError: module 'utils.search_nav' has no attribute 'RetailerSearch'`

- [ ] **Step 3: Write `RetailerSearch`, the Selenium seams, and `search_to_url`**

Append to `sneaker-scout-backend/utils/search_nav.py`:

```python
@dataclass
class RetailerSearch:
    """Everything a single retailer's search_scraper.py supplies. The
    selectors are the bits that break on a redesign — keep them in the
    per-retailer file so fixes are one obvious edit."""
    key: str
    home_url: str
    search_box_selectors: List[str]
    results_ready_selector: str
    page_param: str = "page"
    # Module callables (filled in by the per-retailer file). Optional so
    # the pure config can be constructed in tests without importing them.
    setup_driver: Optional[Callable] = None
    warm_up_session: Optional[Callable] = None
    scrape_all_pages: Optional[Callable] = None
    save_to_json: Optional[Callable] = None
    timing: Timing = field(default_factory=Timing)


def _find_search_box(driver, selectors, timeout):
    last_exc = None
    for selector in selectors:
        try:
            return WebDriverWait(driver, timeout).until(
                EC.element_to_be_clickable((By.CSS_SELECTOR, selector))
            )
        except Exception as exc:
            last_exc = exc
    raise RuntimeError(f"No search box for selectors {selectors}: {last_exc}")


def _wait_for_results(driver, selector, timeout):
    WebDriverWait(driver, timeout).until(
        EC.presence_of_element_located((By.CSS_SELECTOR, selector))
    )


def search_to_url(driver, config, term, navigate_home=False,
                  sleep=time.sleep, rand=random.uniform):
    """Drive `config`'s search bar with `term`, human-like, and return the
    results URL (inbound pagination stripped). On the first call pass
    navigate_home=True to load the homepage; later calls reuse the search
    box already on the results page (faster + less robotic)."""
    t = config.timing
    if navigate_home:
        driver.get(config.home_url)
    human_pause(t, sleep=sleep, rand=rand)
    box = _find_search_box(driver, config.search_box_selectors, t.results_timeout)
    box.clear()
    human_type(box, term, t, sleep=sleep, rand=rand)
    box.send_keys(Keys.ENTER)
    _wait_for_results(driver, config.results_ready_selector, t.results_timeout)
    human_pause(t, sleep=sleep, rand=rand)
    return strip_query_param(driver.current_url, config.page_param)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_search_nav.py -v`
Expected: PASS (4 passed)

- [ ] **Step 5: Commit**

```bash
git add utils/search_nav.py tests/test_search_nav.py
git commit -m "feat(sneaker_scout-jtv): RetailerSearch config + human search_to_url"
```

---

### Task 5: `resolve_urls` + `run_search` + `run_search_cli`

The orchestration the per-retailer files call: resolve every term with one reused driver (homepage only on the first), scrape each URL via the retailer's strict-mode `scrape_all_pages`, merge, dedupe, save.

**Files:**
- Modify: `sneaker-scout-backend/utils/search_nav.py`
- Test: `sneaker-scout-backend/tests/test_search_scraper_cli.py`

- [ ] **Step 1: Write the failing tests**

Create `sneaker-scout-backend/tests/test_search_scraper_cli.py`:

```python
"""Wiring tests for utils.search_nav orchestration + per-retailer files.
No live Selenium: resolve/scrape are monkeypatched, mirroring
tests/test_custom_url_cli.py."""
import json
import os

import utils.search_nav as sn


def _cfg(**over):
    base = dict(
        key="platypus",
        home_url="https://p",
        search_box_selectors=["input#search"],
        results_ready_selector="a",
        page_param="p",
    )
    base.update(over)
    return sn.RetailerSearch(**base)


def test_resolve_urls_reuses_one_driver_and_navigates_home_once(monkeypatch):
    events = []

    class FakeDriver:
        def quit(self):
            events.append("quit")

    cfg = _cfg(setup_driver=lambda: FakeDriver(), warm_up_session=None)
    monkeypatch.setattr(
        sn, "search_to_url",
        lambda driver, c, term, navigate_home, **kw: events.append(("home" if navigate_home else "reuse", term)) or f"https://p/{term}",
    )

    urls = sn.resolve_urls(cfg, ["Air Max 90", "Samba OG"])

    assert urls == ["https://p/Air Max 90", "https://p/Samba OG"]
    assert events[0] == ("home", "Air Max 90")   # first navigates home
    assert events[1] == ("reuse", "Samba OG")     # rest reuse the box
    assert events[-1] == "quit"                    # single driver closed


def test_resolve_urls_skips_failing_terms(monkeypatch):
    class FakeDriver:
        def quit(self):
            pass

    cfg = _cfg(setup_driver=lambda: FakeDriver(), warm_up_session=None)

    def flaky(driver, c, term, navigate_home, **kw):
        if term == "boom":
            raise RuntimeError("no search box")
        return f"https://p/{term}"

    monkeypatch.setattr(sn, "search_to_url", flaky)
    assert sn.resolve_urls(cfg, ["ok", "boom", "ok2"]) == ["https://p/ok", "https://p/ok2"]


def test_run_search_aggregates_dedupes_and_writes_one_file(tmp_path, monkeypatch):
    fixture = os.path.join(os.path.dirname(__file__), "fixtures", "search", "hype_sample.json")
    monkeypatch.setattr(sn, "resolve_urls",
                        lambda cfg, terms, **kw: [f"https://r/{i}" for i, _ in enumerate(terms)])

    scrape_calls = []

    def fake_scrape(base_url, gender="mens", max_pages=3, strict_errors=False, **kw):
        scrape_calls.append((base_url, strict_errors))
        shared = "https://r/shared" if base_url in ("https://r/0", "https://r/1") else base_url
        return [{"sneaker": {"name": base_url, "product_url": shared}}]

    written = {}
    cfg = _cfg(scrape_all_pages=fake_scrape,
               save_to_json=lambda data, path: written.update({path: data}))

    out = str(tmp_path / "platypus_search_products.json")
    sn.run_search(cfg, names_from=fixture, name=None, gender="mens", out=out)

    assert all(strict for _, strict in scrape_calls)      # strict mode on
    assert len(scrape_calls) == 3                          # 3 unique names
    urls = sorted(p["sneaker"]["product_url"] for p in written[out])
    assert urls == ["https://r/2", "https://r/shared"]    # 0 & 1 deduped


def test_run_search_single_name(tmp_path, monkeypatch):
    monkeypatch.setattr(sn, "resolve_urls", lambda cfg, terms, **kw: ["https://r/x"])
    written = {}
    cfg = _cfg(scrape_all_pages=lambda base_url, **kw: [{"sneaker": {"name": "S", "product_url": base_url}}],
               save_to_json=lambda data, path: written.update({path: data}))
    out = str(tmp_path / "fl.json")
    sn.run_search(cfg, names_from=None, name="Nike Air Max 90", gender="mens", out=out)
    assert len(written[out]) == 1


def test_run_search_requires_a_name_source():
    import pytest
    cfg = _cfg(scrape_all_pages=lambda **kw: [], save_to_json=lambda *a: None)
    with pytest.raises(SystemExit):
        sn.run_search(cfg, names_from=None, name=None, gender="mens", out="x.json")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/test_search_scraper_cli.py -v`
Expected: FAIL with `AttributeError: module 'utils.search_nav' has no attribute 'resolve_urls'`

- [ ] **Step 3: Write `resolve_urls`, `run_search`, `_default_out`, `run_search_cli`**

Append to `sneaker-scout-backend/utils/search_nav.py`:

```python
def resolve_urls(config, terms, timeout=None):
    """Resolve every term to its results URL using ONE reused driver
    (homepage only on the first term; results-box reuse after). Failed
    terms are skipped with a warning so one bad search can't abort the
    batch."""
    driver = config.setup_driver()
    urls = []
    try:
        if config.warm_up_session is not None:
            config.warm_up_session(driver, None)
        for i, term in enumerate(terms):
            try:
                url = search_to_url(driver, config, term, navigate_home=(i == 0))
                print(f"  search '{term}' -> {url}")
                urls.append(url)
            except Exception as exc:
                print(f"  search '{term}' FAILED ({exc.__class__.__name__}: {exc}) — skipping")
    finally:
        try:
            driver.quit()
        except Exception:
            pass
    return urls


def _default_out(retailer_key):
    import os
    return os.path.join("jsons", f"{retailer_key}_search_products.json")


def run_search(config, names_from=None, name=None, gender="mens", out=None,
               limit=None, max_pages=3):
    """End-to-end for one retailer: gather terms -> resolve URLs -> scrape
    each (strict) -> merge+dedupe -> write one aggregated JSON."""
    if name:
        terms = [name]
    elif names_from:
        terms = extract_names(names_from, limit=limit)
    else:
        sys.exit("Provide --name or --names-from")
    if not terms:
        sys.exit("No search terms to run")
    print(f"[{config.key}] {len(terms)} search term(s)")

    urls = resolve_urls(config, terms)
    if not urls:
        sys.exit(f"[{config.key}] no search URLs resolved — check selectors in {config.key}/search_scraper.py")

    result_lists = []
    for url in urls:
        print(f"[{config.key}] scraping {url}")
        result_lists.append(
            config.scrape_all_pages(base_url=url, gender=gender,
                                    max_pages=max_pages, strict_errors=True)
        )

    products = merge_dedupe(result_lists)
    out = out or _default_out(config.key)
    config.save_to_json(products, out)
    print(f"[{config.key}] wrote {len(products)} unique products -> {out}")
    return products


def run_search_cli(config, argv=None):
    """argparse entrypoint each <retailer>/search_scraper.py calls."""
    parser = argparse.ArgumentParser(description=f"Search-driven scraper for {config.key}")
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument("--name", default=None, help="Single sneaker name to search")
    src.add_argument("--names-from", default=None,
                     help="Hype DC scrape JSON to pull sneaker names from")
    parser.add_argument("--gender", choices=("mens", "womens"), default="mens")
    parser.add_argument("--out", default=None, help="Output JSON path")
    parser.add_argument("--limit", type=int, default=None, help="Cap number of names")
    parser.add_argument("--max-pages", type=int, default=3)
    args = parser.parse_args(argv)
    run_search(config, names_from=args.names_from, name=args.name,
               gender=args.gender, out=args.out, limit=args.limit,
               max_pages=args.max_pages)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m pytest tests/test_search_scraper_cli.py -v`
Expected: PASS (5 passed)

- [ ] **Step 5: Commit**

```bash
git add utils/search_nav.py tests/test_search_scraper_cli.py
git commit -m "feat(sneaker_scout-jtv): resolve_urls + run_search orchestration + CLI"
```

---

### Task 6: Per-supplier search files

One tiny file per retailer: its `RetailerSearch` config (the selectors that break) wired to its module callables, plus the CLI guard. Selectors are best-guess per platform; Task 8 finalises them live.

**Files:**
- Create: `sneaker-scout-backend/hypedc/search_scraper.py`
- Create: `sneaker-scout-backend/footlocker/search_scraper.py`
- Create: `sneaker-scout-backend/jdsports/search_scraper.py`
- Create: `sneaker-scout-backend/platypus/search_scraper.py`
- Create: `sneaker-scout-backend/salomon/search_scraper.py`
- Test: `sneaker-scout-backend/tests/test_search_scraper_cli.py` (add a parametrized config-presence test)

- [ ] **Step 1: Create `hypedc/search_scraper.py`**

```python
"""HypeDC search-driven scraper.
Run:  python -m hypedc.search_scraper --name "Nike Air Max 90"
      python -m hypedc.search_scraper --names-from=jsons/hypedc_mens_products.json
If search breaks, fix SEARCH_CONFIG.search_box_selectors / results_ready_selector
below. HypeDC needs headed mode (HYPEDC_HEADLESS=false) + possible CAPTCHA."""
from . import pagination_scraper as scraper
from utils.search_nav import RetailerSearch, run_search_cli

SEARCH_CONFIG = RetailerSearch(
    key="hypedc",
    home_url="https://www.hypedc.com/au",
    search_box_selectors=["input#search", "input[name='q']", "input[type='search']"],
    results_ready_selector="li[data-plp-product]",
    page_param="page",
    setup_driver=scraper.setup_driver,
    warm_up_session=scraper.warm_up_session,
    scrape_all_pages=scraper.scrape_all_pages,
    save_to_json=scraper.save_to_json,
)

if __name__ == "__main__":
    run_search_cli(SEARCH_CONFIG)
```

- [ ] **Step 2: Create `footlocker/search_scraper.py`**

```python
"""Footlocker search-driven scraper.
Run:  python -m footlocker.search_scraper --name "Nike Air Max 90"
Fix selectors in SEARCH_CONFIG below if search breaks."""
from . import pagination_scraper as scraper
from utils.search_nav import RetailerSearch, run_search_cli

SEARCH_CONFIG = RetailerSearch(
    key="footlocker",
    home_url="https://www.footlocker.com.au/en",
    search_box_selectors=["input[name='query']", "input[type='search']", "input#search"],
    results_ready_selector="a[href*='/product/']",
    page_param="currentPage",
    setup_driver=scraper.setup_driver,
    warm_up_session=scraper.warm_up_session,
    scrape_all_pages=scraper.scrape_all_pages,
    save_to_json=scraper.save_to_json,
)

if __name__ == "__main__":
    run_search_cli(SEARCH_CONFIG)
```

- [ ] **Step 3: Create `jdsports/search_scraper.py`**

```python
"""JD Sports search-driven scraper.
Run:  python -m jdsports.search_scraper --name "Nike Air Max 90"
Fix selectors in SEARCH_CONFIG below if search breaks."""
from . import pagination_scraper as scraper
from utils.search_nav import RetailerSearch, run_search_cli

SEARCH_CONFIG = RetailerSearch(
    key="jdsports",
    home_url="https://www.jd-sports.com.au",
    search_box_selectors=["input#searchTerm", "input[name='search']", "input[type='search']"],
    results_ready_selector="a[href*='/product/']",
    page_param="from",
    setup_driver=scraper.setup_driver,
    warm_up_session=scraper.warm_up_session,
    scrape_all_pages=scraper.scrape_all_pages,
    save_to_json=scraper.save_to_json,
)

if __name__ == "__main__":
    run_search_cli(SEARCH_CONFIG)
```

- [ ] **Step 4: Create `platypus/search_scraper.py`**

```python
"""Platypus search-driven scraper.
Run:  python -m platypus.search_scraper --name "adidas Samba OG"
Fix selectors in SEARCH_CONFIG below if search breaks."""
from . import pagination_scraper as scraper
from utils.search_nav import RetailerSearch, run_search_cli

SEARCH_CONFIG = RetailerSearch(
    key="platypus",
    home_url="https://www.platypusshoes.com.au",
    search_box_selectors=["input#search", "input[name='q']", "input[type='search']"],
    results_ready_selector="a[href$='.html']",
    page_param="p",
    setup_driver=scraper.setup_driver,
    warm_up_session=scraper.warm_up_session,
    scrape_all_pages=scraper.scrape_all_pages,
    save_to_json=scraper.save_to_json,
)

if __name__ == "__main__":
    run_search_cli(SEARCH_CONFIG)
```

- [ ] **Step 5: Create `salomon/search_scraper.py`**

Salomon's module has no `warm_up_session` — leave it unset (defaults to None).

```python
"""Salomon search-driven scraper.
Run:  python -m salomon.search_scraper --name "XT-6"
Fix selectors in SEARCH_CONFIG below if search breaks."""
from . import pagination_scraper as scraper
from utils.search_nav import RetailerSearch, run_search_cli

SEARCH_CONFIG = RetailerSearch(
    key="salomon",
    home_url="https://salomon.com.au",
    search_box_selectors=["input[name='q']", "input[type='search']", "input#Search"],
    results_ready_selector="a[href*='/products/']",
    page_param="page",
    setup_driver=scraper.setup_driver,
    scrape_all_pages=scraper.scrape_all_pages,
    save_to_json=scraper.save_to_json,
)

if __name__ == "__main__":
    run_search_cli(SEARCH_CONFIG)
```

- [ ] **Step 6: Write the config-presence test**

Append to `sneaker-scout-backend/tests/test_search_scraper_cli.py`:

```python
import importlib
import pytest


@pytest.mark.parametrize("retailer", ["hypedc", "footlocker", "jdsports", "platypus", "salomon"])
def test_each_retailer_search_file_is_wired(retailer):
    mod = importlib.import_module(f"{retailer}.search_scraper")
    cfg = mod.SEARCH_CONFIG
    assert cfg.key == retailer
    assert cfg.home_url.startswith("https://")
    assert cfg.search_box_selectors and cfg.results_ready_selector
    # module callables wired (warm_up optional for salomon)
    assert callable(cfg.setup_driver)
    assert callable(cfg.scrape_all_pages)
    assert callable(cfg.save_to_json)
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `python -m pytest tests/test_search_scraper_cli.py -v`
Expected: PASS (config-presence parametrized cases + earlier cases).

- [ ] **Step 8: Commit**

```bash
git add hypedc/search_scraper.py footlocker/search_scraper.py jdsports/search_scraper.py platypus/search_scraper.py salomon/search_scraper.py tests/test_search_scraper_cli.py
git commit -m "feat(sneaker_scout-jtv): per-supplier search_scraper files"
```

---

### Task 7: Sanity-run each CLI (no Selenium)

Confirm every entrypoint imports and parses before any live run.

**Files:** none (verification only)

- [ ] **Step 1: Help for each retailer**

Run:
```bash
for r in hypedc footlocker jdsports platypus salomon; do \
  echo "== $r =="; python -m $r.search_scraper --help; done
```
Expected: each prints usage with `--name`, `--names-from`, `--gender`, `--out`, `--limit`, `--max-pages`. No traceback.

- [ ] **Step 2: Mutually-exclusive guard**

Run: `python -m platypus.search_scraper`
Expected: argparse error "one of the arguments --name --names-from is required", exit code 2.

- [ ] **Step 3: Full suite green**

Run: `python -m pytest -q`
Expected: PASS — no existing tests broken (only new files added).

---

### Task 8: Live headed verification + selector finalisation (MANUAL — per retailer)

`SEARCH_CONFIG` selectors are best-guess. Confirm each retailer against the live site and fix wrong selectors **in that retailer's `search_scraper.py`**. Do footlocker, jdsports, platypus, salomon (the search targets). Verify hypedc too only if you intend to self-search it. **Cannot be completed from assumption — requires a real headed run with Chrome installed.**

For EACH target retailer:

- [ ] **Step 1: Single live search (headed)**

```bash
cd sneaker-scout-backend
source .venv/bin/activate
HYPEDC_HEADLESS=false python -m <retailer>.search_scraper --name "Nike Air Max 90" --max-pages=1
```
Expected: console shows `search 'Nike Air Max 90' -> <results URL>`, then scrapes, then `wrote N unique products -> jsons/<retailer>_search_products.json` with N > 0.

- [ ] **Step 2: If it fails at "No search box"** — inspect the live home page's search input in a browser, put the correct CSS selector at the front of `search_box_selectors` in `<retailer>/search_scraper.py`, re-run Step 1.

- [ ] **Step 3: If it resolves a URL but scrapes 0 products** — the results-page DOM differs from the category DOM the parser expects. Set `results_ready_selector` to a stable per-product anchor on the results page and re-run. If the results page is fundamentally different from the category page, note it in the bead — that retailer needs a results-page parser variant (out of scope for the happy path).

- [ ] **Step 4: Throughput check (one batch)**

```bash
time HYPEDC_HEADLESS=false python -m <retailer>.search_scraper \
    --names-from=jsons/hypedc_mens_products.json --limit=100 --max-pages=1
```
Expected: the resolve phase (the `search '...' -> ...` lines) completes for ~100 names within ~10 minutes. If slower, lower the `Timing` think bands; if it trips bot detection, raise them (trade-off documented in `utils/search_nav.py`).

- [ ] **Step 5: Confirm upload-shaped output**

```bash
python -c "import json; d=json.load(open('jsons/<retailer>_search_products.json')); print(len(d), sorted(d[0].keys()))"
```
Expected: count > 0 and top-level keys include `sneaker`, `brand`, `retailer` (singular — run_update contract).

- [ ] **Step 6: Commit selector fixes (once, after all retailers verified)**

```bash
git add */search_scraper.py
git commit -m "fix(sneaker_scout-jtv): finalise live search selectors per retailer"
```

---

### Task 9: Docs — backend CLAUDE.md + spec.yaml

Repo CLAUDE.md mandates updating `spec.yaml` for a new scraper entrypoint; backend CLAUDE.md is where scraper usage lives.

**Files:**
- Modify: `sneaker-scout-backend/CLAUDE.md`
- Modify: `spec.yaml`

- [ ] **Step 1: Add a "Search-driven scraping" section to backend CLAUDE.md**

Under "Running Scrapers", add:

```markdown
### Search-driven scraping (cover Hype's catalogue on other retailers)

Each retailer has a `search_scraper.py` that drives its on-page search bar
(human-like typing, ~6s/search so ~100 names resolve in ~10 min) for one
or many sneaker names and scrapes every result, aggregating + de-duping
into one JSON ready for run_update.

```bash
cd sneaker-scout-backend
# one name (smoke test a retailer)
python -m platypus.search_scraper --name "adidas Samba OG"
# many names auto-extracted from a Hype DC scrape (the intended bulk use)
python -m platypus.search_scraper --names-from=jsons/hypedc_mens_products.json --gender=mens
# then upload the aggregated file
python -m data_upload.run_update --file=jsons/platypus_search_products.json
```

Output: `jsons/<retailer>_search_products.json` (override with `--out`).
**When a search scraper breaks, edit that retailer's `search_scraper.py`** —
the `SEARCH_CONFIG.search_box_selectors` / `results_ready_selector` are the
usual culprits. Shared logic (typing, throughput, orchestration) lives in
`utils/search_nav.py`. HypeDC search needs headed mode + possible CAPTCHA.
```

- [ ] **Step 2: Register the entrypoint in spec.yaml**

Add an entry describing `python -m <retailer>.search_scraper` alongside the other scraper CLI entries (match that file's existing style: params `--name`/`--names-from`, `--gender`, `--out`, `--limit`, `--max-pages`; output `jsons/<retailer>_search_products.json`). Keep examples round-trippable.

- [ ] **Step 3: Verify docs match reality**

Run: `python -m platypus.search_scraper --help`
Confirm documented flags match `--help`. Fix drift.

- [ ] **Step 4: Commit**

```bash
git add sneaker-scout-backend/CLAUDE.md spec.yaml
git commit -m "docs(sneaker_scout-jtv): document per-retailer search scraper entrypoints"
```

---

### Task 10: Close out

- [ ] **Step 1: Full suite green**

Run: `cd sneaker-scout-backend && python -m pytest -q`
Expected: PASS.

- [ ] **Step 2: Close the bead**

```bash
bd close sneaker_scout-jtv --reason="per-supplier search scrapers shipped: human-like search_to_url (~6s/search, 100 in <=10min), shared utils/search_nav.py orchestration, per-retailer search_scraper.py files, selectors verified live"
```

- [ ] **Step 3: Session-completion push** (per repo CLAUDE.md)

```bash
git pull --rebase
bd dolt push
git push
git status   # MUST show up to date with origin
```

---

## Self-Review

**Spec coverage:**
- "file per supplier so I can test/validate and fix when it breaks" → `<retailer>/search_scraper.py` each holds only its selectors + CLI; smoke-test via `python -m <retailer>.search_scraper --name ...` — Task 6.
- "shared util for this task" → all logic in `utils/search_nav.py` (+ `utils/hype_names.py`, `utils/product_merge.py`) — Tasks 1–5.
- "as human-like as possible to avoid bot detection" → char-by-char typing with jitter, randomized think-pauses, results-box reuse instead of homepage reloads — Tasks 3, 4.
- "at least 100 searches in ~10 minutes" → `Timing` defaults average ≈6s/search, encoded + asserted via `expected_search_seconds` (Task 3) and live-checked (Task 8 Step 4).
- "scrape all results / use existing custom-url infra" → resolved URL → existing `scrape_all_pages(strict_errors=True)`, no internals changed — Tasks 5, 6.
- "input list of names from hypedc outputs" → `extract_names` + `--names-from` — Tasks 1, 5.
- Aggregated, de-duped, one file per retailer → `merge_dedupe` + `_default_out` — Tasks 2, 5.

**Placeholder scan:** No TBD/"handle errors"/"similar to" — every code step has full code. The only non-code tasks (7 sanity, 8 live) are inherently runtime verification and are marked so with concrete fix instructions.

**Type consistency:** `extract_names(path, limit, include_brand)`, `merge_dedupe(result_lists)`, `Timing(...)`, `expected_search_seconds(num_chars, timing)`, `human_type(element, text, timing, sleep, rand)`, `human_pause(timing, sleep, rand)`, `RetailerSearch(key, home_url, search_box_selectors, results_ready_selector, page_param, setup_driver, warm_up_session, scrape_all_pages, save_to_json, timing)`, `search_to_url(driver, config, term, navigate_home, sleep, rand)`, `resolve_urls(config, terms, timeout)`, `run_search(config, names_from, name, gender, out, limit, max_pages)`, `run_search_cli(config, argv)` are used identically across tasks. `scrape_all_pages(base_url, gender, max_pages, strict_errors)` and `save_to_json(data, path)` match the real signatures verified in all five modules.

## Risks / open items
- **Selectors unverified offline** — Task 8 is the gate; the registries are provisional until then.
- **Search-results DOM may differ from category DOM** for some retailers; if so the parser yields 0 products and that retailer needs a small results-page parser variant (flagged Task 8 Step 3).
- **Stealth vs throughput** is a genuine trade-off; the `Timing` knobs expose it. 100 searches/session at ~6s cadence lowers but does not eliminate detection risk.
