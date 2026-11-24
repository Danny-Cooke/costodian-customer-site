from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import build as build_tool  # noqa: E402


@pytest.fixture(scope="session")
def dist(tmp_path_factory: pytest.TempPathFactory) -> Path:
    out = tmp_path_factory.mktemp("dist")
    build_tool.build(out, [])
    return out


@pytest.fixture(scope="session")
def site() -> dict:
    return build_tool.load_site()


@pytest.fixture(scope="session")
def forms() -> dict:
    return build_tool.load_json(build_tool.CONFIG_DIR / "forms.json")
