"""Builds the static site into dist/.

Everything the pages show that is a value rather than prose comes from
site/config/site.json and site/config/forms.json. The same field definitions
render the forms (here) and validate them (in the browser), so a field is
declared once.

    python tools/build.py
    python tools/build.py --out dist --set pricing.per_bill=12 --set company.contact_email='"x@y.z"'
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import shutil
from pathlib import Path
from typing import Any

from jinja2 import Environment, FileSystemLoader, StrictUndefined, select_autoescape

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
CONFIG_DIR = SITE / "config"
TEMPLATES = SITE / "templates"
STATIC = SITE / "static"
# The values shared with Terraform. Another environment's file is chosen by
# setting PLATFORM_FILE to its path.
PLATFORM_FILE_VARIABLE = "PLATFORM_FILE"
DEFAULT_PLATFORM_FILE = ROOT / "infra" / "envs" / "dev" / "platform.tfvars.json"
PRODUCT_NAME_KEY = "product_name"
INITIAL_VERSIONS_KEY = "initial_versions"
# What a kind of account may leave out of its definition in forms.json.
TYPE_DEFAULTS: dict[str, Any] = {
    "intro": "",
    "legal_form": None,
    "legal_form_field": None,
    "regulator_number_field": None,
}
TYPE_KEYS = ("id", "label", "portal", "regulator", "legal_form", "legal_form_field", "regulator_number_field", "groups")
STATIC_URL = "/static"
INDEX = "index.html"
PAGE_DATA_ID = "page-data"

Field = dict[str, Any]


class BuildError(ValueError):
    """The configuration cannot produce a correct site."""


def platform_file() -> Path:
    return Path(os.environ.get(PLATFORM_FILE_VARIABLE, DEFAULT_PLATFORM_FILE))


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def apply_override(config: dict[str, Any], assignment: str) -> None:
    """Sets one dotted key, e.g. pricing.per_bill=12. The value is JSON; a bare word is a string."""
    key, separator, raw = assignment.partition("=")
    if not separator:
        raise BuildError(f"--set needs key=value, got {assignment!r}")
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        value = raw
    target = config
    *parents, leaf = key.split(".")
    for part in parents:
        if not isinstance(target.get(part), dict):
            raise BuildError(f"--set {key}: {part!r} is not a section of the site settings")
        target = target[part]
    if leaf not in target:
        raise BuildError(f"--set {key}: there is no such setting")
    target[leaf] = value


OPTIONAL_KEYS: dict[str, Any] = {
    "required": False,
    "help": "",
    "inputmode": "",
    "autocomplete": "",
    "max_length": None,
    "min_length": None,
    "default": None,
    "secret": False,
    "matches": None,
}


def lookup(config: dict[str, Any], dotted: str) -> Any:
    """Reads one dotted key of the site settings, e.g. auth.password_min_length."""
    value: Any = config
    for part in dotted.split("."):
        if not isinstance(value, dict) or part not in value:
            raise BuildError(f"there is no site setting {dotted!r}")
        value = value[part]
    return value


def feature_flags(site: dict[str, Any]) -> dict[str, bool]:
    """What is switched on in this build. Sign-in is on once the build is given an app client."""
    return {"auth": bool(site["auth"]["client_id"]), "payment": bool(site["pricing"]["payment_enabled"])}


def prepare(items: list[dict[str, Any]], site: dict[str, Any]) -> list[dict[str, Any]]:
    """Applies the site settings to a list of steps or fields from forms.json.

    Drops anything that requires a feature that is off, picks the title for the
    features that are on, and fills in lengths that are held in the site settings.
    """
    flags = feature_flags(site)
    kept = []
    for original in items:
        item = copy.deepcopy(original)
        requirement = item.pop("requires", None)
        if requirement is not None and not flags[requirement]:
            continue
        for flag, title in item.pop("title_when", {}).items():
            if flags[flag]:
                item["title"] = title
        key = item.pop("min_length_key", None)
        if key is not None:
            item["min_length"] = lookup(site, key)
        key = item.pop("options_key", None)
        if key is not None:
            item["options"] = [
                {"value": value, "label": choice["label"], "hint": choice.get("summary", "")}
                for value, choice in lookup(site, key).items()
            ]
        key = item.pop("options_from", None)
        if key is not None:
            # The choices are read when the page is used, so that a new one needs
            # no rebuild. The ones known at build time are what a preview shows.
            item["options"] = [{"value": value, "label": value} for value in lookup(site, key)]
        key = item.pop("default_key", None)
        if key is not None:
            item["default"] = lookup(site, key)
        if isinstance(item.get("fields"), list):
            item["fields"] = prepare(item["fields"], site)
        kept.append(item)
    return kept


def resolve_format(field: Field, formats: dict[str, dict[str, str]]) -> Field:
    """Fills in the keys a field may leave out, and turns a named format into its pattern."""
    for key, value in OPTIONAL_KEYS.items():
        field.setdefault(key, value)
    name = field.pop("format", None)
    if name is None:
        return field
    if name not in formats:
        raise BuildError(f"field {field['id']}: unknown format {name!r}")
    field["pattern"] = formats[name]["pattern"]
    field["pattern_message"] = formats[name]["message"]
    return field


def expand(fields: list[Field], forms: dict[str, Any]) -> tuple[list[Field], list[Field], list[Field]]:
    """Returns (tree, flat, groups).

    tree is what the template renders: fields, with an address as one group node
    holding its parts. flat is every input, for reading, validating and saving.
    groups lists the group nodes, so the browser can show and hide them.
    """
    tree: list[Field] = []
    flat: list[Field] = []
    groups: list[Field] = []
    for original in fields:
        field = copy.deepcopy(original)
        if field["type"] != "address":
            resolve_format(field, forms["formats"])
            tree.append(field)
            flat.append(field)
            continue
        children: list[Field] = []
        for part in forms["address_parts"]:
            child: Field = {
                "id": f"{field['id']}_{part['suffix']}",
                "label": part["label"],
                "type": "text",
                "required": bool(field.get("required")) and part["required"],
                "autocomplete": part.get("autocomplete", ""),
                "max_length": part.get("max_length"),
            }
            if "format" in part:
                child["format"] = part["format"]
            if "show_if" in field:
                child["show_if"] = field["show_if"]
            resolve_format(child, forms["formats"])
            children.append(child)
        group = {"id": field["id"], "type": "group", "label": field["label"], "fields": children}
        if "show_if" in field:
            group["show_if"] = field["show_if"]
        tree.append(group)
        flat.extend(children)
        groups.append({"id": group["id"], "show_if": group.get("show_if")})
    return tree, flat, groups


def with_condition(fields: list[Field], condition: dict[str, Any] | None) -> list[Field]:
    """A section's own condition applies to every field in it that has none."""
    if condition:
        for field in fields:
            field.setdefault("show_if", condition)
            for child in field.get("fields", []):
                child.setdefault("show_if", condition)
    return fields


