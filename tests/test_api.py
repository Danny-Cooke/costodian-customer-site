"""The account API: what it accepts, what it refuses, and what it stores."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

import build_api as api_tool
import pytest

import build as build_tool

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "api"))

SUBJECT = "11111111-2222-3333-4444-555555555555"
YOU = {
    "person_name": "Sam Example",
    "person_role": "partner",
    "person_email": "sam@example.test",
    "person_phone": "020 7946 0000",
}
FIRM = {
    "firm_name": "Example Law LLP",
    "firm_sra_number": "123456",
    "firm_type": "partnership",
    "firm_office_line1": "1 High Street",
    "firm_office_town": "London",
    "firm_office_postcode": "SE1 1AA",
    "firm_correspondence_same": True,
}
EARNER = {"name": "Sam Example", "initials": "SE", "grade": "A", "own_terms": True}


class ConditionalCheckFailedException(Exception):
    pass


class FakeTable:
    """Keeps items by their two keys, and refuses a conditional write to an existing item."""

    def __init__(self) -> None:
        self.items: dict[tuple[str, str], dict[str, Any]] = {}

    def put_item(self, Item: dict[str, Any], **condition: Any) -> None:  # noqa: N803 (boto3's argument name)
        key = (Item["pk"], Item["sk"])
        if condition and key in self.items:
            raise ConditionalCheckFailedException
        self.items[key] = Item

    def query(self, **_: Any) -> dict[str, Any]:
        return {"Items": list(self.items.values())}


@pytest.fixture
def api(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Any:
    config = api_tool.build_api(tmp_path / "api", [])
    monkeypatch.setenv("API_CONFIG", str(config))
    monkeypatch.setenv("TABLE_NAME", "unused")
    monkeypatch.setenv("TABLE_HASH_KEY", "pk")
    monkeypatch.setenv("TABLE_RANGE_KEY", "sk")
    sys.modules.pop("handler", None)
    import handler

    handler.CONFIG_PATH = config
    handler.config.cache_clear()
    fake = FakeTable()
    monkeypatch.setattr(handler, "table", lambda: fake)
    handler.fake = fake
    return handler


def event(body: Any = None, section: str | None = None, subject: str | None = SUBJECT) -> dict[str, Any]:
    claims = {"sub": subject, "email": "sam@example.test"} if subject else {}
    made: dict[str, Any] = {"requestContext": {"authorizer": {"jwt": {"claims": claims}}}}
    if body is not None:
        made["body"] = body if isinstance(body, str) else json.dumps(body)
    if section is not None:
        made["pathParameters"] = {"section": section}
    return made


def answer(response: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    assert response["headers"]["cache-control"] == "no-store"
    return response["statusCode"], json.loads(response["body"])


def company_values(api: Any) -> dict[str, Any]:
    """Legal aid only, with every question that shows for it answered."""
    values: dict[str, Any] = {"funding_legal_aid": True, "funding_private": False}
    for section in api.config()["company"]["sections"]:
        for field in section["fields"]:
            if field["type"] == "note" or field["id"] in values or not field.get("required"):
                continue
            if field["type"] in ("radio", "select"):
                values[field["id"]] = field["options"][0]["value"]
            elif field["type"] == "number":
                values[field["id"]] = str(field.get("min", 1))
            elif field["type"] == "checkbox":
                values[field["id"]] = True
            else:
                values[field["id"]] = "1A234B" if "account" in field["id"] else "Sam Example"
    return values


# -------------------------------------------------------------------- reading


def test_a_request_without_a_person_is_refused(api: Any) -> None:
    assert answer(api.read(event(subject=None))) == (401, {"error": "not_signed_in"})
    assert answer(api.write(event({"values": {}}, "signup", subject=None)))[0] == 401
    assert answer(api.accept(event({"values": {}}, subject=None)))[0] == 401


def test_a_new_account_reads_as_empty(api: Any) -> None:
    assert answer(api.read(event())) == (200, {"signup": None, "company": None, "agreement": None})


# --------------------------------------------------------------------- saving


def test_sign_up_details_are_saved_under_the_person_and_read_back(api: Any) -> None:
    status, body = answer(api.write(event({"values": {**YOU, **FIRM}}, "signup")))
    assert status == 200
    assert body["signup"]["values"]["firm_name"] == FIRM["firm_name"]
    assert body["signup"]["completedAt"].endswith("Z")
    assert list(api.fake.items) == [("ACCOUNT#" + SUBJECT, "signup")]
    assert answer(api.read(event()))[1]["signup"] == body["signup"]


def test_only_known_fields_on_show_are_kept(api: Any) -> None:
    sent = {**YOU, **FIRM, "is_admin": True, "person_password": "Secret-password-1", "firm_company_number": "12345678"}
    stored = answer(api.write(event({"values": sent}, "signup")))[1]["signup"]["values"]
    assert "is_admin" not in stored
    assert "person_password" not in stored
    assert "firm_company_number" not in stored, "a partnership has no company number, so it is not on show"


def test_details_that_fail_the_form_rules_are_refused_and_nothing_is_stored(api: Any) -> None:
    status, body = answer(
        api.write(event({"values": {**YOU, **FIRM, "person_email": "sam-at-example", "firm_name": ""}}, "signup"))
    )
    assert status == 422
    assert set(body["errors"]) == {"person_email", "firm_name"}
    assert api.fake.items == {}


@pytest.mark.parametrize("value", [{"nested": 1}, ["a"], 12, "x" * 5000])
def test_a_value_of_the_wrong_shape_or_size_is_refused(api: Any, value: Any) -> None:
    status, body = answer(api.write(event({"values": {**YOU, **FIRM, "firm_name": value}}, "signup")))
    assert status == 422
    assert "firm_name" in body["errors"]


def test_a_choice_that_is_not_one_of_the_options_is_refused(api: Any) -> None:
    status, body = answer(api.write(event({"values": {**YOU, **FIRM, "person_role": "emperor"}}, "signup")))
    assert status == 422
    assert "person_role" in body["errors"]


@pytest.mark.parametrize("body", ["not json", "[]", '{"values": []}'])
def test_a_body_that_is_not_the_expected_json_is_refused(api: Any, body: str) -> None:
    assert answer(api.write(event(body, "signup")))[0] == 400


def test_a_body_over_the_size_limit_is_refused(api: Any) -> None:
    oversized = json.dumps({"values": {"firm_name": "x" * (api.config()["limits"]["max_body_bytes"] + 1)}})
    assert answer(api.write(event(oversized, "signup"))) == (400, {"error": "too_large"})


def test_an_unknown_section_is_refused(api: Any) -> None:
    assert answer(api.write(event({"values": {}}, "agreement"))) == (400, {"error": "unknown_section"})


def test_one_person_cannot_read_what_another_saved(api: Any) -> None:
    api.write(event({"values": {**YOU, **FIRM}}, "signup"))
    other = "99999999-2222-3333-4444-555555555555"
    api.write(event({"values": {**YOU, **FIRM, "firm_name": "Other Firm"}}, "signup", subject=other))
    assert {key[0] for key in api.fake.items} == {"ACCOUNT#" + SUBJECT, "ACCOUNT#" + other}


# -------------------------------------------------------------------- company


def test_company_information_is_saved_with_the_register_version(api: Any) -> None:
    status, body = answer(
        api.write(
            event({"values": company_values(api), "feeEarners": [EARNER], "registerVersion": "made-up"}, "company")
        )
    )
    assert status == 200, body
    assert body["company"]["registerVersion"] == build_tool.load_json(build_tool.RULES)["register_version"]
    assert body["company"]["feeEarners"][0]["name"] == EARNER["name"]
    assert not any(key.startswith("private_") for key in body["company"]["values"]), "private answers are not on show"


def test_company_information_needs_a_funding_type_and_a_fee_earner(api: Any) -> None:
    values = {**company_values(api), "funding_legal_aid": False}
    status, body = answer(api.write(event({"values": values, "feeEarners": []}, "company")))
    assert status == 422
    messages = api.config()["messages"]
    assert body["problems"] == [messages["funding_required"], messages["fee_earner_required"]]


def test_a_fee_earner_that_fails_the_rules_is_refused(api: Any) -> None:
    status, body = answer(
        api.write(event({"values": company_values(api), "feeEarners": [{**EARNER, "name": ""}]}, "company"))
    )
    assert status == 422
    assert "name" in body["rowErrors"][0]


def test_too_many_fee_earners_are_refused(api: Any) -> None:
    rows = [EARNER] * (api.config()["company"]["maxFeeEarners"] + 1)
    status, body = answer(api.write(event({"values": company_values(api), "feeEarners": rows}, "company")))
    assert status == 422
    assert api.config()["messages"]["too_many_rows"] in body["problems"]


# ------------------------------------------------------------------ agreement


def test_accepting_the_agreement_records_who_and_which_version(api: Any) -> None:
    status, body = answer(api.accept(event({"values": {"accept_name": "Sam Example", "accept_tick": True}})))
    agreement = build_tool.load_site()["agreement"]
    assert status == 200
    assert body["agreement"]["acceptedBy"] == "Sam Example"
    assert (body["agreement"]["id"], body["agreement"]["version"]) == (agreement["id"], agreement["version"])
    assert answer(api.read(event()))[1]["agreement"] == body["agreement"]


def test_an_acceptance_cannot_be_written_twice(api: Any) -> None:
    first = answer(api.accept(event({"values": {"accept_name": "Sam Example", "accept_tick": True}})))[1]["agreement"]
    status, body = answer(api.accept(event({"values": {"accept_name": "Someone Else", "accept_tick": True}})))
    assert (status, body) == (409, {"error": "already_accepted"})
    assert answer(api.read(event()))[1]["agreement"] == first


def test_the_agreement_is_not_accepted_without_the_tick(api: Any) -> None:
    status, body = answer(api.accept(event({"values": {"accept_name": "Sam Example", "accept_tick": False}})))
    assert status == 422
    assert "accept_tick" in body["errors"]


# ---------------------------------------------------------------- shared rules


def shared_cases() -> list[dict[str, Any]]:
    return json.loads((ROOT / "tests" / "fixtures" / "validation_cases.json").read_text(encoding="utf-8"))


@pytest.mark.parametrize("case", shared_cases(), ids=lambda case: case["name"])
def test_the_api_applies_the_same_rules_as_the_browser(api: Any, case: dict[str, Any]) -> None:
    import validation

    messages = json.loads((ROOT / "site" / "config" / "forms.json").read_text(encoding="utf-8"))["messages"]
    assert validation.validate_field(case["field"], case["values"], messages, 2000) == case["message"]
