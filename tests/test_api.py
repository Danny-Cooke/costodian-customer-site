"""The account API: firms, the people who manage them, and what they may do and store."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

import pytest

import build as build_tool
import build_api as api_tool

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "api"))

OWNER = "11111111-2222-3333-4444-555555555555"
OWNER_EMAIL = "sam@example.test"
STRANGER = "99999999-2222-3333-4444-555555555555"
YOU = {
    "person_name": "Sam Example",
    "person_role": "partner",
    "person_email": OWNER_EMAIL,
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
ACCEPT = {"accept_name": "Sam Example", "accept_tick": True}


class ConditionalCheckFailedException(Exception):
    pass


class UsernameExistsException(Exception):
    pass


class FakeTable:
    """Items by their two keys. Refuses a conditional write to an item that exists."""

    def __init__(self) -> None:
        self.items: dict[tuple[str, str], dict[str, Any]] = {}

    def put_item(self, Item: dict[str, Any], **condition: Any) -> None:  # noqa: N803 (boto3's argument names)
        key = (Item["pk"], Item["sk"])
        if condition and key in self.items:
            raise ConditionalCheckFailedException
        self.items[key] = json.loads(json.dumps(Item))

    def get_item(self, Key: dict[str, str]) -> dict[str, Any]:  # noqa: N803
        found = self.items.get((Key["pk"], Key["sk"]))
        return {"Item": found} if found else {}

    def delete_item(self, Key: dict[str, str]) -> None:  # noqa: N803
        self.items.pop((Key["pk"], Key["sk"]), None)

    def query(self, ExpressionAttributeValues: dict[str, str], **_: Any) -> dict[str, Any]:  # noqa: N803
        partition = ExpressionAttributeValues[":partition"]
        return {"Items": [item for (pk, _sk), item in self.items.items() if pk == partition]}

    def sorts(self, partition_prefix: str) -> list[str]:
        return sorted(sk for (pk, sk) in self.items if pk.startswith(partition_prefix))


class FakeDirectory:
    """The sign-in service: creates and deletes people, and remembers what it was asked."""

    def __init__(self) -> None:
        self.users: dict[str, str] = {}
        self.calls: list[tuple[str, str]] = []

    def admin_create_user(self, UserPoolId: str, Username: str, **_: Any) -> dict[str, Any]:  # noqa: N803
        if Username in self.users:
            raise UsernameExistsException
        subject = f"sub-{len(self.users) + 1}"
        self.users[Username] = subject
        self.calls.append(("create", Username))
        return {"User": {"Attributes": [{"Name": "sub", "Value": subject}, {"Name": "email", "Value": Username}]}}

    def admin_user_global_sign_out(self, UserPoolId: str, Username: str) -> None:  # noqa: N803
        self.calls.append(("sign_out", Username))

    def admin_delete_user(self, UserPoolId: str, Username: str) -> None:  # noqa: N803
        self.calls.append(("delete", Username))


@pytest.fixture
def api(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Any:
    config = api_tool.build_api(tmp_path / "api", [])
    for name, value in {
        "TABLE_NAME": "unused",
        "TABLE_HASH_KEY": "pk",
        "TABLE_RANGE_KEY": "sk",
        "USER_POOL_ID": "pool",
    }.items():
        monkeypatch.setenv(name, value)
    sys.modules.pop("handler", None)
    import handler

    handler.CONFIG_PATH = config
    handler.config.cache_clear()
    handler.fake = FakeTable()
    handler.people_service = FakeDirectory()
    monkeypatch.setattr(handler, "table", lambda: handler.fake)
    monkeypatch.setattr(handler, "directory", lambda: handler.people_service)
    return handler


def event(
    body: Any = None,
    subject: str | None = OWNER,
    email: str = OWNER_EMAIL,
    method: str = "POST",
    **path: str,
) -> dict[str, Any]:
    claims = {"sub": subject, "email": email} if subject else {}
    made: dict[str, Any] = {"requestContext": {"authorizer": {"jwt": {"claims": claims}}, "http": {"method": method}}}
    if body is not None:
        made["body"] = body if isinstance(body, str) else json.dumps(body)
    if path:
        made["pathParameters"] = path
    return made


def answer(response: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    assert response["headers"]["cache-control"] == "no-store"
    assert response["statusCode"] not in (403, 404), "the distribution would replace these with the not-found page"
    return response["statusCode"], json.loads(response["body"])


def view(api: Any, subject: str = OWNER, email: str = OWNER_EMAIL) -> dict[str, Any]:
    return answer(api.read(event(subject=subject, email=email)))[1]


@pytest.fixture
def firm(api: Any) -> Any:
    """An API with one firm in it: the owner enrolled and the details saved."""
    assert answer(api.enrol(event()))[0] == 200
    assert answer(api.write(event({"values": {**YOU, **FIRM}}, section="signup")))[0] == 200
    return api


def invite(api: Any, email: str = "alex@example.test", role: str = "admin", **who: Any) -> tuple[int, dict[str, Any]]:
    return answer(api.people(event({"values": {"invite_email": email, "invite_role": role}}, **who)))


def member(api: Any, email: str) -> dict[str, Any]:
    return next(person for person in view(api)["people"] if person["email"] == email)


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


# ------------------------------------------------------------ who is asking


def test_a_request_without_a_person_is_refused_everywhere(api: Any) -> None:
    nobody = {"subject": None}
    assert answer(api.read(event(**nobody))) == (401, {"error": "not_signed_in"})
    for handler in (api.enrol, api.accept, api.people):
        assert answer(handler(event({"values": {}}, **nobody)))[0] == 401
    assert answer(api.write(event({"values": {}}, section="signup", **nobody)))[0] == 401


def test_a_signed_in_person_with_no_firm_reads_as_nobody_and_can_save_nothing(api: Any) -> None:
    assert view(api)["member"] is None
    status, body = answer(api.write(event({"values": {**YOU, **FIRM}}, section="signup")))
    assert (status, body["error"]) == (400, "no_firm")
    assert api.fake.items == {}


# ------------------------------------------------------------------- enrolling


def test_enrolling_makes_the_person_the_owner_of_a_new_firm_once(api: Any) -> None:
    status, first = answer(api.enrol(event()))
    assert (status, first["member"]["role"]) == (200, "owner")
    assert answer(api.enrol(event()))[1]["member"]["firmId"] == first["member"]["firmId"], (
        "a second call makes no second firm"
    )
    seen = view(api)
    assert seen["member"] == {"role": "owner", "sub": OWNER}
    assert [person["email"] for person in seen["people"]] == [OWNER_EMAIL]
    assert [change["what"] for change in seen["changes"]] == ["created"]


def test_what_a_person_saved_before_firms_existed_is_moved_into_their_firm(api: Any) -> None:
    earlier = "ACCOUNT#" + OWNER
    agreement_sort = api.agreement_key()
    api.fake.put_item(
        {"pk": earlier, "sk": "signup", "data": {"values": {**YOU, **FIRM}, "completedAt": "2026-11-18T16:00:00.000Z"}}
    )
    api.fake.put_item(
        {
            "pk": earlier,
            "sk": "company",
            "data": {"values": {"office_region": "London"}, "feeEarners": [{"name": "Sam"}], "savedAt": "x"},
        }
    )
    api.fake.put_item(
        {"pk": earlier, "sk": agreement_sort, "data": {"acceptedBy": "Sam Example", "version": "draft-0.1"}}
    )

    api.enrol(event())
    seen = view(api)
    assert seen["signup"]["values"] == {**YOU, **FIRM}
    assert seen["signup"]["completedAt"] == "2026-11-18T16:00:00.000Z"
    assert seen["company"]["values"] == {"office_region": "London"}
    assert "feeEarners" not in seen["company"], "fee earners are no longer kept here"
    assert seen["agreement"]["acceptedBy"] == "Sam Example"
    assert api.fake.sorts(earlier) == ["membership", "person"], "nothing is left behind under the person"


# ---------------------------------------------------------------------- saving


def test_details_are_split_between_the_person_and_the_firm_and_read_back_whole(firm: Any) -> None:
    seen = view(firm)
    assert seen["signup"]["values"] == {**YOU, **FIRM}
    assert firm.fake.items[("ACCOUNT#" + OWNER, "person")]["data"]["values"] == YOU
    firm_details = next(item for (pk, sk), item in firm.fake.items.items() if pk.startswith("FIRM#") and sk == "firm")
    assert firm_details["data"]["values"] == FIRM


def test_only_known_fields_on_show_are_kept(firm: Any) -> None:
    sent = {**YOU, **FIRM, "is_admin": True, "person_password": "Secret-password-1", "firm_company_number": "12345678"}
    stored = answer(firm.write(event({"values": sent}, section="signup")))[1]["signup"]["values"]
    assert not {"is_admin", "person_password", "firm_company_number"} & set(stored)


def test_details_that_fail_the_form_rules_are_refused_and_nothing_changes(firm: Any) -> None:
    before = dict(firm.fake.items)
    bad = {**YOU, **FIRM, "person_email": "sam-at-example", "firm_name": ""}
    status, body = answer(firm.write(event({"values": bad}, section="signup")))
    assert status == 422
    assert set(body["errors"]) == {"person_email", "firm_name"}
    assert firm.fake.items == before


@pytest.mark.parametrize("value", [{"nested": 1}, ["a"], 12, "x" * 5000])
def test_a_value_of_the_wrong_shape_or_size_is_refused(firm: Any, value: Any) -> None:
    status, body = answer(firm.write(event({"values": {**YOU, **FIRM, "firm_name": value}}, section="signup")))
    assert status == 422
    assert "firm_name" in body["errors"]


def test_a_choice_that_is_not_one_of_the_options_is_refused(firm: Any) -> None:
    status, body = answer(firm.write(event({"values": {**YOU, **FIRM, "person_role": "emperor"}}, section="signup")))
    assert status == 422
    assert "person_role" in body["errors"]


@pytest.mark.parametrize("body", ["not json", "[]", '{"values": []}'])
def test_a_body_that_is_not_the_expected_json_is_refused(firm: Any, body: str) -> None:
    assert answer(firm.write(event(body, section="signup")))[0] == 400


def test_a_body_over_the_size_limit_is_refused(firm: Any) -> None:
    oversized = json.dumps({"values": {"firm_name": "x" * (firm.config()["limits"]["max_body_bytes"] + 1)}})
    assert answer(firm.write(event(oversized, section="signup"))) == (400, {"error": "too_large"})


def test_an_unknown_section_is_refused(firm: Any) -> None:
    assert answer(firm.write(event({"values": {}}, section="agreement"))) == (400, {"error": "unknown_section"})


def test_company_information_is_saved_with_the_register_version_and_no_fee_earners(firm: Any) -> None:
    sent = {"values": company_values(firm), "feeEarners": [{"name": "Sam"}], "registerVersion": "made-up"}
    status, body = answer(firm.write(event(sent, section="company")))
    assert status == 200, body
    assert body["company"]["registerVersion"] == build_tool.load_json(build_tool.RULES)["register_version"]
    assert "feeEarners" not in body["company"]
    assert not any(name.startswith("private_") for name in body["company"]["values"]), "private answers are not on show"


def test_company_information_needs_a_funding_type(firm: Any) -> None:
    values = {**company_values(firm), "funding_legal_aid": False}
    status, body = answer(firm.write(event({"values": values}, section="company")))
    assert status == 422
    assert body["problems"] == [firm.config()["messages"]["funding_required"]]


# ----------------------------------------------------------------- separation


def test_two_firms_never_see_each_other(firm: Any) -> None:
    firm.enrol(event(subject=STRANGER, email="other@example.test"))
    other = {**YOU, **FIRM, "firm_name": "Other Firm", "person_email": "other@example.test"}
    firm.write(event({"values": other}, section="signup", subject=STRANGER, email="other@example.test"))
    assert view(firm)["signup"]["values"]["firm_name"] == FIRM["firm_name"]
    theirs = view(firm, STRANGER, "other@example.test")
    assert theirs["signup"]["values"]["firm_name"] == "Other Firm"
    assert [person["email"] for person in theirs["people"]] == ["other@example.test"]


def test_a_person_cannot_act_on_a_member_of_another_firm(firm: Any) -> None:
    firm.enrol(event(subject=STRANGER, email="other@example.test"))
    status, body = answer(firm.people(event(method="DELETE", member=STRANGER)))
    assert (status, body["error"]) == (400, "unknown_member")
    assert view(firm, STRANGER, "other@example.test")["member"] is not None


# --------------------------------------------------------------------- people


def test_an_owner_invites_an_administrator_who_then_belongs_to_the_firm(firm: Any) -> None:
    status, body = invite(firm, "Alex@Example.test")
    assert status == 200
    assert [(person["email"], person["role"]) for person in body["people"]] == [
        (OWNER_EMAIL, "owner"),
        ("alex@example.test", "admin"),
    ]
    assert firm.people_service.calls == [("create", "alex@example.test")]
    invited = member(firm, "alex@example.test")
    theirs = view(firm, invited["sub"], "alex@example.test")
    assert theirs["member"]["role"] == "admin"
    assert theirs["signup"]["values"]["firm_name"] == FIRM["firm_name"], "they see the firm's details"
    assert theirs["signup"]["values"]["person_email"] == "alex@example.test", "and their own, not the owner's"
    assert "person_name" not in theirs["signup"]["values"]
    assert body["changes"][0]["what"] == "invited"


def test_an_email_address_that_already_has_an_account_cannot_be_invited(firm: Any) -> None:
    invite(firm)
    status, body = invite(firm)
    assert (status, body["error"]) == (409, "invite_exists")
    assert len(view(firm)["people"]) == 2


def test_an_invitation_needs_a_real_address_and_a_known_role(firm: Any) -> None:
    assert invite(firm, "not-an-address")[0] == 422
    status, body = invite(firm, role="emperor")
    assert status == 422
    assert "invite_role" in body["errors"]
    assert firm.people_service.calls == []


def test_an_administrator_can_save_answers_but_not_invite_accept_or_manage(firm: Any) -> None:
    invite(firm)
    admin = {"subject": member(firm, "alex@example.test")["sub"], "email": "alex@example.test"}
    assert answer(firm.write(event({"values": company_values(firm)}, section="company", **admin)))[0] == 200

    for refused in (
        firm.people(event({"values": {"invite_email": "jo@example.test", "invite_role": "admin"}}, **admin)),
        firm.people(event({"role": "owner"}, method="PUT", member=admin["subject"], **admin)),
        firm.people(event(method="DELETE", member=OWNER, **admin)),
        firm.accept(event({"values": ACCEPT}, **admin)),
    ):
        status, body = answer(refused)
        assert (status, body["error"]) == (400, "not_allowed")
        assert body["problems"] == [firm.config()["messages"]["not_allowed"]]
    assert len(view(firm)["people"]) == 2
    assert view(firm)["agreement"] is None


def test_an_owner_can_make_an_administrator_an_owner_and_back(firm: Any) -> None:
    invite(firm)
    alex = member(firm, "alex@example.test")["sub"]
    assert answer(firm.people(event({"role": "owner"}, method="PUT", member=alex)))[0] == 200
    assert view(firm, alex, "alex@example.test")["member"]["role"] == "owner"
    assert answer(firm.people(event({"role": "admin"}, method="PUT", member=alex)))[0] == 200
    assert member(firm, "alex@example.test")["role"] == "admin"
    assert answer(firm.people(event({"role": "emperor"}, method="PUT", member=alex)))[0] == 422


def test_a_firm_always_keeps_an_owner(firm: Any) -> None:
    invite(firm)
    for last_owner_leaving in (
        firm.people(event({"role": "admin"}, method="PUT", member=OWNER)),
        firm.people(event(method="DELETE", member=OWNER)),
    ):
        status, body = answer(last_owner_leaving)
        assert (status, body["error"]) == (409, "last_owner")
    assert view(firm)["member"]["role"] == "owner"


def test_removing_a_person_ends_their_access_and_their_sign_in(firm: Any) -> None:
    invite(firm)
    alex = member(firm, "alex@example.test")["sub"]
    status, body = answer(firm.people(event(method="DELETE", member=alex)))
    assert status == 200
    assert [person["email"] for person in body["people"]] == [OWNER_EMAIL]
    assert view(firm, alex, "alex@example.test")["member"] is None
    assert firm.fake.sorts("ACCOUNT#" + alex) == []
    assert firm.people_service.calls[-2:] == [("sign_out", alex), ("delete", alex)]
    assert answer(firm.write(event({"values": company_values(firm)}, section="company", subject=alex)))[0] == 400


def test_a_firm_cannot_have_more_people_than_the_limit(firm: Any) -> None:
    firm.config()["limits"]["max_members"] = 2
    assert invite(firm, "one@example.test")[0] == 200
    status, body = invite(firm, "two@example.test")
    assert (status, body["error"]) == (409, "too_many_members")


# ------------------------------------------------------------------ agreement


def test_an_owner_accepting_the_agreement_records_who_and_which_version(firm: Any) -> None:
    status, body = answer(firm.accept(event({"values": ACCEPT})))
    agreement = build_tool.load_site()["agreement"]
    assert status == 200
    assert (body["agreement"]["acceptedBy"], body["agreement"]["acceptedByEmail"]) == ("Sam Example", OWNER_EMAIL)
    assert (body["agreement"]["id"], body["agreement"]["version"]) == (agreement["id"], agreement["version"])
    assert view(firm)["agreement"] == body["agreement"]


def test_an_acceptance_cannot_be_written_twice(firm: Any) -> None:
    first = answer(firm.accept(event({"values": ACCEPT})))[1]["agreement"]
    status, body = answer(firm.accept(event({"values": {**ACCEPT, "accept_name": "Someone Else"}})))
    assert (status, body) == (409, {"error": "already_accepted"})
    assert view(firm)["agreement"] == first


def test_the_agreement_is_not_accepted_without_the_tick(firm: Any) -> None:
    status, body = answer(firm.accept(event({"values": {**ACCEPT, "accept_tick": False}})))
    assert status == 422
    assert "accept_tick" in body["errors"]


# -------------------------------------------------------------- change record


def test_every_change_is_recorded_with_who_made_it_newest_first(firm: Any) -> None:
    firm.write(event({"values": company_values(firm)}, section="company"))
    invite(firm)
    firm.accept(event({"values": ACCEPT}))
    changes = view(firm)["changes"]
    assert [change["what"] for change in changes] == ["agreement", "invited", "company", "signup", "created"]
    assert all(change["by"] == OWNER_EMAIL and change["at"].endswith("Z") for change in changes)
    assert changes[1]["subject"] == "alex@example.test"


def test_a_refused_change_is_not_recorded(firm: Any) -> None:
    before = len(view(firm)["changes"])
    firm.write(event({"values": {**YOU, **FIRM, "firm_name": ""}}, section="signup"))
    assert len(view(firm)["changes"]) == before


# ---------------------------------------------------------------- shared rules


def shared_cases() -> list[dict[str, Any]]:
    return json.loads((ROOT / "tests" / "fixtures" / "validation_cases.json").read_text(encoding="utf-8"))


@pytest.mark.parametrize("case", shared_cases(), ids=lambda case: case["name"])
def test_the_api_applies_the_same_rules_as_the_browser(api: Any, case: dict[str, Any]) -> None:
    import validation

    messages = json.loads((ROOT / "site" / "config" / "forms.json").read_text(encoding="utf-8"))["messages"]
    assert validation.validate_field(case["field"], case["values"], messages, 2000) == case["message"]