def build_forms(forms: dict[str, Any], site: dict[str, Any]) -> dict[str, Any]:
    # Each kind of account has a set of questions of its own. They are kept
    # apart, not merged into one form with parts hidden, so that a question only
    # exists for the kinds of account it is asked of.
    types = []
    for kind in forms["signup"]["types"]:
        tree, flat, groups = expand(prepare(kind["fields"], site), forms)
        types.append({**TYPE_DEFAULTS, **kind, "fields": tree, "flat": flat, "groups": groups})

    signup_steps = []
    for step in prepare(forms["signup"]["steps"], site):
        for field in step["fields"]:
            if field.pop("options_from_types", False):
                field["options"] = [{"value": kind["id"], "label": kind["label"]} for kind in types]
        tree, flat, groups = expand(step["fields"], forms)
        signup_steps.append({"profile": False, "kind": "", **step, "fields": tree, "flat": flat, "groups": groups})

    def simple(fields: list[Field]) -> dict[str, list[Field]]:
        tree, flat, _ = expand(prepare(fields, site), forms)
        return {"fields": tree, "flat": flat}

    company = forms["company"]
    sections = []

    def add_section(source: dict[str, Any], fields: list[Field], kind: str = "fields") -> None:
        tree, flat, groups = expand(prepare(fields, site), forms)
        condition = source.get("show_if")
        with_condition(tree, condition)
        with_condition(flat, condition)
        sections.append(
            {
                "id": source.get("id", kind),
                "kind": kind,
                "title": source["title"],
                "intro": source.get("intro", ""),
                "show_if": condition,
                "fields": tree,
                "flat": flat,
                "groups": groups,
            }
        )

    add_section({**company["funding"], "id": "funding"}, company["funding"]["fields"])
    for section in company["sections"]:
        add_section(section, section["fields"])

    agreement_tree, agreement_flat, _ = expand(forms["agreement"]["fields"], forms)

    return {
        "messages": forms["messages"],
        "signup": {"steps": signup_steps, "types": types},
        "verify": simple(forms["verify"]["fields"]),
        "signin": simple(forms["signin"]["fields"]),
        "reset": {"request": simple(forms["reset"]["request"]), "confirm": simple(forms["reset"]["confirm"])},
        "new_password": simple(forms["new_password"]["fields"]),
        "people": {"invite": simple(forms["people"]["invite"])},
        "agreement": {"fields": agreement_tree, "flat": agreement_flat},
        "company": {
            "sections": sections,
            "funding_ids": [field["id"] for field in company["funding"]["fields"]],
        },
    }


