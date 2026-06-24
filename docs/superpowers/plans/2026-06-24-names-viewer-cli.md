# Names-viewer CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A read-only CLI that prints all unique Hype DC sneaker names so a human can inspect the list the search scrapers would search.

**Architecture:** A thin `utils/show_names.py` wrapper around the existing `utils.hype_names.extract_names()`. Names go to stdout (one per line), a count goes to stderr. No search-pipeline code changes.

**Tech Stack:** Python 3.11, argparse, pytest (run via `uv run`).

---

### Task 1: names-viewer CLI

**Files:**
- Create: `sneaker-scout-backend/utils/show_names.py`
- Test: `sneaker-scout-backend/tests/test_show_names.py`

Reuses fixture `sneaker-scout-backend/tests/fixtures/search/hype_sample.json`,
whose names dedupe to `["Air Max 90", "Gel-Kayano 14", "Samba OG"]` (blank
skipped), or with brand `["Nike Air Max 90", "ASICS Gel-Kayano 14", "adidas Samba OG"]`.

- [ ] **Step 1: Write the failing tests**

```python
# sneaker-scout-backend/tests/test_show_names.py
"""Tests for the read-only names-viewer CLI (utils.show_names)."""
import os

import utils.show_names as show_names

FIXTURE = os.path.join(os.path.dirname(__file__), "fixtures", "search", "hype_sample.json")


def test_prints_unique_names_one_per_line_to_stdout(capsys):
    show_names.main(["--names-from", FIXTURE])
    out, err = capsys.readouterr()
    assert out.splitlines() == ["Air Max 90", "Gel-Kayano 14", "Samba OG"]
    # count summary goes to stderr, not stdout
    assert "3 unique names" in err
    assert "3 unique names" not in out


def test_include_brand_prefixes_brand(capsys):
    show_names.main(["--names-from", FIXTURE, "--include-brand"])
    out, _ = capsys.readouterr()
    assert out.splitlines() == [
        "Nike Air Max 90", "ASICS Gel-Kayano 14", "adidas Samba OG",
    ]


def test_limit_caps_the_list(capsys):
    show_names.main(["--names-from", FIXTURE, "--limit", "2"])
    out, _ = capsys.readouterr()
    assert out.splitlines() == ["Air Max 90", "Gel-Kayano 14"]


def test_defaults_to_hypedc_products_json(monkeypatch, capsys):
    captured = {}

    def fake_extract(path, limit=None, include_brand=False):
        captured["path"] = path
        return ["X"]

    monkeypatch.setattr(show_names, "extract_names", fake_extract)
    show_names.main([])
    assert captured["path"] == "jsons/hypedc_products.json"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd sneaker-scout-backend && uv run python -m pytest tests/test_show_names.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'utils.show_names'`

- [ ] **Step 3: Write minimal implementation**

```python
# sneaker-scout-backend/utils/show_names.py
"""Read-only CLI: print the unique Hype DC sneaker names that the search
scrapers would search, so a human can inspect the list.

Reuses utils.hype_names.extract_names (the same extraction the search
scrapers use) so this view never drifts from what actually gets searched.
Names go to stdout (one per line, pipe/grep friendly); the count goes to
stderr so a redirected list stays clean. This does not touch the search
pipeline."""
import argparse
import sys

from utils.hype_names import extract_names

DEFAULT_NAMES_FROM = "jsons/hypedc_products.json"


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Print unique Hype DC sneaker names (view-only).")
    parser.add_argument("--names-from", default=DEFAULT_NAMES_FROM,
                        help=f"Hype DC scrape JSON to read (default: {DEFAULT_NAMES_FROM})")
    parser.add_argument("--include-brand", action="store_true",
                        help='Prefix the brand, e.g. "Nike Air Max 90"')
    parser.add_argument("--limit", type=int, default=None,
                        help="Cap the number of names shown")
    args = parser.parse_args(argv)

    names = extract_names(args.names_from, limit=args.limit,
                          include_brand=args.include_brand)
    for name in names:
        print(name)
    print(f"{len(names)} unique names", file=sys.stderr)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd sneaker-scout-backend && uv run python -m pytest tests/test_show_names.py -v`
Expected: PASS (4 passed)

- [ ] **Step 5: Smoke-test against the real Hype DC scrape**

Run: `cd sneaker-scout-backend && uv run python -m utils.show_names | head`
Expected: real sneaker names, one per line; `N unique names` on stderr.

- [ ] **Step 6: Commit**

```bash
git add sneaker-scout-backend/utils/show_names.py sneaker-scout-backend/tests/test_show_names.py
git commit -m "feat: add read-only Hype DC names-viewer CLI"
```

---

## Self-Review

- **Spec coverage:** viewer CLI (Task 1), reuses `extract_names` (Step 3),
  `--names-from`/`--include-brand`/`--limit` (Steps 1 & 3), stdout names +
  stderr count (Step 1 asserts), default input (Step 1 asserts), unit test
  (Task 1). All spec sections covered. No pipeline changes — confirmed.
- **Placeholder scan:** none.
- **Type consistency:** `main(argv)`, `extract_names(path, limit, include_brand)`,
  `DEFAULT_NAMES_FROM` used consistently across tests and implementation.
