# Custom URL Scrape Starting Point — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **Project rule:** the project CLAUDE.md mandates subagent-driven-development; pick that.

**Beads issue:** `sneaker_scout-1el`

**Goal:** Add a `--url` CLI flag to every retailer's `pagination_scraper.py` (salomon, hypedc, platypus, footlocker, jdsports) so users can scrape from an arbitrary starting URL (filtered listings, brand pages, deep pagination links). When `--url` is supplied, the scraper runs in *strict mode*: no static-fixture fallback, no swallowing of per-product or driver errors — failures are surfaced as exceptions so the operator can diagnose.

**Architecture:** Each `scrape_all_pages(...)` already accepts a `base_url` parameter today, so the change is two-fold per file: (1) plumb a new `strict_errors: bool = False` kwarg through that function and replace each "log-and-continue" or "fall-back-to-static-fixtures" branch with `if strict_errors: raise ...`, and (2) add `--url` and `--out` arguments to each `__main__` block. The CLI sets `strict_errors=True` and a `_custom_products.json` default output filename when `--url` is given. For hypedc and jdsports the custom URL has any inbound pagination param (`?page=N` / `?from=N`) stripped before the existing `_build_page_url` constructs subsequent pages — without this, the user's filter URL would emit `?page=3&page=1` on the first iteration. A small shared helper `utils/url_helpers.strip_query_param()` is added and TDD-covered first.

**Tech Stack:** Python 3.11+, argparse, urllib.parse, pytest, BeautifulSoup, Selenium / undetected-chromedriver (existing).

---

## File Structure

### Create
- `sneaker-scout-backend/utils/url_helpers.py` — `strip_query_param(url, name)` pure function.
- `sneaker-scout-backend/tests/test_url_helpers.py` — unit tests for the helper.
- `sneaker-scout-backend/tests/test_custom_url_cli.py` — argparse + strict_errors behaviour for each retailer.

### Modify
- `sneaker-scout-backend/salomon/pagination_scraper.py` — add `strict_errors`, `--url`, `--out`.
- `sneaker-scout-backend/hypedc/pagination_scraper.py` — same + strip `?page=` from custom URL.
- `sneaker-scout-backend/platypus/pagination_scraper.py` — same (LOAD MORE flow).
- `sneaker-scout-backend/footlocker/pagination_scraper.py` — same + skip mega-menu when strict.
- `sneaker-scout-backend/jdsports/pagination_scraper.py` — same + strip `?from=` from custom URL.
- `sneaker-scout-backend/CLAUDE.md` — document the new `--url` flag and strict-mode semantics.

### Why this structure
- `strip_query_param` is a pure URL-manipulation function used by two retailers; it goes in `utils/` so both can import it without duplicating the urlsplit/parse_qsl/urlencode dance. One module, one test file, ~15 lines of code.
- One test file per concern: `test_url_helpers.py` for the pure helper, `test_custom_url_cli.py` for the CLI/argparse/strict-mode plumbing across retailers. The latter mocks `scrape_all_pages` (no Selenium) and asserts the wiring is correct.
- Each retailer's `pagination_scraper.py` keeps its own pagination semantics; the change is a small set of localised edits inside the existing functions, not a cross-cutting refactor.

---

## Strict mode contract

When `strict_errors=True`, the following branches in `scrape_all_pages` change behaviour:

| Today (`strict_errors=False`)                                                  | When `strict_errors=True`                                              |
| ------------------------------------------------------------------------------ | ---------------------------------------------------------------------- |
| `setup_driver()` raises → `print` warning + `_scrape_via_static_fallback(...)` | Let the exception propagate.                                           |
| Listing-page load fails (after retry) → fall back to static fixtures           | `raise RuntimeError(f"...")` with the URL and underlying class.        |
| Listing parses to zero cards on page 1 → fall back to static fixtures          | `raise RuntimeError(f"...")` (dump diag file first, then raise).       |
| Per-product `extract_detailed_info(...)` raises → log + `continue`             | Let the exception propagate (do not call `log_detail_error`).          |
| `_click_load_more` / `click_next_page` returns False mid-loop (platypus/fl)    | `raise RuntimeError(...)` instead of silently breaking the loop.       |
| (footlocker only) mega-menu nav fails → fall back to `_ensure_listing`         | Skip the mega-menu entirely; go direct to `driver.get(base_url)`.      |

Strict mode is purely additive — existing callers (cron, `entrypoint.sh`, the periodic Docker loop) pass `strict_errors=False` implicitly via the default, so their behaviour is unchanged.

---

## Task 1: `utils/url_helpers.py` + tests

**Files:**
- Create: `sneaker-scout-backend/utils/url_helpers.py`
- Create: `sneaker-scout-backend/tests/test_url_helpers.py`

- [ ] **Step 1: Write the failing test**

Create `sneaker-scout-backend/tests/test_url_helpers.py`:

```python
"""Tests for utils.url_helpers.strip_query_param.

Targeted at the hypedc / jdsports pagination wiring: when a user passes
a custom listing URL that already encodes a page (`?page=3`, `?from=144`),
we need to drop that param before constructing subsequent page URLs.
Other query params (filters, sorts) must survive."""

from utils.url_helpers import strip_query_param


def test_strip_named_param_removes_it():
    url = "https://example.com/path?page=3&brand=nike"
    assert strip_query_param(url, "page") == "https://example.com/path?brand=nike"


def test_strip_named_param_when_absent_returns_unchanged():
    url = "https://example.com/path?brand=nike"
    assert strip_query_param(url, "page") == url


def test_strip_named_param_when_only_param_drops_query():
    url = "https://example.com/path?page=3"
    assert strip_query_param(url, "page") == "https://example.com/path"


def test_strip_named_param_preserves_fragment():
    url = "https://example.com/path?page=3#anchor"
    assert strip_query_param(url, "page") == "https://example.com/path#anchor"


def test_strip_named_param_handles_repeated_param():
    url = "https://example.com/path?page=3&page=4&brand=nike"
    assert strip_query_param(url, "page") == "https://example.com/path?brand=nike"


def test_strip_named_param_handles_url_without_query():
    url = "https://example.com/path"
    assert strip_query_param(url, "page") == url


def test_strip_named_param_is_case_sensitive_by_default():
    # `currentPage` is the footlocker pagination key; mixed-case must be
    # treated literally (no accidental match on `currentpage`).
    url = "https://example.com/path?currentPage=2"
    assert strip_query_param(url, "currentpage") == url
    assert strip_query_param(url, "currentPage") == "https://example.com/path"
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```
cd sneaker-scout-backend && python -m pytest tests/test_url_helpers.py -v
```

Expected: ImportError / ModuleNotFoundError — `utils.url_helpers` does not exist.

- [ ] **Step 3: Implement `strip_query_param`**

Create `sneaker-scout-backend/utils/url_helpers.py`:

```python
"""URL-manipulation helpers shared by retailer scrapers.

Kept deliberately small — anything more interesting than param stripping
belongs inside a retailer module, not here."""
from urllib.parse import urlencode, urlsplit, urlunsplit, parse_qsl


