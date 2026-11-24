"""Builds the account API's package: the code in api/ plus the settings it needs.

    python tools/build_api.py --out build/api

The settings are the same field definitions the pages are built from, so the
browser and the API check a form against one source. Terraform zips the output.
"""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path
from typing import Any

from build import ROOT, load_forms, load_site, page_data

API = ROOT / "api"
CONFIG_NAME = "config.json"
# How items are keyed inside one customer's table.
KEYS = {
    "firm_partition": "FIRM",
    "person_prefix": "PERSON#",
    "person": "person",
    "firm": "firm",
    "company": "company",
    "claim": "claim",
    "member_prefix": "member#",
    "change_prefix": "change#",
    "agreement_prefix": "agreement#",
}
# How they were keyed in the one table every firm shared, for moving firms out of it.
LEGACY_KEYS = {
    "account_prefix": "ACCOUNT#",
    "firm_prefix": "FIRM#",
    "membership": "membership",
    "person": "person",
}
SCRIPTS = ("signup", "company", "agreements", "people")
CONFIG_KEYS = {"agreements": "agreement"}
PAGE_KEYS = ("steps", "sections", "fundingIds", "versionField", "fields", "agreement", "inviteFields")


def api_config(site: dict[str, Any]) -> dict[str, Any]:
    forms = load_forms(site)
    by_script = {script: page for page in site["pages"] for script in page.get("scripts", [])}
    config: dict[str, Any] = {
        "messages": forms["messages"],
        "limits": site["limits"],
        "keys": KEYS,
    }
    for script in SCRIPTS:
        data = page_data(by_script[script], site, forms)
        config[CONFIG_KEYS.get(script, script)] = {key: data[key] for key in PAGE_KEYS if key in data}
    config["roles"] = sorted(site["roles"])
    config["permissions"] = site["permissions"]
    config["firstMemberRole"] = site["first_member_role"]
    config["legacyKeys"] = LEGACY_KEYS
    config["customerStatuses"] = site["customer_statuses"]
    config["customerLabel"] = site["customer_label"]
    config["retention"] = site["retention"]
    return config


def build_api(out: Path, overrides: list[str]) -> Path:
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(API, out, ignore=shutil.ignore_patterns("__pycache__"))
    target = out / CONFIG_NAME
    target.write_text(json.dumps(api_config(load_site(overrides)), indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return target


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / "build" / "api")
    parser.add_argument("--set", dest="overrides", action="append", default=[], metavar="KEY=VALUE")
    args = parser.parse_args()
    print(f"built the API package into {build_api(args.out, args.overrides).parent}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