def page_data(page: dict[str, Any], site: dict[str, Any], forms: dict[str, Any]) -> dict[str, Any]:
    """What the page's scripts need, written into the page as JSON."""
    data: dict[str, Any] = {
        "routes": site["routes"],
        "storageKey": site["storage_key"],
        "messages": forms["messages"],
        "agreement": site["agreement"],
        "setupSteps": site["setup_steps"],
        "labels": site["labels"],
        "identity": site["identity"],
        "area": page["area"],
        "route": page["route"],
        "detailsRoute": site["portal"]["details_route"],
        "auth": {
            "enabled": feature_flags(site)["auth"],
            "clientId": site["auth"]["client_id"],
            "endpoint": site["auth"]["endpoint"],
            "sessionKey": site["storage_key"] + site["auth"]["session_suffix"],
            "refreshMarginSeconds": site["auth"]["refresh_margin_seconds"],
        },
        "api": {
            "account": site["api"]["base_path"] + site["api"]["account_path"],
            "agreement": site["api"]["base_path"] + site["api"]["agreement_path"],
            "firm": site["api"]["base_path"] + site["api"]["firm_path"],
            "people": site["api"]["base_path"] + site["api"]["people_path"],
        },
        "roles": site["roles"],
        "permissions": site["permissions"],
        "firstMemberRole": site["first_member_role"],
    }
    scripts = page.get("scripts", [])
    steps = [
        {key: step[key] for key in ("id", "title", "profile", "groups", "kind")}
        | {"fields": step["flat"], "scope": step.get("scope", "")}
        for step in forms["signup"]["steps"]
    ]
    types = [{key: kind[key] for key in TYPE_KEYS} | {"fields": kind["flat"]} for kind in forms["signup"]["types"]]
    if "signup" in scripts:
        data["steps"] = steps
        data["types"] = types
        data["verifyFields"] = forms["verify"]["flat"]
    if "details" in scripts:
        data["steps"] = [step for step in steps if step["profile"]]
        data["types"] = types
    if "signin" in scripts:
        data["signinFields"] = forms["signin"]["flat"]
        data["verifyFields"] = forms["verify"]["flat"]
        data["resetRequestFields"] = forms["reset"]["request"]["flat"]
        data["resetConfirmFields"] = forms["reset"]["confirm"]["flat"]
        data["newPasswordFields"] = forms["new_password"]["flat"]
    if "people" in scripts:
        data["inviteFields"] = forms["people"]["invite"]["flat"]
        data["changes"] = site["changes"]
        data["maxChangesShown"] = site["limits"]["max_changes_shown"]
    if "agreements" in scripts:
        data["fields"] = forms["agreement"]["flat"]
    if "company" in scripts:
        company = forms["company"]
        data["sections"] = [
            {key: section[key] for key in ("id", "title", "show_if", "groups")} | {"fields": section["flat"]}
            for section in company["sections"]
        ]
        data["fundingIds"] = company["funding_ids"]
        data["versions"] = site["versions"]
        data["versionField"] = site["version_field"]
    return data