def strip_query_param(url: str, name: str) -> str:
    """Return ``url`` with every occurrence of the query parameter
    ``name`` removed. Fragment, path, scheme, and other params are
    preserved. Match is case-sensitive.

    Used by hypedc and jdsports so that a user-supplied custom URL that
    already encodes pagination (`?page=3`, `?from=144`) doesn't end up
    duplicated when the retailer's own `_build_page_url` re-appends the
    same param.
    """
    parts = urlsplit(url)
    qs = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True) if k != name]
    return urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(qs), parts.fragment))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```
cd sneaker-scout-backend && python -m pytest tests/test_url_helpers.py -v
```

Expected: 7 passed.

- [ ] **Step 5: Commit**

```
git -C /workspace/sneaker-scout-backend add utils/url_helpers.py tests/test_url_helpers.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-1el): add utils.url_helpers.strip_query_param

Pure helper used by hypedc and jdsports pagination scrapers in the
next tasks: when the user supplies a custom starting URL that already
encodes a page (?page=3 / ?from=144), strip_query_param drops it so the
retailer's _build_page_url logic doesn't double-encode pagination state
on subsequent pages. Filter / sort params are preserved.

Closes: nothing yet (1el remains open until all retailers are wired up)."
```

---

## Task 2: Salomon — `--url` + `strict_errors`

**Files:**
- Modify: `sneaker-scout-backend/salomon/pagination_scraper.py:144-262` (function body) and the `__main__` block at lines 264-302.
- Modify: `sneaker-scout-backend/tests/test_custom_url_cli.py` (create on first task).

- [ ] **Step 1: Write the failing test**

Create `sneaker-scout-backend/tests/test_custom_url_cli.py`:

```python
"""CLI / strict-mode wiring tests for every retailer's pagination_scraper.

We deliberately do NOT exercise Selenium here. Each retailer's
`scrape_all_pages` is monkey-patched to record the kwargs it was called
with, so we can assert that the `__main__` block hands the right values
through. Strict-mode behaviour inside scrape_all_pages is exercised
separately by patching setup_driver to raise.
"""
import importlib
import subprocess
import sys

import pytest


# ---------------------------------------------------------------------------
# Salomon
# ---------------------------------------------------------------------------

def test_salomon_url_flag_sets_strict_and_custom_output(tmp_path, monkeypatch):
    """`python -m salomon.pagination_scraper --gender=mens --url=...` must
    invoke scrape_all_pages with the custom base_url, strict_errors=True,
    and write the result to a *_custom_products.json file."""
    captured = {}

    def fake_scrape(base_url, retailer=None, gender="mens",
                    max_pages=None, max_products_per_page=5,
                    page_timeout=30, strict_errors=False):
        captured["base_url"] = base_url
        captured["gender"] = gender
        captured["strict_errors"] = strict_errors
        return [{"sneaker": {"name": "stub"}}]

    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, "argv", [
        "salomon.pagination_scraper",
        "--gender=mens",
        "--url=https://salomon.com.au/collections/mens?filter=trail",
    ])

    mod = importlib.import_module("salomon.pagination_scraper")
    monkeypatch.setattr(mod, "scrape_all_pages", fake_scrape)

    # Re-execute the __main__ block by calling its body.
    mod._run_cli()

    assert captured["base_url"] == "https://salomon.com.au/collections/mens?filter=trail"
    assert captured["strict_errors"] is True
    assert (tmp_path / "jsons" / "salomon_mens_custom_products.json").exists()


def test_salomon_no_url_flag_preserves_canonical_output(tmp_path, monkeypatch):
    """Without --url: canonical LISTING_URLS[gender] is used, strict=False,
    output filename is unchanged from before (`salomon_<gender>_products.json`)."""
    captured = {}

    def fake_scrape(base_url, retailer=None, gender="mens",
                    max_pages=None, max_products_per_page=5,
                    page_timeout=30, strict_errors=False):
        captured["base_url"] = base_url
        captured["strict_errors"] = strict_errors
        return [{"sneaker": {"name": "stub"}}]

    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, "argv", ["salomon.pagination_scraper", "--gender=mens"])

    mod = importlib.import_module("salomon.pagination_scraper")
    monkeypatch.setattr(mod, "scrape_all_pages", fake_scrape)
    mod._run_cli()

    assert captured["base_url"] == mod.LISTING_URLS["mens"]
    assert captured["strict_errors"] is False
    assert (tmp_path / "jsons" / "salomon_mens_products.json").exists()


def test_salomon_strict_setup_driver_failure_raises(monkeypatch):
    """In strict mode, setup_driver() failure must propagate — NOT silently
    fall back to static fixtures (which salomon doesn't even have)."""
    mod = importlib.import_module("salomon.pagination_scraper")

    def boom():
        raise RuntimeError("chrome not installed")

    monkeypatch.setattr(mod, "setup_driver", boom)
    with pytest.raises(RuntimeError, match="chrome not installed"):
        mod.scrape_all_pages(
            "https://salomon.com.au/collections/mens",
            gender="mens", max_pages=1, max_products_per_page=1,
            strict_errors=True,
        )


def test_salomon_strict_detail_error_raises(monkeypatch):
    """In strict mode, a per-product extract_detailed_info exception must
    propagate instead of being swallowed via log_detail_error + continue."""
    mod = importlib.import_module("salomon.pagination_scraper")

    class FakeDriver:
        page_source = """
        <html><body>
          <div id='searchspring-content'>
            <div class='ss__result product-grid-element-container'>
              <a class='ss__image__link' href='/products/p1'><img src='x'/></a>
              <div class='product-grid-item__title'>P1</div>
            </div>
          </div>
        </body></html>
        """
        def get(self, url): pass
        def quit(self): pass

    monkeypatch.setattr(mod, "setup_driver", lambda: FakeDriver())
    # Patch the WebDriverWait to a no-op so the listing "loads" instantly.
    monkeypatch.setattr(mod, "WebDriverWait", lambda *a, **kw: type("W", (), {"until": lambda self, f: True})())

    def boom_detail(*args, **kwargs):
        raise ValueError("PDP parse exploded")

    monkeypatch.setattr(mod, "extract_detailed_info", boom_detail)

    with pytest.raises(ValueError, match="PDP parse exploded"):
        mod.scrape_all_pages(
            "https://salomon.com.au/collections/mens",
            gender="mens", max_pages=1, max_products_per_page=1,
            strict_errors=True,
        )
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```
cd sneaker-scout-backend && python -m pytest tests/test_custom_url_cli.py::test_salomon_url_flag_sets_strict_and_custom_output tests/test_custom_url_cli.py::test_salomon_no_url_flag_preserves_canonical_output tests/test_custom_url_cli.py::test_salomon_strict_setup_driver_failure_raises tests/test_custom_url_cli.py::test_salomon_strict_detail_error_raises -v
```

Expected: AttributeError / signature mismatch — `_run_cli` doesn't exist, `strict_errors` isn't a parameter.

- [ ] **Step 3: Add `strict_errors` to `scrape_all_pages`**

Edit `sneaker-scout-backend/salomon/pagination_scraper.py`. Change the signature at line 144:

```python
def scrape_all_pages(base_url, retailer=None, gender="mens", max_pages=None,
                    max_products_per_page=5, page_timeout=30,
                    strict_errors=False):
