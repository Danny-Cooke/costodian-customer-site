"""Copies the rules a firm takes a position on out of the product's rule register.

The register lives in the product repository. This site only needs the rules that
are not fixed (the ones a firm answers a question about), so that subset is copied
into site/data/rules.generated.json together with the register version it came from.

    python tools/sync_rules.py --register <path to register.yaml>
    python tools/sync_rules.py --register <path to register.yaml> --check
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "site" / "data" / "rules.generated.json"
FIXED = "fixed"
KEPT_KEYS = ("id", "title", "source", "text", "kind", "note", "options", "default")


def extract(register_path: Path) -> dict[str, object]:
    register = yaml.safe_load(register_path.read_text(encoding="utf-8"))
    rules = [
        {key: rule[key] for key in KEPT_KEYS if key in rule} for rule in register["rules"] if rule["kind"] != FIXED
    ]
    return {"register_version": register["version"], "rules": rules}


def render(data: dict[str, object]) -> str:
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--register", type=Path, required=True, help="path to the product's register.yaml")
    parser.add_argument("--check", action="store_true", help="fail if the committed copy is out of date")
    args = parser.parse_args()

    text = render(extract(args.register))
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != text:
            print(f"{OUTPUT.relative_to(ROOT)} is out of date; run without --check", file=sys.stderr)
            return 1
        return 0
    OUTPUT.write_text(text, encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