def output_path(out: Path, route: str) -> Path:
    relative = route.lstrip("/")
    if route.endswith("/"):
        return out / relative / INDEX
    return out / relative


def ucfirst(text: str) -> str:
    return text[:1].upper() + text[1:]


def interpolate(value: Any, environment: Environment, site: dict[str, Any]) -> Any:
    """Renders every string in a config value as a template that can read the site config."""
    if isinstance(value, str):
        return environment.from_string(value).render(site=site)
    if isinstance(value, list):
        return [interpolate(item, environment, site) for item in value]
    if isinstance(value, dict):
        return {key: interpolate(item, environment, site) for key, item in value.items()}
    return value


def load_site(overrides: list[str] | tuple[str, ...] = ()) -> dict[str, Any]:
    """The site config as the pages see it: overrides applied, then every string resolved.

    Any text in site.json may refer to another site value, the product name above
    all, so that a value is written once.
    """
    site = load_json(CONFIG_DIR / "site.json")
    # The product's name is declared once, in the values Terraform also reads.
    platform = load_json(platform_file())
    site["product"]["name"] = platform[PRODUCT_NAME_KEY]
    # The versions a firm can run begin with the ones the platform starts with.
    site["versions"] = platform[INITIAL_VERSIONS_KEY]
    for assignment in overrides:
        apply_override(site, assignment)
    return interpolate(site, Environment(undefined=StrictUndefined), site)


def load_forms(site: dict[str, Any]) -> dict[str, Any]:
    return build_forms(load_json(CONFIG_DIR / "forms.json"), site)


def build(out: Path, overrides: list[str]) -> list[Path]:
    site = load_site(overrides)
    forms = load_forms(site)

    routes: dict[str, str] = site["routes"]
    pages_by_route = {page["route"]: page for page in site["pages"]}
    missing = [name for group in site["nav"].values() for name in group if name not in pages_by_route]
    missing += [step["route"] for step in site["setup_steps"] if step["route"] not in pages_by_route]
    missing += [page["route"] for page in site["pages"] if page["route"] not in routes]
    if missing:
        raise BuildError(f"site.json refers to pages or routes that are not defined: {sorted(set(missing))}")

    environment = Environment(
        loader=FileSystemLoader(TEMPLATES),
        autoescape=select_autoescape(["html"]),
        undefined=StrictUndefined,
        trim_blocks=True,
        lstrip_blocks=True,
    )
    environment.filters["ucfirst"] = ucfirst

    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    shutil.copytree(STATIC, out / STATIC_URL.lstrip("/"))

    written: list[Path] = []
    for page in site["pages"]:
        html = environment.get_template(page["template"]).render(
            site=site,
            routes=routes,
            page=page,
            pages=pages_by_route,
            forms=forms,
            static=STATIC_URL,
            page_data_id=PAGE_DATA_ID,
            page_data=page_data(page, site, forms),
        )
        target = output_path(out, routes[page["route"]])
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(html, encoding="utf-8")
        written.append(target)
    return written


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / "dist")
    parser.add_argument("--set", dest="overrides", action="append", default=[], metavar="KEY=VALUE")
    args = parser.parse_args()
    written = build(args.out, args.overrides)
    print(f"built {len(written)} pages into {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