```

In the function body, replace the per-product `except Exception` block (lines 222-233) with:

```python
                except Exception as e:
                    if strict_errors:
                        raise
                    summary = log_detail_error(
                        _err_logger,
                        e,
                        url=product_url,
                        retailer="salomon",
                        product_name=basic_info.get("name"),
                        brand=basic_info.get("brand"),
                    )
                    print(f"  Error processing product: {summary} — skipping (see logs/salomon_scrape_errors.log)")
                    continue
```

Replace the listing-load `except` block (lines 176-178) with:

```python
            except Exception as e:
                if strict_errors:
                    raise RuntimeError(
                        f"Listing page {current_page} failed to load ({current_url}): {e}"
                    ) from e
                print(f"Error loading page {current_page}: {e}")
                break
```

The setup_driver call at line 156 must also respect strict mode. Wrap it:

```python
    # Set up the driver
    try:
        driver = setup_driver()
    except Exception:
        if strict_errors:
            raise
        raise  # salomon currently has no static fallback, so behaviour is unchanged here
    print("WebDriver set up successfully!")
```

(Salomon has no static fallback today; the wrap is purely for code-style parity with the other retailers and a no-op behaviour-wise.)

- [ ] **Step 4: Extract `__main__` body into `_run_cli()` and add `--url` / `--out`**

Replace the `if __name__ == "__main__":` block (lines 264-302) with a callable function plus the dispatcher:

```python
def _run_cli(argv=None):
    """CLI entrypoint, factored out of __main__ so tests can call it
    with a patched sys.argv without invoking the module-level guard."""
    import argparse

    parser = argparse.ArgumentParser(description="Scrape Salomon AU listing")
    parser.add_argument(
        "--gender",
        choices=("mens", "womens"),
        default="mens",
        help="Which listing to scrape (default: mens). One invocation per gender.",
    )
    parser.add_argument(
        "--url",
        default=None,
        help="Custom starting URL. When given, the scraper runs in strict "
             "mode (no static-fixture fallback, no swallowing of per-product "
             "errors) and writes to jsons/salomon_<gender>_custom_products.json "
             "by default. The canonical LISTING_URLS[gender] is used when omitted.",
    )
    parser.add_argument(
        "--out",
        default=None,
        help="Override the output JSON path. Defaults vary by mode: "
             "jsons/salomon_<gender>_products.json (canonical) or "
             "jsons/salomon_<gender>_custom_products.json (custom URL).",
    )
    args = parser.parse_args(argv)

    base_url = args.url if args.url else LISTING_URLS[args.gender]
    strict = bool(args.url)
    retailer = {
        'name': 'Salomon Australia',
        'website_url': 'https://salomon.com.au',
        'logo_url': 'https://salomon.com.au/cdn/shop/files/1278_1_a777c16c-54d9-4015-843d-f768f66955e3_32x32.png'
    }

    all_products = scrape_all_pages(
        base_url,
        retailer=retailer,
        gender=args.gender,
        max_pages=3,
        max_products_per_page=999,
        page_timeout=30,
        strict_errors=strict,
    )

    print(f"\nProcessed {len(all_products)} products successfully")

    if all_products:
        if args.out:
            out = args.out
        elif strict:
            out = f"jsons/salomon_{args.gender}_custom_products.json"
        else:
            out = f"jsons/salomon_{args.gender}_products.json"
        save_to_json(all_products, out)
        print(f"All done! Data has been saved to {out}")
    else:
        print("No products were scraped.")


if __name__ == "__main__":
    _run_cli()
```

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```
cd sneaker-scout-backend && python -m pytest tests/test_custom_url_cli.py -k salomon -v
```

Expected: 4 passed.

- [ ] **Step 6: Commit**

```
git -C /workspace/sneaker-scout-backend add salomon/pagination_scraper.py tests/test_custom_url_cli.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-1el): --url flag + strict mode for salomon scraper

Adds --url to the salomon CLI: when supplied, the scraper uses that URL
as the listing starting point, runs scrape_all_pages with
strict_errors=True (so driver / listing / per-product failures raise
instead of being swallowed), and writes to a *_custom_products.json
file so it doesn't clobber the canonical scrape output.

Refactors __main__ into _run_cli() so the wiring can be unit-tested
with a patched sys.argv without invoking Selenium."
```

---

## Task 3: HypeDC — `--url` + `strict_errors` + strip `?page=`

**Files:**
- Modify: `sneaker-scout-backend/hypedc/pagination_scraper.py:374-552`.
- Modify: `sneaker-scout-backend/tests/test_custom_url_cli.py` (append).

- [ ] **Step 1: Write the failing test (append to existing test file)**

Append to `sneaker-scout-backend/tests/test_custom_url_cli.py`:

```python
# ---------------------------------------------------------------------------
# HypeDC
# ---------------------------------------------------------------------------

def test_hypedc_url_flag_strips_inbound_page_param(monkeypatch):
    """If the user passes `?page=3&filter=nike`, the URL pagination
    helper must compute page-2 of the run as `?filter=nike&page=2`
    (filter preserved, inbound page stripped, new page appended).
    """
    mod = importlib.import_module("hypedc.pagination_scraper")

    base_with_page = "https://www.hypedc.com/au/categories/mens/footwear/sneakers?page=3&filter=nike"
    # The custom-URL pipeline strips inbound `page` first.
    cleaned = mod._strip_inbound_pagination(base_with_page)
    assert "page=" not in cleaned
    assert "filter=nike" in cleaned

    assert mod._build_page_url(cleaned, 2).endswith("page=2")


def test_hypedc_url_flag_sets_strict_and_custom_output(tmp_path, monkeypatch):
    captured = {}

    def fake_scrape(base_url=None, retailer=None, gender="mens",
                    max_pages=3, max_products_per_page=3,
                    strict_errors=False):
        captured["base_url"] = base_url
        captured["strict_errors"] = strict_errors
        return [{"sneaker": {"name": "stub"}}]

    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, "argv", [
        "hypedc.pagination_scraper",
        "--gender=womens",
        "--url=https://www.hypedc.com/au/categories/womens/footwear/sneakers?brand=nike",
    ])

    mod = importlib.import_module("hypedc.pagination_scraper")
    monkeypatch.setattr(mod, "scrape_all_pages", fake_scrape)
    mod._run_cli()

    assert captured["strict_errors"] is True
    assert "brand=nike" in captured["base_url"]
    assert (tmp_path / "jsons" / "hypedc_womens_custom_products.json").exists()


def test_hypedc_strict_setup_driver_failure_raises(monkeypatch):
    mod = importlib.import_module("hypedc.pagination_scraper")
    monkeypatch.setattr(mod, "setup_driver", lambda: (_ for _ in ()).throw(RuntimeError("no chrome")))
    with pytest.raises(RuntimeError, match="no chrome"):
        mod.scrape_all_pages(
            base_url="https://www.hypedc.com/au/categories/mens/footwear/sneakers",
            gender="mens", max_pages=1, max_products_per_page=1,
            strict_errors=True,
        )
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```
cd sneaker-scout-backend && python -m pytest tests/test_custom_url_cli.py -k hypedc -v
```

Expected: AttributeError (`_strip_inbound_pagination`, `_run_cli` undefined) and signature mismatch on `strict_errors`.

- [ ] **Step 3: Add `_strip_inbound_pagination` helper, `strict_errors`, and `_run_cli`**

