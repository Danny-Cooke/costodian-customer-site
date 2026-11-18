"""The built site: every page is there, every link resolves, and the pages are
safe to serve under a content security policy that allows no inline code."""

from __future__ import annotations

import json
from html.parser import HTMLParser
from pathlib import Path

import pytest

import build as build_tool

JSON_SCRIPT = "application/json"


class Page(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: list[str] = []
        self.ids: list[str] = []
        self.label_targets: list[str] = []
        self.headings: list[str] = []
        self.inline_scripts = 0
        self.inline_handlers: list[str] = []
        self.style_attributes = 0
        self.json_blocks: list[str] = []
        self.inputs: set[str] = set()
        self.title = ""
        self._capture: str | None = None
        self._template_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        if tag == "template":
            self._template_depth += 1
        for name in ("href", "src"):
            if values.get(name):
                self.links.append(values[name])
        if "id" in values:
            self.ids.append(values["id"])
        if tag == "label" and values.get("for"):
            self.label_targets.append(values["for"])
        if tag == "h1":
            self.headings.append(tag)
        if "style" in values:
            self.style_attributes += 1
        self.inline_handlers += [name for name in values if name.startswith("on")]
        if "data-input" in values and self._template_depth == 0:
            self.inputs.add(values["data-input"])
        if tag == "script":
            if values.get("type") == JSON_SCRIPT:
                self._capture = "json"
            elif not values.get("src"):
                self.inline_scripts += 1
        if tag == "title":
            self._capture = "title"

    def handle_endtag(self, tag: str) -> None:
        if tag == "template":
            self._template_depth -= 1
        if tag in ("script", "title"):
            self._capture = None

    def handle_data(self, data: str) -> None:
        if self._capture == "json":
            self.json_blocks.append(data)
        elif self._capture == "title":
            self.title += data


def parse(path: Path) -> Page:
    page = Page()
    page.feed(path.read_text(encoding="utf-8"))
    return page


def built_file(dist: Path, route: str) -> Path:
    return build_tool.output_path(dist, route)


@pytest.fixture(scope="module")
def pages(dist: Path, site: dict) -> dict[str, Page]:
    return {page["route"]: parse(built_file(dist, site["routes"][page["route"]])) for page in site["pages"]}


def test_every_configured_page_is_built(dist: Path, site: dict) -> None:
    for page in site["pages"]:
        assert built_file(dist, site["routes"][page["route"]]).is_file(), page["route"]


def test_every_internal_link_resolves(dist: Path, pages: dict[str, Page]) -> None:
    for route, page in pages.items():
        for link in page.links:
            if not link.startswith("/"):
                assert link.startswith(("#", "mailto:")), f"{route}: unexpected external link {link}"
                continue
            target = dist / link.lstrip("/")
            if link.endswith("/"):
                target = target / build_tool.INDEX
            assert target.is_file(), f"{route}: {link} does not exist"


def test_no_inline_code_so_a_strict_content_security_policy_holds(pages: dict[str, Page]) -> None:
    for route, page in pages.items():
        assert page.inline_scripts == 0, route
        assert page.inline_handlers == [], route
        assert page.style_attributes == 0, route


def test_each_page_has_one_heading_and_a_title_with_the_product_name(pages: dict[str, Page], site: dict) -> None:
    for route, page in pages.items():
        assert len(page.headings) == 1, route
        assert site["product"]["name"] in page.title, route


def test_ids_are_unique_and_every_label_points_at_a_field(pages: dict[str, Page]) -> None:
    for route, page in pages.items():
        assert len(page.ids) == len(set(page.ids)), f"{route}: duplicate ids"
        assert set(page.label_targets) <= set(page.ids), f"{route}: a label points at nothing"


def test_page_data_is_valid_json_with_the_routes(pages: dict[str, Page], site: dict) -> None:
    for route, page in pages.items():
        assert len(page.json_blocks) == 1, route
        assert json.loads(page.json_blocks[0])["routes"] == site["routes"]


def test_sign_up_renders_every_field_it_validates(pages: dict[str, Page]) -> None:
    data = json.loads(pages["signup"].json_blocks[0])
    expected = {field["id"] for step in data["steps"] for field in step["fields"] if field["type"] != "note"}
    assert expected and expected <= pages["signup"].inputs


def test_company_information_renders_every_field_it_validates(pages: dict[str, Page]) -> None:
    data = json.loads(pages["company"].json_blocks[0])
    expected = {field["id"] for section in data["sections"] for field in section["fields"] if field["type"] != "note"}
    assert expected and expected <= pages["company"].inputs
    assert "feeEarners" not in data, "fee earners are managed in the product, not here"


def test_names_are_not_typed_into_templates_or_scripts(site: dict) -> None:
    """The product and company names come from site.json, never from a template."""
    names = [site["product"]["name"], site["company"]["name"]]
    sources = [*build_tool.TEMPLATES.rglob("*.html"), *build_tool.STATIC.rglob("*.js")]
    assert sources
    for source in sources:
        text = source.read_text(encoding="utf-8")
        for name in names:
            assert name not in text, f"{source.name} contains the literal {name!r}"


def test_the_price_is_shown_only_when_one_is_set(
    tmp_path: Path, pages: dict[str, Page], dist: Path, site: dict
) -> None:
    pricing = site["routes"]["pricing"]
    assert "Price to be confirmed" in built_file(dist, pricing).read_text(encoding="utf-8")

    build_tool.build(tmp_path / "priced", ["pricing.per_bill=12", "pricing.refund_days=14"])
    html = built_file(tmp_path / "priced", pricing).read_text(encoding="utf-8")
    assert f"{site['pricing']['currency_symbol']}12" in html
    assert "within 14 days" in html
    assert "Price to be confirmed" not in html


def test_the_contact_address_appears_only_when_set(tmp_path: Path, dist: Path, site: dict) -> None:
    home = site["routes"]["home"]
    assert "mailto:" not in built_file(dist, home).read_text(encoding="utf-8")
    build_tool.build(tmp_path / "contact", ["company.contact_email=hello@example.test"])
    assert "mailto:hello@example.test" in built_file(tmp_path / "contact", home).read_text(encoding="utf-8")


def test_the_preview_banner_can_be_switched_off(tmp_path: Path, dist: Path, site: dict) -> None:
    home = site["routes"]["home"]
    assert site["preview"]["message"] in built_file(dist, home).read_text(encoding="utf-8")
    build_tool.build(tmp_path / "live", ["preview.enabled=false"])
    assert site["preview"]["message"] not in built_file(tmp_path / "live", home).read_text(encoding="utf-8")


@pytest.mark.parametrize("assignment", ["pricing.no_such=1", "nothing.per_bill=1", "pricing.per_bill"])
def test_an_override_for_an_unknown_setting_is_refused(tmp_path: Path, assignment: str) -> None:
    with pytest.raises(build_tool.BuildError):
        build_tool.build(tmp_path / "bad", [assignment])


SUPPLIER_NAMES = ("aws", "amazon", "bedrock", "claude", "anthropic", "cloudfront")


def test_no_page_names_a_hosting_or_ai_supplier(dist: Path, site: dict) -> None:
    """The site says where data is held, never whose infrastructure or models are used."""
    for page in site["pages"]:
        text = built_file(dist, site["routes"][page["route"]]).read_text(encoding="utf-8").lower()
        for name in SUPPLIER_NAMES:
            assert name not in text, f"{page['route']} mentions {name}"


FEATURE_TABLE_ROUTES = ("features", "security", "sra")
MINIMUM_TABLE_ROWS = 9


def test_every_row_of_a_feature_table_ends_with_a_tick(dist: Path, site: dict) -> None:
    for route in FEATURE_TABLE_ROUTES:
        html = built_file(dist, site["routes"][route]).read_text(encoding="utf-8")
        body_rows = html.count('<th scope="row">')
        assert body_rows >= MINIMUM_TABLE_ROWS, route
        assert html.count('class="tick-mark"') == body_rows, route


def test_the_sra_page_gives_a_rule_reference_for_every_point(dist: Path, site: dict) -> None:
    html = built_file(dist, site["routes"]["sra"]).read_text(encoding="utf-8")
    assert html.count('class="ref"') == html.count('<th scope="row">')


def test_the_product_name_is_written_once(tmp_path: Path, site: dict) -> None:
    """Renaming the product is one value: the old name is left nowhere in the built site."""
    new_name = "Renamed"
    build_tool.build(tmp_path, [f"product.name={new_name}"])
    for path in tmp_path.rglob("*"):
        if path.is_file():
            text = path.read_text(encoding="utf-8")
            assert site["product"]["name"] not in text, f"{path.relative_to(tmp_path)} still names the product"
    assert new_name in built_file(tmp_path, site["routes"]["home"]).read_text(encoding="utf-8")


SOURCE_OF_THE_NAME = "infra/envs/dev/platform.tfvars.json"
# Notes and history may name the product; the lock file is generated.
NOT_SEARCHED = (".claude/", "package-lock.json")


def test_the_product_name_is_declared_in_one_file_only(site: dict) -> None:
    """A rename is one value: nothing else in the repository spells the name out."""
    import subprocess

    listed = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        cwd=build_tool.ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    name = site["product"]["name"].lower()
    found = []
    for relative in listed:
        path = build_tool.ROOT / relative
        if relative.startswith(NOT_SEARCHED) or relative == SOURCE_OF_THE_NAME or not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        if name in text.lower():
            found.append(relative)
    assert found == [], f"the product name is spelled out in {found}"
