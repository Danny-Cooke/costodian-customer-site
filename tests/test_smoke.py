"""The smoke test itself: it must pass on a healthy site and name what is wrong on a broken one."""

from __future__ import annotations

from pathlib import Path

import build as build_tool
import smoke

HEADERS = {name: "x" for name in smoke.REQUIRED_HEADERS}


def serve(dist: Path, *, headers: dict[str, str] = HEADERS, broken: str | None = None, missing_status: int = 404):
    """A stand-in for the deployed site, answering from the built files the way CloudFront is set up to."""

    def fetcher(url: str) -> tuple[int, dict[str, str], str]:
        path = "/" + url.split("/", 3)[3] if url.count("/") > 2 else "/"
        if path == broken:
            return 500, headers, ""
        target = dist / path.lstrip("/")
        if path.endswith("/") or "." not in path.rsplit("/", 1)[-1]:
            target = target / build_tool.INDEX
        if target.is_file():
            return 200, headers, target.read_text(encoding="utf-8")
        return missing_status, headers, (dist / "404.html").read_text(encoding="utf-8")

    return fetcher


def test_a_healthy_site_passes(dist: Path, site: dict) -> None:
    assert smoke.check("https://example.test", site, serve(dist)) == []


def test_a_page_that_errors_is_named(dist: Path, site: dict) -> None:
    problems = smoke.check("https://example.test/", site, serve(dist, broken=site["routes"]["pricing"]))
    assert problems == [f"{site['routes']['pricing']}: expected 200, got 500"]


def test_a_missing_security_header_is_named(dist: Path, site: dict) -> None:
    headers = {name: "x" for name in smoke.REQUIRED_HEADERS[1:]}
    problems = smoke.check("https://example.test", site, serve(dist, headers=headers))
    assert problems and all(smoke.REQUIRED_HEADERS[0] in problem for problem in problems)


def test_a_missing_page_served_as_200_is_caught(dist: Path, site: dict) -> None:
    problems = smoke.check("https://example.test", site, serve(dist, missing_status=200))
    assert problems == [f"{smoke.MISSING_PATH}: expected 404, got 200"]


def test_every_folder_page_is_checked(site: dict) -> None:
    paths = [path for path, _ in smoke.expected_pages(site)]
    assert site["routes"]["home"] in paths and site["routes"]["company"] in paths
    assert site["routes"]["not_found"] not in paths