Edit `sneaker-scout-backend/hypedc/pagination_scraper.py`.

Near the top with the other imports add:

```python
from utils.url_helpers import strip_query_param
```

Add this helper just below `_build_page_url` (around line 380):

```python
def _strip_inbound_pagination(url):
    """Remove an inbound `?page=N` from a custom starting URL so the
    retailer's own _build_page_url doesn't end up emitting duplicated
    `page=` params on subsequent pages. Filters and sort params are
    preserved."""
    return strip_query_param(url, "page")
```

Update the `scrape_all_pages` signature (line 413-419):

```python
def scrape_all_pages(
    base_url=None,
    retailer=None,
    gender="mens",
    max_pages=3,
    max_products_per_page=3,
    strict_errors=False,
):
```

Inside `scrape_all_pages`, the setup_driver block (lines 437-442) becomes:

```python
    try:
        driver = setup_driver()
        print("WebDriver set up successfully (undetected-chromedriver)")
    except Exception as exc:
        if strict_errors:
            raise
        print(f"setup_driver() failed: {exc}")
        return _scrape_via_static_fallback(retailer, gender, max_products_per_page)
```

The retry-with-fresh-driver block (lines 459-477) becomes:

```python
            except Exception as exc:
                if strict_errors:
                    raise RuntimeError(
                        f"Listing page {page_num} ({current_url}) failed to load: {exc}"
                    ) from exc
                print(f"  Page {page_num} failed ({exc.__class__.__name__}), retrying with fresh driver…")
                try:
                    driver.quit()
                except Exception:
                    pass
                try:
                    driver = setup_driver()
                    time.sleep(3)
                    driver.get(current_url)
                    WebDriverWait(driver, 12).until(
                        EC.presence_of_element_located((By.CSS_SELECTOR, "li[data-plp-product]"))
                    )
                    print(f"Page {page_num} loaded (after retry)")
                except Exception as exc2:
                    print(f"  Retry also failed: {exc2}")
                    if page_num == 1 and not all_products:
                        return _scrape_via_static_fallback(retailer, gender, max_products_per_page)
                    break
```

The per-product `except` (lines 502-512) becomes:

```python
                except Exception as exc:
                    if strict_errors:
                        raise
                    summary = log_detail_error(
                        _err_logger,
                        exc,
                        url=product_url,
                        retailer="hypedc",
                        product_name=name,
                        brand=basic.get("brand"),
                    )
                    print(f"    Detail-page error: {summary} — skipping (see logs/hypedc_scrape_errors.log)")
                    continue
```

Replace the `__main__` block (lines 529-551) with the same `_run_cli` pattern as Task 2:

```python
def _run_cli(argv=None):
    import argparse

    parser = argparse.ArgumentParser(description="Scrape Hype DC listing")
    parser.add_argument(
        "--gender", choices=("mens", "womens"), default="mens",
        help="Which listing to scrape (default: mens).",
    )
    parser.add_argument(
        "--url", default=None,
        help="Custom starting URL. Strict mode: setup/listing/PDP errors "
             "raise; static-fixture fallback is disabled. Inbound `?page=N` "
             "is stripped before pagination resumes from this URL.",
    )
    parser.add_argument(
        "--out", default=None,
        help="Override output path. Defaults to "
             "jsons/hypedc_<gender>_products.json (canonical) or "
             "jsons/hypedc_<gender>_custom_products.json (custom URL).",
    )
    args = parser.parse_args(argv)

    if args.url:
        base_url = _strip_inbound_pagination(args.url)
        strict = True
    else:
        base_url = LISTING_URLS[args.gender]
        strict = False

    products = scrape_all_pages(
        base_url=base_url,
        retailer=RETAILER,
        gender=args.gender,
        max_pages=3,
        max_products_per_page=999,
        strict_errors=strict,
    )
    if products:
        if args.out:
            out = args.out
        elif strict:
            out = f"jsons/hypedc_{args.gender}_custom_products.json"
        else:
            out = f"jsons/hypedc_{args.gender}_products.json"
        save_to_json(products, out)
        print(f"\nSaved {len(products)} products to {out}")
    else:
        print("No products scraped")


if __name__ == "__main__":
    _run_cli()
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```
cd sneaker-scout-backend && python -m pytest tests/test_custom_url_cli.py -k hypedc -v
```

Expected: 3 passed.

- [ ] **Step 5: Commit**

```
git -C /workspace/sneaker-scout-backend add hypedc/pagination_scraper.py tests/test_custom_url_cli.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-1el): --url flag + strict mode for hypedc scraper

Adds --url to the hypedc CLI with the same semantics as salomon, plus
an inbound-pagination strip so a user URL like
'?page=3&brand=nike' becomes '?brand=nike' before _build_page_url
takes over. Filter and sort params survive.

Strict mode disables the static-fixture fallback (which only matches
the canonical category URL) and re-raises per-product detail errors."
```

---

## Task 4: Platypus — `--url` + `strict_errors`

**Files:**
- Modify: `sneaker-scout-backend/platypus/pagination_scraper.py:481-627`.
- Modify: `sneaker-scout-backend/tests/test_custom_url_cli.py` (append).

Platypus uses LOAD MORE clicks rather than URL-based pagination, so no `_strip_inbound_pagination` is needed — a custom URL is just loaded as the initial page and the LOAD MORE click loop continues from there.

- [ ] **Step 1: Write the failing test**

Append to `sneaker-scout-backend/tests/test_custom_url_cli.py`:

```python
# ---------------------------------------------------------------------------
# Platypus
# ---------------------------------------------------------------------------

def test_platypus_url_flag_sets_strict_and_custom_output(tmp_path, monkeypatch):
    captured = {}

    def fake_scrape(base_url=None, retailer=None, gender="mens",
                    max_pages=1, max_products_per_page=3,
                    strict_errors=False):
        captured["base_url"] = base_url
        captured["strict_errors"] = strict_errors
        return [{"sneaker": {"name": "stub"}}]

    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, "argv", [
        "platypus.pagination_scraper",
        "--gender=mens",
        "--url=https://www.platypusshoes.com.au/shop/mens/brands/nike",
    ])

    mod = importlib.import_module("platypus.pagination_scraper")
    monkeypatch.setattr(mod, "scrape_all_pages", fake_scrape)
    mod._run_cli()

    assert captured["base_url"] == "https://www.platypusshoes.com.au/shop/mens/brands/nike"
    assert captured["strict_errors"] is True
    assert (tmp_path / "jsons" / "platypus_mens_custom_products.json").exists()


def test_platypus_strict_listing_load_failure_raises(monkeypatch):
    """Listing-load failure inside strict mode must propagate as a
    RuntimeError mentioning the URL, not be swallowed by the
    static-fixture fallback."""
    mod = importlib.import_module("platypus.pagination_scraper")

    class FakeDriver:
        def get(self, url): raise TimeoutError("nav timed out")
        def quit(self): pass

    monkeypatch.setattr(mod, "setup_driver", lambda: FakeDriver())
    monkeypatch.setattr(mod, "warm_up_session", lambda d, r: None)

    with pytest.raises(RuntimeError, match="listing"):
        mod.scrape_all_pages(
            base_url="https://www.platypusshoes.com.au/shop/mens/brands/nike",
            gender="mens", max_pages=1, max_products_per_page=1,
            strict_errors=True,
        )
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```
cd sneaker-scout-backend && python -m pytest tests/test_custom_url_cli.py -k platypus -v
```

