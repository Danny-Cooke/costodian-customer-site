"""How the field definitions are prepared for the pages."""

from __future__ import annotations

import copy

import pytest

import build as build_tool


def test_an_address_becomes_one_group_of_parts_that_inherit_its_condition(forms: dict) -> None:
    condition = {"field": "same", "equals": False}
    fields = [{"id": "office", "label": "Office", "type": "address", "required": True, "show_if": condition}]
    tree, flat, groups = build_tool.expand(fields, forms)

    assert [node["type"] for node in tree] == ["group"]
    assert [field["id"] for field in flat] == [f"office_{part['suffix']}" for part in forms["address_parts"]]
    assert all(field["show_if"] == condition for field in flat)
    assert groups == [{"id": "office", "show_if": condition}]
    required = {part["suffix"]: part["required"] for part in forms["address_parts"]}
    assert {field["id"].removeprefix("office_"): field["required"] for field in flat} == required


def test_an_optional_address_has_no_required_parts(forms: dict) -> None:
    _, flat, _ = build_tool.expand([{"id": "a", "label": "A", "type": "address", "required": False}], forms)
    assert not any(field["required"] for field in flat)


def test_a_named_format_becomes_its_pattern_and_message(forms: dict) -> None:
    _, flat, _ = build_tool.expand([{"id": "e", "label": "email", "type": "email", "format": "email"}], forms)
    assert flat[0]["pattern"] == forms["formats"]["email"]["pattern"]
    assert flat[0]["pattern_message"] == forms["formats"]["email"]["message"]
    assert "format" not in flat[0]


def test_an_unknown_format_is_refused(forms: dict) -> None:
    with pytest.raises(build_tool.BuildError):
        build_tool.expand([{"id": "x", "label": "x", "type": "text", "format": "no_such"}], forms)


def test_a_section_condition_reaches_every_field_in_it(forms: dict) -> None:
    condition = {"field": "funding_private", "equals": True}
    changed = copy.deepcopy(forms)
    changed["company"]["sections"].append(
        {"id": "extra", "title": "Extra", "show_if": condition, "fields": [{"id": "x", "label": "x", "type": "text"}]}
    )
    built = build_tool.build_forms(changed, build_tool.load_site())
    extra = next(section for section in built["company"]["sections"] if section["id"] == "extra")
    assert extra["show_if"] == condition
    assert all(field["show_if"] == condition for field in extra["flat"])


def test_choices_read_when_the_page_is_used_start_from_the_ones_known_at_build(forms: dict) -> None:
    site = build_tool.load_site()
    built = build_tool.build_forms(forms, site)
    fields = [field for section in built["company"]["sections"] for field in section["flat"]]
    version = next(field for field in fields if field["id"] == site["version_field"])
    assert [option["value"] for option in version["options"]] == site["versions"]
    assert site["versions"], "the platform starts with at least one version"
