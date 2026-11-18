"""Checks submitted values against the field definitions in forms.json.

The same rules as site/static/js/validate.js, which checks them in the browser
first. The browser's check is for the person; this one is the control. Both are
run against tests/fixtures/validation_cases.json so they cannot drift apart.
"""

from __future__ import annotations

import re
from typing import Any

Field = dict[str, Any]
Values = dict[str, Any]
Messages = dict[str, str]

NOTE = "note"
CHOICE_TYPES = ("radio", "select")
PLACEHOLDER = re.compile(r"\{(\w+)\}")


def is_visible(item: Field, values: Values) -> bool:
    condition = item.get("show_if")
    if not condition:
        return True
    value = values.get(condition["field"])
    if "equals" in condition:
        return bool(value == condition["equals"])
    if "in" in condition:
        return value in condition["in"]
    return True


def is_empty(value: Any) -> bool:
    return value is None or value == "" or value is False


def fill(template: str, field: Field) -> str:
    return PLACEHOLDER.sub(lambda match: str(field[match[1]]) if match[1] in field else match[0], template)


def required_message(field: Field, messages: Messages) -> str:
    if field["type"] == "checkbox":
        return messages["required_tick"]
    if field["type"] in CHOICE_TYPES:
        return messages["required_choice"]
    return messages["required"]


def is_number(value: Any) -> bool:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return False
    return number == number and number not in (float("inf"), float("-inf"))


def validate_field(field: Field, values: Values, messages: Messages, max_text_length: int) -> str | None:
    """The message for one field, or None when it passes."""
    if field["type"] == NOTE or not is_visible(field, values):
        return None
    value = values.get(field["id"])
    if is_empty(value):
        return fill(required_message(field, messages), field) if field.get("required") else None
    if field["type"] == "checkbox":
        return None if value is True else fill(messages["invalid"], field)
    if not isinstance(value, str):
        return fill(messages["invalid"], field)
    if field["type"] == "number":
        if not is_number(value):
            return fill(messages["number"], field)
        number = float(value)
        if isinstance(field.get("min"), int | float) and number < field["min"]:
            return fill(messages["too_small"], field)
        if isinstance(field.get("max"), int | float) and number > field["max"]:
            return fill(messages["too_large"], field)
        return None
    if field["type"] in CHOICE_TYPES and value not in [option["value"] for option in field.get("options", [])]:
        return fill(messages["option"], field)
    if len(value) > (field.get("max_length") or max_text_length):
        return fill(messages["too_long"], field)
    if field.get("min_length") and len(value) < field["min_length"]:
        return fill(messages["too_short"], field)
    if field.get("pattern") and not re.search(field["pattern"], value):
        return field.get("pattern_message") or fill(messages["pattern"], field)
    if field.get("matches") and value != values.get(field["matches"]):
        return fill(messages["mismatch"], field)
    return None


def validate_fields(fields: list[Field], values: Values, messages: Messages, max_text_length: int) -> dict[str, str]:
    """{field id: message} for the fields that are wrong; empty when all pass."""
    errors = {}
    for field in fields:
        message = validate_field(field, values, messages, max_text_length)
        if message:
            errors[field["id"]] = message
    return errors


def visible_values(fields: list[Field], values: Values) -> Values:
    """The values worth keeping: known fields that are on show, never notes or secrets."""
    return {
        field["id"]: values[field["id"]]
        for field in fields
        if field["type"] != NOTE and not field.get("secret") and is_visible(field, values) and field["id"] in values
    }