Expected: AttributeError (`_run_cli` undefined), signature mismatch on `strict_errors`.

- [ ] **Step 3: Add `strict_errors` and `_run_cli`**

Edit `sneaker-scout-backend/platypus/pagination_scraper.py`.

Update the `scrape_all_pages` signature (lines 481-487):

```python
def scrape_all_pages(
    base_url=None,
    retailer=None,
    gender="mens",
    max_pages=1,
    max_products_per_page=3,
    strict_errors=False,
):
```

Setup_driver block (lines 502-507):

```python
    try:
        driver = setup_driver()
        print("WebDriver set up successfully (undetected-chromedriver)")
    except Exception as exc:
        if strict_errors:
            raise
        print(f"setup_driver() failed: {exc}")
        return _scrape_via_static_fallback(retailer, max_products_per_page, gender)
```

Listing-load failure block (lines 514-536) — wrap the full try/retry/fall-back path so strict mode raises on the first failure with the URL in the message:

```python
        print(f"\n--- Loading listing ---\nURL: {base_url}")
        try:
            driver.get(base_url)
            WebDriverWait(driver, 12).until(
                EC.presence_of_element_located((By.CSS_SELECTOR, "div.productCard"))
            )
            print("Listing loaded")
        except Exception as exc:
            if strict_errors:
                raise RuntimeError(
                    f"Platypus listing ({base_url}) failed to load: {exc}"
                ) from exc
            print(f"  Listing failed ({exc.__class__.__name__}), retrying with fresh driver…")
            try:
                driver.quit()
            except Exception:
                pass
            try:
                driver = setup_driver()
                time.sleep(3)
                driver.get(base_url)
                WebDriverWait(driver, 12).until(
                    EC.presence_of_element_located((By.CSS_SELECTOR, "div.productCard"))
                )
                print("Listing loaded (after retry)")
            except Exception as exc2:
                print(f"  Retry also failed: {exc2}")
                return _scrape_via_static_fallback(retailer, max_products_per_page, gender)
```

LOAD MORE loop (lines 539-553) — when LOAD MORE silently fails in strict mode, raise:

```python
        for click_idx in range(max(0, max_pages - 1)):
            cards_before = len(driver.find_elements(By.CSS_SELECTOR, "div.productCard"))
            if not _click_load_more(driver):
                if strict_errors:
                    raise RuntimeError(
                        f"LOAD MORE click {click_idx+1}: button not visible "
                        "(expected more pages but the listing exposed none)"
                    )
                print("  No LOAD MORE button visible — done expanding")
                break
            try:
                WebDriverWait(driver, 10).until(
                    lambda d: len(d.find_elements(By.CSS_SELECTOR, "div.productCard")) > cards_before
                )
                cards_after = len(driver.find_elements(By.CSS_SELECTOR, "div.productCard"))
                print(f"  LOAD MORE click {click_idx+1}: {cards_before} → {cards_after} cards")
            except TimeoutException:
                if strict_errors:
                    raise RuntimeError(
                        f"LOAD MORE click {click_idx+1}: card count did not grow within 10s"
                    )
                print(f"  LOAD MORE click {click_idx+1}: card count didn't grow — stopping")
                break
            time.sleep(3)
```

`if not page_basics:` block (lines 557-558):

```python
        if not page_basics:
            if strict_errors:
                raise RuntimeError(
                    f"Platypus listing ({base_url}) parsed to zero product cards"
                )
            return _scrape_via_static_fallback(retailer, max_products_per_page, gender)
```

Per-product `except` (lines 577-587):

```python
            except Exception as exc:
                if strict_errors:
                    raise
                summary = log_detail_error(
                    _err_logger,
                    exc,
                    url=product_url,
                    retailer="platypus",
                    product_name=name,
                    brand=basic.get("brand"),
                )
                print(f"    Detail-page error: {summary} — skipping (see logs/platypus_scrape_errors.log)")
                continue
```

Replace the `__main__` block (lines 602-627) with:

```python
def _run_cli(argv=None):
    import argparse

    parser = argparse.ArgumentParser(description="Scrape Platypus Shoes listing")
    parser.add_argument(
        "--gender", choices=("mens", "womens"), default="mens",
        help="Which listing to scrape (default: mens).",
    )
    parser.add_argument(
        "--url", default=None,
        help="Custom starting URL. Strict mode: setup / listing-load / "
             "LOAD-MORE / PDP errors raise; static-fixture fallback is "
             "disabled. The URL is loaded as the initial page; LOAD MORE "
             "clicks continue from there.",
    )
    parser.add_argument(
        "--out", default=None,
        help="Override output path. Defaults to "
             "jsons/platypus_<gender>_products.json (canonical) or "
             "jsons/platypus_<gender>_custom_products.json (custom URL).",
    )
    args = parser.parse_args(argv)

    base_url = args.url if args.url else LISTING_URLS[args.gender]
    strict = bool(args.url)

    products = scrape_all_pages(
        base_url=base_url,
        retailer=RETAILER,
        gender=args.gender,
        max_pages=3,
        max_products_per_page=999,
        strict_errors=strict,
    )
    if products:
        if args.out:
            out = args.out
        elif strict:
            out = f"jsons/platypus_{args.gender}_custom_products.json"
        else:
            out = f"jsons/platypus_{args.gender}_products.json"
        save_to_json(products, out)
        print(f"\nSaved {len(products)} products to {out}")
    else:
        print("No products scraped")


if __name__ == "__main__":
    _run_cli()
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```
cd sneaker-scout-backend && python -m pytest tests/test_custom_url_cli.py -k platypus -v
```

Expected: 2 passed.

- [ ] **Step 5: Commit**

```
git -C /workspace/sneaker-scout-backend add platypus/pagination_scraper.py tests/test_custom_url_cli.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-1el): --url flag + strict mode for platypus scraper

Same shape as salomon/hypedc: --url loads an arbitrary listing as the
initial page; LOAD MORE clicks continue expanding from there. Strict
mode also raises when LOAD MORE silently fails (button missing or card
count doesn't grow), which today is logged-and-broken-out-of.

Output goes to *_custom_products.json so the canonical run isn't
clobbered."
```

---

## Task 5: Foot Locker — `--url` + `strict_errors` + skip mega-menu

**Files:**
- Modify: `sneaker-scout-backend/footlocker/pagination_scraper.py:923-1186`.
- Modify: `sneaker-scout-backend/tests/test_custom_url_cli.py` (append).

Foot Locker has the most complex flow: a mega-menu click-through, OneTrust cookie handling, in-session card-click PDP navigation. The relevant change for strict mode is to skip the mega-menu (which is `mens` / `womens`-keyed and won't make sense for an arbitrary filtered URL) and go direct via `_ensure_listing(driver, base_url)`.

- [ ] **Step 1: Write the failing test**

Append to `sneaker-scout-backend/tests/test_custom_url_cli.py`:

```python
# ---------------------------------------------------------------------------
# Foot Locker
# ---------------------------------------------------------------------------

def test_footlocker_url_flag_sets_strict_and_skips_megamenu(tmp_path, monkeypatch):
    captured = {}

    def fake_scrape(base_url=..., retailer=None, gender="mens",
                    max_products_per_page=3, max_pages=1,
                    section="mens", strict_errors=False):
        captured["base_url"] = base_url
        captured["strict_errors"] = strict_errors
        captured["section"] = section
        return [{"sneaker": {"name": "stub"}}]

    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, "argv", [
        "footlocker.pagination_scraper",
        "--gender=mens",
        "--url=https://www.footlocker.com.au/en/category/brands/on",
    ])

    mod = importlib.import_module("footlocker.pagination_scraper")
    monkeypatch.setattr(mod, "scrape_all_pages", fake_scrape)
    mod._run_cli()

    assert captured["strict_errors"] is True
    assert captured["base_url"] == "https://www.footlocker.com.au/en/category/brands/on"
    assert (tmp_path / "jsons" / "footlocker_mens_custom_products.json").exists()


