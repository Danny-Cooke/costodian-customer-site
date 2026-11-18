"""Checks a deployed copy of the site: every page answers, a missing page is a
proper 404, and the security headers are present.

    python tools/smoke.py https://<the site address>
"""

from __future__ import annotations

import argparse
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))

from build import load_site  # noqa: E402

MISSING_PATH = "/this-page-does-not-exist/"
REQUIRED_HEADERS = ("content-security-policy", "strict-transport-security", "x-content-type-options", "x-frame-options")
TIMEOUT_SECONDS = 20
OK = 200
NOT_FOUND = 404


def fetch(url: str) -> tuple[int, dict[str, str], str]:
    request = urllib.request.Request(url, headers={"User-Agent": "site-smoke-test"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:  # noqa: S310 - https address given by the operator
            return response.status, {k.lower(): v for k, v in response.headers.items()}, response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        return error.code, {k.lower(): v for k, v in error.headers.items()}, error.read().decode("utf-8", "replace")


def expected_pages(config: dict) -> list[tuple[str, str]]:
    """(path, text that must be on the page) for every page that has a folder address."""
    routes = config["routes"]
    return [(routes[page["route"]], page["title"]) for page in config["pages"] if routes[page["route"]].endswith("/")]


def check(base_url: str, config: dict, fetcher=fetch) -> list[str]:
    base = base_url.rstrip("/")
    problems: list[str] = []
    for path, title in expected_pages(config):
        status, headers, body = fetcher(base + path)
        if status != OK:
            problems.append(f"{path}: expected {OK}, got {status}")
            continue
        if title not in body:
            problems.append(f"{path}: the page does not contain its title {title!r}")
        problems += [f"{path}: header {name} is missing" for name in REQUIRED_HEADERS if name not in headers]

    # The same page without its trailing slash must also resolve.
    bare = next(path for path, _ in expected_pages(config) if path != "/").rstrip("/")
    status, _, _ = fetcher(base + bare)
    if status != OK:
        problems.append(f"{bare}: expected {OK} without the trailing slash, got {status}")

    status, _, body = fetcher(base + MISSING_PATH)
    not_found_title = next(page["title"] for page in config["pages"] if page["route"] == "not_found")
    if status != NOT_FOUND:
        problems.append(f"{MISSING_PATH}: expected {NOT_FOUND}, got {status}")
    elif not_found_title not in body:
        problems.append(f"{MISSING_PATH}: the not-found page was not served")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base_url")
    parser.add_argument("--set", dest="overrides", action="append", default=[], metavar="KEY=VALUE")
    args = parser.parse_args()
    if not args.base_url.startswith("https://"):
        print("the address must start with https://", file=sys.stderr)
        return 2
    problems = check(args.base_url, load_site(args.overrides))
    for problem in problems:
        print(f"FAIL {problem}", file=sys.stderr)
    if not problems:
        print(f"ok: {args.base_url} answers on every page")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
