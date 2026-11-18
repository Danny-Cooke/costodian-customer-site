"""How the field definitions are prepared for the pages."""

from __future__ import annotations

import copy

import pytest

import build as build_tool
import sync_rules


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


def test_every_rule_a_firm_decides_has_a_question(forms: dict, rules: dict) -> None:
    fields = build_tool.position_fields(forms["company"]["legal_aid"], rules)
    assert [field["rule"]["id"] for field in fields] == [rule["id"] for rule in rules["rules"]]
    for field, rule in zip(fields, rules["rules"], strict=True):
        if field["type"] == "radio":
            assert [option["value"] for option in field["options"]] == rule["options"]
            assert field["default"] == rule["default"]


def test_a_rule_with_no_wording_stops_the_build(forms: dict, rules: dict) -> None:
    legal_aid = copy.deepcopy(forms["company"]["legal_aid"])
    legal_aid["positions"].pop(rules["rules"][0]["id"])
    with pytest.raises(build_tool.BuildError):
        build_tool.position_fields(legal_aid, rules)


def test_wording_for_a_rule_that_is_not_in_the_register_stops_the_build(forms: dict, rules: dict) -> None:
    legal_aid = copy.deepcopy(forms["company"]["legal_aid"])
    legal_aid["positions"]["NO-SUCH-RULE"] = {"question": "?", "per_case": True}
    with pytest.raises(build_tool.BuildError):
        build_tool.position_fields(legal_aid, rules)


def test_option_wording_that_differs_from_the_register_stops_the_build(forms: dict, rules: dict) -> None:
    changed = copy.deepcopy(rules)
    with_options = next(rule for rule in changed["rules"] if rule.get("options"))
    with_options["options"].append("a_new_option")
    with pytest.raises(build_tool.BuildError):
        build_tool.position_fields(forms["company"]["legal_aid"], changed)


def test_a_section_condition_reaches_every_field_in_it(forms: dict, rules: dict) -> None:
    built = build_tool.build_forms(forms, rules, build_tool.load_site())
    legal_aid = next(section for section in built["company"]["sections"] if section["id"] == "legal_aid")
    assert legal_aid["show_if"] == forms["company"]["legal_aid"]["show_if"]
    assert all(field["show_if"] == legal_aid["show_if"] for field in legal_aid["flat"])


def test_the_rule_copy_keeps_only_rules_that_are_not_fixed(tmp_path) -> None:
    register = tmp_path / "register.yaml"
    register.write_text(
        "version: '1'\nrules:\n"
        "  - {id: A, title: a, source: s, text: t, kind: fixed}\n"
        "  - {id: B, title: b, source: s, text: t, kind: judgment, options: [x, y], default: x}\n",
        encoding="utf-8",
    )
    data = sync_rules.extract(register)
    assert data["register_version"] == "1"
    assert [rule["id"] for rule in data["rules"]] == ["B"]


def test_the_committed_rule_copy_holds_no_fixed_rule(rules: dict) -> None:
    assert rules["register_version"]
    assert rules["rules"] and all(rule["kind"] != sync_rules.FIXED for rule in rules["rules"])