def test_footlocker_strict_skips_navigate_via_menu(monkeypatch):
    """In strict mode, the mega-menu click-through is skipped — we go
    directly to base_url via _ensure_listing. This isolates strict mode
    from Akamai BMP click-stream heuristics that may not match the
    arbitrary URL the operator passed."""
    mod = importlib.import_module("footlocker.pagination_scraper")

    calls = {"menu": 0, "ensure": 0}

    def fake_menu(driver, mens_or_womens="mens"):
        calls["menu"] += 1
        return True

    def fake_ensure(driver, url):
        calls["ensure"] += 1
        return True

    class FakeDriver:
        page_source = "<html></html>"
        current_url = "https://www.footlocker.com.au/foo"
        def find_elements(self, *a, **kw): return []
        def get(self, url): pass
        def quit(self): pass
        def back(self): pass

    monkeypatch.setattr(mod, "setup_driver", lambda: FakeDriver())
    monkeypatch.setattr(mod, "warm_up_session", lambda d, r: None)
    monkeypatch.setattr(mod, "navigate_to_listing_via_menu", fake_menu)
    monkeypatch.setattr(mod, "_ensure_listing", fake_ensure)
    monkeypatch.setattr(mod, "is_attached_mode", lambda: False)
    # parse_listing_page must return [] so we exit fast on page 0 in strict mode → raise.
    monkeypatch.setattr(mod, "parse_listing_page", lambda src: [])

    with pytest.raises(RuntimeError):
        mod.scrape_all_pages(
            base_url="https://www.footlocker.com.au/en/category/brands/on",
            gender="mens", max_products_per_page=1, max_pages=1,
            section="mens", strict_errors=True,
        )
    assert calls["menu"] == 0, "mega-menu nav must be skipped in strict mode"
    assert calls["ensure"] >= 1, "must navigate directly via _ensure_listing"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```
cd sneaker-scout-backend && python -m pytest tests/test_custom_url_cli.py -k footlocker -v
```

Expected: AttributeError (`_run_cli` undefined), signature mismatch.

- [ ] **Step 3: Add `strict_errors` and `_run_cli`**

Edit `sneaker-scout-backend/footlocker/pagination_scraper.py`.

Update the `scrape_all_pages` signature (lines 923-930):

```python
def scrape_all_pages(
    base_url=LISTING_URL,
    retailer=None,
    gender="mens",
    max_products_per_page=3,
    max_pages=1,
    section="mens",
    strict_errors=False,
):
```

Setup_driver block (lines 953-958):

```python
    try:
        driver = setup_driver()
        print("WebDriver set up successfully (undetected-chromedriver)")
    except Exception as exc:
        if strict_errors:
            raise
        print(f"setup_driver() failed: {exc}")
        return _scrape_via_static_fallback(retailer, max_products_per_page, gender)
```

Mega-menu vs direct nav block (lines 982-986). Replace with:

```python
        if not already_on_listing:
            if strict_errors:
                # Skip the mega-menu click-through: it's `mens`/`womens`-
                # keyed and won't make sense for an arbitrary filtered
                # URL. Go direct.
                if not _ensure_listing(driver, base_url):
                    raise RuntimeError(
                        f"Foot Locker listing ({base_url}) could not be loaded"
                    )
            else:
                if not navigate_to_listing_via_menu(driver, mens_or_womens=section):
                    print(f"  Falling back to direct listing URL: {base_url}")
                    if not _ensure_listing(driver, base_url):
                        return _scrape_via_static_fallback(retailer, max_products_per_page, gender)
```

Empty-first-page block (lines 1005-1014). Replace with:

```python
            if not page_basics:
                if page_idx == 0:
                    os.makedirs("diag", exist_ok=True)
                    diag_path = os.path.join("diag", "footlocker_listing_dump.html")
                    with open(diag_path, "w", encoding="utf-8") as f:
                        f.write(page_source)
                    print(f"  0 products on first page — dumped HTML to {diag_path}")
                    if strict_errors:
                        raise RuntimeError(
                            f"Foot Locker listing ({base_url}) parsed to zero cards "
                            f"(HTML dump at {diag_path})"
                        )
                    return _scrape_via_static_fallback(retailer, max_products_per_page, gender)
                print("  Empty listing page — assuming end of results")
                break
```

Card-click / URL-fallback per-product `except` blocks (lines 1044-1053 and 1061-1071). Replace each `log_detail_error` block with:

```python
                    except Exception as exc:
                        if strict_errors:
                            raise
                        summary = log_detail_error(
                            _err_logger,
                            exc,
                            url=product_url,
                            retailer="footlocker",
                            product_name=name,
                            brand=basic.get("brand"),
                        )
                        print(f"    Detail-page error: {summary} — skipping (see logs/footlocker_scrape_errors.log)")
                        detailed = {}
```

(Two occurrences — one in the `click_card_to_pdp` branch, one in the `render_and_parse_pdp` branch.)

Replace the `__main__` block (lines 1154-1186) with `_run_cli`:

```python
def _run_cli(argv=None):
    import argparse

    parser = argparse.ArgumentParser(description="Scrape Foot Locker AU listing")
    parser.add_argument(
        "--gender", choices=("mens", "womens"), default="mens",
        help="Which listing to scrape (default: mens).",
    )
    parser.add_argument(
        "--url", default=None,
        help="Custom starting URL. Strict mode: setup / listing / per-PDP "
             "errors raise; static-fixture fallback is disabled; mega-menu "
             "click-through is skipped (we go directly to the URL via "
             "_ensure_listing).",
    )
    parser.add_argument(
        "--out", default=None,
        help="Override output path. Defaults to "
             "jsons/footlocker_<gender>_products.json (canonical) or "
             "jsons/footlocker_<gender>_custom_products.json (custom URL).",
    )
    args = parser.parse_args(argv)

    max_pages = int(os.environ.get("FOOTLOCKER_MAX_PAGES", "3"))
    max_per_page = int(os.environ.get("FOOTLOCKER_MAX_PER_PAGE", "999"))

    base_url = args.url if args.url else LISTING_URLS[args.gender]
    strict = bool(args.url)

    products = scrape_all_pages(
        base_url=base_url,
        retailer=RETAILER,
        gender=args.gender,
        max_products_per_page=max_per_page,
        max_pages=max_pages,
        section=args.gender,
        strict_errors=strict,
    )
    if products:
        if args.out:
            out = args.out
        elif strict:
            out = f"jsons/footlocker_{args.gender}_custom_products.json"
        else:
            out = f"jsons/footlocker_{args.gender}_products.json"
        save_to_json(products, out)
        print(f"\nSaved {len(products)} products to {out}")
    else:
        print("No products scraped")


if __name__ == "__main__":
    _run_cli()
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```
cd sneaker-scout-backend && python -m pytest tests/test_custom_url_cli.py -k footlocker -v
```

Expected: 2 passed.

- [ ] **Step 5: Commit**

```
git -C /workspace/sneaker-scout-backend add footlocker/pagination_scraper.py tests/test_custom_url_cli.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-1el): --url flag + strict mode for footlocker scraper

Adds --url to the footlocker CLI. Strict mode skips the mens/womens
mega-menu click-through (which doesn't fit an arbitrary filtered URL)
and navigates directly via _ensure_listing. Setup, listing-load and
per-PDP errors raise instead of falling back to the static fixture.

The cookie-banner / OneTrust handling and Akamai warm-up dance still
run — they're orthogonal to which URL we're targeting."
```

---

## Task 6: JD Sports — `--url` + `strict_errors` + strip `?from=`

**Files:**
- Modify: `sneaker-scout-backend/jdsports/pagination_scraper.py:525-715`.
- Modify: `sneaker-scout-backend/tests/test_custom_url_cli.py` (append).

JD Sports paginates via `?from=N` offsets (72 items per page), so the inbound-pagination strip targets `from`.

- [ ] **Step 1: Write the failing test**

Append to `sneaker-scout-backend/tests/test_custom_url_cli.py`:

```python
# ---------------------------------------------------------------------------
# JD Sports
# ---------------------------------------------------------------------------

def test_jdsports_url_flag_strips_inbound_from_param():
    mod = importlib.import_module("jdsports.pagination_scraper")
    base = "https://www.jdsports.com.au/men/trainers/?from=144&brand=nike"
    cleaned = mod._strip_inbound_pagination(base)
    assert "from=" not in cleaned
    assert "brand=nike" in cleaned
    # _build_page_url(_, 2) should emit from=144 (page_idx * 72).
    assert mod._build_page_url(cleaned, 2).endswith("from=144")


def test_jdsports_url_flag_sets_strict_and_custom_output(tmp_path, monkeypatch):
    captured = {}

    def fake_scrape(base_url=..., retailer=None, gender="mens",
                    max_pages=1, max_products_per_page=3,
                    strict_errors=False):
        captured["base_url"] = base_url
        captured["strict_errors"] = strict_errors
        return [{"sneaker": {"name": "stub"}}]

    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, "argv", [
        "jdsports.pagination_scraper",
        "--gender=womens",
        "--url=https://www.jdsports.com.au/women/trainers/?brand=nike",
    ])

    mod = importlib.import_module("jdsports.pagination_scraper")
    monkeypatch.setattr(mod, "scrape_all_pages", fake_scrape)
    mod._run_cli()

    assert captured["strict_errors"] is True
    assert "brand=nike" in captured["base_url"]
    assert (tmp_path / "jsons" / "jdsports_womens_custom_products.json").exists()


def test_jdsports_strict_listing_load_raises(monkeypatch):
    mod = importlib.import_module("jdsports.pagination_scraper")

    class FakeDriver:
        def get(self, url): raise TimeoutError("nav timed out")
        def quit(self): pass

    monkeypatch.setattr(mod, "setup_driver", lambda: FakeDriver())
    monkeypatch.setattr(mod, "warm_up_session", lambda d, r: None)

    with pytest.raises((RuntimeError, TimeoutError)):
        mod.scrape_all_pages(
            base_url="https://www.jdsports.com.au/men/trainers/",
            gender="mens", max_pages=1, max_products_per_page=1,
            strict_errors=True,
        )
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```
cd sneaker-scout-backend && python -m pytest tests/test_custom_url_cli.py -k jdsports -v
```

Expected: AttributeError (`_strip_inbound_pagination`, `_run_cli` undefined), signature mismatch.

- [ ] **Step 3: Add `_strip_inbound_pagination`, `strict_errors`, and `_run_cli`**

Edit `sneaker-scout-backend/jdsports/pagination_scraper.py`.

Add import near the top:

```python
from utils.url_helpers import strip_query_param
```

Add helper just below `_build_page_url` (around line 538):

```python
def _strip_inbound_pagination(url):
    """Remove an inbound `?from=N` from a custom starting URL so
    `_build_page_url` doesn't end up emitting duplicate `from=` params
    on subsequent pages. Filters and sort params are preserved."""
    return strip_query_param(url, "from")
```

Update the `scrape_all_pages` signature (lines 567-573):

```python
def scrape_all_pages(
    base_url=LISTING_URL,
    retailer=None,
    gender="mens",
    max_pages=1,
    max_products_per_page=3,
    strict_errors=False,
):
```

Setup_driver block (lines 585-590):

```python
    try:
        driver = setup_driver()
        print("WebDriver set up successfully (undetected-chromedriver)")
    except Exception as exc:
        if strict_errors:
            raise
        print(f"setup_driver() failed: {exc}")
        return _scrape_via_static_fallback(retailer, max_products_per_page, gender)
```

Listing-load block (lines 600-610):

```python
            try:
                driver.get(page_url)
                WebDriverWait(driver, 30).until(
                    EC.presence_of_element_located((By.CSS_SELECTOR, "li.productListItem"))
                )
                print("Listing loaded")
            except Exception as exc:
                if strict_errors:
                    raise RuntimeError(
                        f"JD Sports listing page {page_idx + 1} ({page_url}) failed to load: {exc}"
                    ) from exc
                print(f"  Listing failed ({exc.__class__.__name__}): {exc}")
                if page_idx == 0:
                    return _scrape_via_static_fallback(retailer, max_products_per_page, gender)
                break
```

Empty-first-page block (lines 616-625):

```python
            if not page_basics:
                if page_idx == 0:
                    os.makedirs("diag", exist_ok=True)
                    diag_path = os.path.join("diag", "jdsports_listing_dump.html")
                    with open(diag_path, "w", encoding="utf-8") as f:
                        f.write(page_source)
                    print(f"  0 products — dumped listing HTML to {diag_path}")
                    if strict_errors:
                        raise RuntimeError(
                            f"JD Sports listing ({page_url}) parsed to zero cards "
                            f"(HTML dump at {diag_path})"
                        )
                    return _scrape_via_static_fallback(retailer, max_products_per_page, gender)
                print("  Empty page — assuming end of listing")
                break
```

Per-product `except` (lines 649-659):

```python
                except Exception as exc:
                    if strict_errors:
                        raise
                    summary = log_detail_error(
                        _err_logger,
                        exc,
                        url=product_url,
                        retailer="jdsports",
                        product_name=name,
                        brand=basic.get("brand"),
                    )
                    print(f"    Detail-page error: {summary} — skipping (see logs/jdsports_scrape_errors.log)")
                    continue
```

Replace the `__main__` block (lines 690-714) with:

```python
def _run_cli(argv=None):
    import argparse

    parser = argparse.ArgumentParser(description="Scrape JD Sports AU listing")
    parser.add_argument(
        "--gender", choices=("mens", "womens"), default="mens",
        help="Which listing to scrape (default: mens).",
    )
    parser.add_argument(
        "--url", default=None,
        help="Custom starting URL. Strict mode: setup / listing / per-PDP "
             "errors raise; static-fixture fallback is disabled. Inbound "
             "`?from=N` is stripped before pagination resumes from the URL.",
    )
    parser.add_argument(
        "--out", default=None,
        help="Override output path. Defaults to "
             "jsons/jdsports_<gender>_products.json (canonical) or "
             "jsons/jdsports_<gender>_custom_products.json (custom URL).",
    )
    args = parser.parse_args(argv)

    max_pages = int(os.environ.get("JDSPORTS_MAX_PAGES", "1"))
    max_per_page = int(os.environ.get("JDSPORTS_MAX_PER_PAGE", "3"))

    if args.url:
        base_url = _strip_inbound_pagination(args.url)
        strict = True
    else:
        base_url = LISTING_URLS[args.gender]
        strict = False

    products = scrape_all_pages(
        base_url=base_url,
        retailer=RETAILER,
        gender=args.gender,
        max_pages=max_pages,
        max_products_per_page=max_per_page,
        strict_errors=strict,
    )
    if products:
        if args.out:
            out = args.out
        elif strict:
            out = f"jsons/jdsports_{args.gender}_custom_products.json"
        else:
            out = f"jsons/jdsports_{args.gender}_products.json"
        save_to_json(products, out)
        print(f"\nSaved {len(products)} products to {out}")
    else:
        print("No products scraped")


if __name__ == "__main__":
    _run_cli()
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```
cd sneaker-scout-backend && python -m pytest tests/test_custom_url_cli.py -k jdsports -v
```

Expected: 3 passed.

- [ ] **Step 5: Commit**

```
git -C /workspace/sneaker-scout-backend add jdsports/pagination_scraper.py tests/test_custom_url_cli.py
git -C /workspace/sneaker-scout-backend commit -m "feat(sneaker_scout-1el): --url flag + strict mode for jdsports scraper

Adds --url to the jdsports CLI with the same shape as the other four
retailers, plus an inbound-pagination strip for ?from= (the offset
JD Sports uses for paging — 72 items per page). Filter and sort
params survive; setup/listing/per-PDP errors raise in strict mode."
```

---

## Task 7: Docs update + full-suite smoke + bd close

**Files:**
- Modify: `sneaker-scout-backend/CLAUDE.md`
- Modify: `CLAUDE.md` (project root, optional cross-reference)

- [ ] **Step 1: Append a "Scraping a custom URL" section to `sneaker-scout-backend/CLAUDE.md`**

Add this section after the "Running Scrapers" block:

```markdown
### Custom starting URLs

Every retailer's `pagination_scraper.py` accepts `--url <listing-url>`:

```bash
cd sneaker-scout-backend
python -m salomon.pagination_scraper --gender=mens --url='https://salomon.com.au/collections/mens/trail-running-shoes'
python -m hypedc.pagination_scraper --gender=mens --url='https://www.hypedc.com/au/categories/mens/footwear/sneakers?brand=nike'
python -m platypus.pagination_scraper --gender=womens --url='https://www.platypusshoes.com.au/shop/womens/brands/asics'
python -m footlocker.pagination_scraper --gender=mens --url='https://www.footlocker.com.au/en/category/brands/on'
python -m jdsports.pagination_scraper --gender=mens --url='https://www.jdsports.com.au/men/trainers/brand/nike/'
```

`--gender` is still required — it tags `colorway.gender` in the output
JSON. Inbound pagination params (`?page=N` / `?from=N`) are stripped
from the URL automatically so the retailer's own paging logic isn't
double-encoded; filters and sort params survive.

**Strict-mode semantics.** When `--url` is supplied, the scraper runs in
strict mode:

- `setup_driver()` failure → exception propagates (no static-fixture
  fallback — the fixture only matches the canonical category URL).
- Listing-load failure → exception with the URL.
- Empty listing → exception (HTML dumped to `diag/<retailer>_listing_dump.html`).
- Per-product PDP error → exception (not logged-and-skipped).
- Pagination / LOAD MORE / mega-menu skipped or raises (footlocker skips
  the mega-menu in strict mode and goes direct).

Output goes to `jsons/<retailer>_<gender>_custom_products.json` by
default so it doesn't clobber the canonical run. Override with `--out`.
```

- [ ] **Step 2: Run the full test suite to confirm nothing else broke**

Run:
```
cd sneaker-scout-backend && python -m pytest tests/test_url_helpers.py tests/test_custom_url_cli.py -v
```

Expected: 7 + 13 = 20 passed (7 helper tests, 13 CLI tests across 5 retailers).

Then run the rest of the suite to confirm no regressions:
```
cd sneaker-scout-backend && python -m pytest tests/ -v --ignore=tests/test_import.py
```

(`test_import.py` is already broken per beads issue `sneaker_scout-jr5`; skip it.)

Expected: all other tests still pass.

- [ ] **Step 3: Close the beads issue and commit**

```
cd /workspace
bd close sneaker_scout-1el --reason="Custom --url flag landed on all 5 retailers (salomon, hypedc, platypus, footlocker, jdsports). Strict mode raises on setup/listing/PDP/pagination failures and disables static-fixture fallback. Inbound page/from params are stripped for hypedc and jdsports."

git -C /workspace/sneaker-scout-backend add CLAUDE.md
git -C /workspace/sneaker-scout-backend commit -m "docs(sneaker_scout-1el): document --url flag + strict-mode semantics

Closes: sneaker_scout-1el"

git -C /workspace add .beads/
git -C /workspace commit -m "chore: bd state for sneaker_scout-1el close"
```

- [ ] **Step 4: Verify**

```
cd /workspace && bd show sneaker_scout-1el | head -5
```

Expected: status is `closed`.

---

## Self-Review

**Spec coverage:**
- "edit the pagination_scrapers of all the retailers" — Tasks 2–6 cover all five.
- "use custom urls as the starting scrape location" — `--url` flag in every CLI; `scrape_all_pages(base_url=...)` already accepted the URL, the change is at the CLI + inbound-pagination layer.
- "raise any errors that come up during the scraping for if custom url" — `strict_errors=True` is set by the CLI when `--url` is supplied; covered in Tasks 2–6 and tested with `pytest.raises` for setup-driver / listing-load / per-product / LOAD MORE / mega-menu paths.

**Placeholder scan:** No "TBD" / "implement later" / "similar to Task N" — every code step has the exact code or exact edit to make.

**Type consistency:** `strict_errors: bool = False`, `_run_cli(argv=None)`, `_strip_inbound_pagination(url) -> str`, `strip_query_param(url, name) -> str` — same names and signatures throughout the plan.

**One subtle gap:** the `_run_cli` test stub in salomon (Task 2) writes a JSON file by virtue of `save_to_json` running. The `chdir(tmp_path)` ensures it writes to a temp dir; the test asserts the file path. Same pattern is used across all retailer CLI tests. The stub returns `[{"sneaker": {"name": "stub"}}]` which is truthy so `save_to_json` is invoked.
