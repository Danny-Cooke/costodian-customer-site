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


class UserNotFoundException(Exception):
    pass


ATTRIBUTE = "custom:customer"
FREE = "free"
PATH = "/example-site/test/customers"
VERSIONS = "/example-site/test/versions"
POOL = 12  # more than one page of labels, so that paging is exercised
PAGE = 10


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

    def sorts(self, partition: str) -> list[str]:
        return sorted(sk for (pk, sk) in self.items if pk == partition)

    def data(self, partition: str, sort: str) -> Any:
        return self.items[(partition, sort)]["data"]


class FakeDirectory:
    """The sign-in service: people, the customer number each carries, and what it was asked."""

    def __init__(self) -> None:
        self.users: dict[str, dict[str, str]] = {}
        self.calls: list[tuple[str, str]] = []

    def register(self, subject: str, email: str) -> None:
        self.users[subject] = {"sub": subject, "email": email}

    def number_of(self, subject: str) -> str | None:
        return self.users.get(subject, {}).get(ATTRIBUTE)

    def admin_create_user(
        self, UserPoolId: str, Username: str, UserAttributes: list[dict[str, str]], **_: Any
    ) -> dict[str, Any]:  # noqa: N803
        if any(user["email"] == Username for user in self.users.values()):
            raise UsernameExistsException
        subject = f"sub-{len(self.users) + 1}"
        self.users[subject] = {"sub": subject, **{a["Name"]: a["Value"] for a in UserAttributes}}
        self.calls.append(("create", Username))
        return {"User": {"Attributes": [{"Name": "sub", "Value": subject}, {"Name": "email", "Value": Username}]}}

    def admin_get_user(self, UserPoolId: str, Username: str) -> dict[str, Any]:  # noqa: N803
        if Username not in self.users:
            raise UserNotFoundException
        return {"UserAttributes": [{"Name": name, "Value": value} for name, value in self.users[Username].items()]}

    def admin_update_user_attributes(
        self, UserPoolId: str, Username: str, UserAttributes: list[dict[str, str]]
    ) -> None:  # noqa: N803
        self.users[Username].update({a["Name"]: a["Value"] for a in UserAttributes})
        self.calls.append(("attach", Username))

    def admin_user_global_sign_out(self, UserPoolId: str, Username: str) -> None:  # noqa: N803
        self.calls.append(("sign_out", Username))

    def admin_delete_user(self, UserPoolId: str, Username: str) -> None:  # noqa: N803
        self.users.pop(Username, None)
        self.calls.append(("delete", Username))


class FakeParameters:
    """The customer labels, one per number, handed out a page at a time."""

    def __init__(self) -> None:
        self.values = {
            f"{PATH}/{n:04d}": json.dumps({"customer": f"{n:04d}", "status": FREE}) for n in range(1, POOL + 1)
        }
        self.values[VERSIONS] = json.dumps(["v1.0"])
        self.writes = 0

    def versions(self) -> list[str]:
        return json.loads(self.values[VERSIONS])

    def label(self, number: str) -> dict[str, Any]:
        return json.loads(self.values[f"{PATH}/{number}"])

    def get_parameter(self, Name: str) -> dict[str, Any]:  # noqa: N803
        return {"Parameter": {"Name": Name, "Value": self.values[Name]}}

    def put_parameter(self, Name: str, Value: str, **_: Any) -> None:  # noqa: N803
        self.values[Name] = Value
        self.writes += 1

    def get_parameters_by_path(self, Path: str, NextToken: str | None = None, **_: Any) -> dict[str, Any]:  # noqa: N803
        names = sorted(name for name in self.values if name.startswith(Path + "/"))
        start = int(NextToken or 0)
        page: dict[str, Any] = {
            "Parameters": [{"Name": name, "Value": self.values[name]} for name in names[start : start + PAGE]]
        }
        if start + PAGE < len(names):
            page["NextToken"] = str(start + PAGE)
        return page


CURRENT: dict[str, Any] = {}

ENVIRONMENT = {
    "TABLE_HASH_KEY": "pk",
    "TABLE_RANGE_KEY": "sk",
    "USER_POOL_ID": "pool",
    "CUSTOMER_ATTRIBUTE": ATTRIBUTE,
    "CUSTOMER_FREE_STATUS": FREE,
    "CUSTOMER_PARAMETER_PATH": PATH,
    "CUSTOMER_TABLE_NAME_TEMPLATE": "test-customer-{number}-tbl",
    "CUSTOMER_TABLE_ARN_TEMPLATE": "arn:aws:dynamodb:eu-west-2:111122223333:table/test-customer-{number}-tbl",
    "CUSTOMER_KEY_ALIAS_TEMPLATE": "alias/test-customer-{number}-key",
    "DATA_ROLE_ARN": "arn:aws:iam::111122223333:role/test-data-role",
    "DATA_ACTIONS": "dynamodb:Query,dynamodb:GetItem",
    "LEGACY_TABLE_NAME": "legacy",
    "VERSIONS_PARAMETER": VERSIONS,
    "VERSION_TAG_PATTERN": r"^v[0-9]+\.[0-9]+(\.[0-9]+)?$",
}


@pytest.fixture
def api(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Any:
    config = api_tool.build_api(tmp_path / "api", [])
    for name, value in ENVIRONMENT.items():
        monkeypatch.setenv(name, value)
    sys.modules.pop("handler", None)
    import handler

    handler.CONFIG_PATH = config
    handler.config.cache_clear()
    handler.tables = {}
    handler.old_table = FakeTable()
    handler.people_service = FakeDirectory()
    handler.labels = FakeParameters()
    handler.people_service.register(OWNER, OWNER_EMAIL)
    handler.people_service.register(STRANGER, "other@example.test")

    def store(number: str) -> FakeTable:
        if not handler.CUSTOMER_NUMBER.fullmatch(number):
            raise handler.Refused(400, {"error": "unknown_customer"})
        return handler.tables.setdefault(number, FakeTable())

    monkeypatch.setattr(handler, "store", store)
    monkeypatch.setattr(handler, "legacy", lambda: handler.old_table)
    monkeypatch.setattr(handler, "directory", lambda: handler.people_service)
    monkeypatch.setattr(handler, "parameters", lambda: handler.labels)
    CURRENT["directory"] = handler.people_service
    return handler


def event(
    body: Any = None,
    subject: str | None = OWNER,
    email: str = OWNER_EMAIL,
    method: str = "POST",
    stale: bool = False,
    **path: str,
) -> dict[str, Any]:
    """A request as API Gateway passes it on. The token carries the person's customer
    number as the sign-in service holds it now, unless the token is `stale`."""
    claims = {"sub": subject, "email": email} if subject else {}
    number = None if stale or not subject else CURRENT["directory"].number_of(subject)
    if number:
        claims[ATTRIBUTE] = number
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
    """An API with one firm in it: the owner enrolled as customer 0001 and the details saved."""
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
    assert api.tables == {}, "no customer's table was touched"


@pytest.mark.parametrize("claim", ["1; DROP", "../0002", "0001/x", "", "abc", "1" * 13])
def test_a_customer_number_that_is_not_a_number_is_never_used(api: Any, claim: str) -> None:
    request = event()
    request["requestContext"]["authorizer"]["jwt"]["claims"][ATTRIBUTE] = claim
    assert answer(api.read(request))[1]["member"] is None
    assert api.tables == {}


# ------------------------------------------------------------------- enrolling


def test_enrolling_takes_the_lowest_free_customer_number_once(api: Any) -> None:
    status, first = answer(api.enrol(event()))
    assert (status, first) == (200, {"member": {"role": "owner"}, "renew": True})
    assert api.people_service.number_of(OWNER) == "0001"
    assert "customer" not in json.dumps(first), "the number is not shown to the browser"
    assert answer(api.enrol(event())) == (200, {"member": {"role": "owner"}, "renew": False})
    assert list(api.tables) == ["0001"], "a second call takes no second number"

    seen = view(api)
    assert seen["member"] == {"role": "owner", "sub": OWNER}
    assert [person["email"] for person in seen["people"]] == [OWNER_EMAIL]
    assert [change["what"] for change in seen["changes"]] == ["created"]
    label = api.labels.label("0001")
    assert (label["status"], label["customer"]) == ("signed up", "0001")
    assert label["signed_up_on"] and label["delete_after"] is None
    assert api.labels.label("0002")["status"] == FREE


def test_each_firm_gets_a_table_of_its_own(api: Any) -> None:
    api.enrol(event())
    api.enrol(event(subject=STRANGER, email="other@example.test"))
    assert (api.people_service.number_of(OWNER), api.people_service.number_of(STRANGER)) == ("0001", "0002")
    assert sorted(api.tables) == ["0001", "0002"]
    assert api.tables["0001"].sorts("FIRM")[-1] == "member#" + OWNER
    assert api.tables["0002"].sorts("FIRM")[-1] == "member#" + STRANGER


def test_a_number_someone_else_took_a_moment_ago_is_passed_over(api: Any) -> None:
    # The label still says free, but another sign-up has just claimed the table.
    api.store("0001").put_item({"pk": "FIRM", "sk": "claim", "data": {"by": "someone-else"}})
    api.enrol(event())
    assert api.people_service.number_of(OWNER) == "0002"
    assert api.tables["0001"].sorts("FIRM") == ["claim"], "the other firm's table is left alone"


def test_a_token_from_before_enrolling_does_not_claim_a_second_number(api: Any) -> None:
    api.enrol(event())
    assert answer(api.read(event(stale=True)))[1]["member"] is None, "the old token names no customer"
    assert answer(api.enrol(event(stale=True))) == (200, {"member": {"role": "owner"}, "renew": True})
    assert list(api.tables) == ["0001"]


def test_when_every_number_is_taken_a_new_firm_is_asked_to_wait(api: Any) -> None:
    for name, value in api.labels.values.items():
        if name.startswith(PATH + "/"):
            api.labels.values[name] = json.dumps({**json.loads(value), "status": "signed up"})
    status, body = answer(api.enrol(event()))
    assert (status, body["error"]) == (409, "no_capacity")
    assert body["problems"] == [api.config()["messages"]["no_capacity"]]
    assert api.people_service.number_of(OWNER) is None


def test_the_free_numbers_are_found_across_every_page_of_labels(api: Any) -> None:
    assert POOL > PAGE
    assert api.free_numbers() == [f"{n:04d}" for n in range(1, POOL + 1)]


def test_a_firm_saved_in_the_shared_table_is_moved_into_its_own(api: Any) -> None:
    old = api.old_table
    for sort, data in {
        "firm": {"values": FIRM, "completedAt": "2026-11-18T16:00:00.000Z"},
        "company": {"values": {"office_region": "London"}, "savedAt": "x"},
        api.agreement_key(): {"acceptedBy": "Sam Example", "version": "draft-0.1"},
        "member#" + OWNER: {
            "sub": OWNER,
            "email": OWNER_EMAIL,
            "role": "owner",
            "addedBy": OWNER_EMAIL,
            "addedAt": "2026-11-18T15:00:00.000Z",
        },
        "change#1": {"at": "2026-11-18T15:00:00.000Z", "by": OWNER_EMAIL, "what": "created"},
    }.items():
        old.put_item({"pk": "FIRM#abc", "sk": sort, "data": data})
    old.put_item({"pk": "ACCOUNT#" + OWNER, "sk": "membership", "data": {"firmId": "abc", "role": "owner"}})
    old.put_item({"pk": "ACCOUNT#" + OWNER, "sk": "person", "data": {"values": YOU}})

    assert answer(api.enrol(event())) == (200, {"member": {"role": "owner"}, "renew": True})
    seen = view(api)
    assert seen["signup"]["values"] == {**YOU, **FIRM}
    assert seen["signup"]["completedAt"] == "2026-11-18T16:00:00.000Z"
    assert seen["company"]["values"] == {"office_region": "London"}
    assert seen["agreement"]["acceptedBy"] == "Sam Example"
    assert [change["what"] for change in seen["changes"]] == ["created"], "its history comes with it"
    assert old.items == {}, "nothing is left in the shared table"
    label = api.labels.label("0001")
    assert (label["status"], label["name"], label["sra_number"]) == ("set-up complete", FIRM["firm_name"], "123456")


def test_a_person_the_firm_removed_is_not_given_a_firm_of_their_own(firm: Any) -> None:
    invite(firm)
    alex = member(firm, "alex@example.test")["sub"]
    still_valid_token = event(subject=alex, email="alex@example.test")
    firm.people(event(method="DELETE", member=alex))
    assert answer(firm.read(still_valid_token))[1]["member"] is None
    assert answer(firm.enrol(still_valid_token))[0] == 400
    assert answer(firm.enrol(event(subject=alex, email="alex@example.test", stale=True))) == (
        401,
        {"error": "not_signed_in"},
    )
    assert list(firm.tables) == ["0001"]


# --------------------------------------------------------------- the label


def test_the_label_follows_what_the_firm_has_saved(firm: Any) -> None:
    label = firm.labels.label("0001")
    assert (label["status"], label["name"], label["sra_number"]) == ("signed up", FIRM["firm_name"], "123456")
    assert label["company_number"] is None, "a partnership has no company number"

    firm.write(event({"values": company_values(firm)}, section="company"))
    assert firm.labels.label("0001")["status"] == "signed up", "the agreement is still to do"
    firm.accept(event({"values": ACCEPT}))
    assert firm.labels.label("0001")["status"] == "set-up complete"

    company = {**YOU, **FIRM, "firm_type": "llp", "firm_company_number": "OC123456"}
    firm.write(event({"values": company}, section="signup"))
    assert firm.labels.label("0001")["company_number"] == "OC123456"


def test_the_label_is_written_only_when_it_changes(firm: Any) -> None:
    before = firm.labels.writes
    firm.write(event({"values": {**YOU, **FIRM}}, section="signup"))
    assert firm.labels.writes == before


def test_a_customer_marked_as_left_stays_left(firm: Any) -> None:
    firm.write_label("0001", status="left", left_on="2027-01-10")
    firm.write(event({"values": {**YOU, **FIRM, "firm_name": "Renamed LLP"}}, section="signup"))
    label = firm.labels.label("0001")
    assert (label["status"], label["name"]) == ("left", "Renamed LLP")
    assert label["delete_after"] == "2034-01-10"


@pytest.mark.parametrize(
    ("left_on", "last_case", "expected"),
    [
        (None, None, None),
        (None, "2026-12-01", None),
        ("2027-01-10", None, "2034-01-10"),
        ("2027-01-10", "2026-12-01", "2033-12-01"),
        ("2027-01-10", "2028-02-29", "2035-02-28"),
    ],
    ids=["still a customer", "still a customer with cases", "left, no case", "left, after last case", "leap day"],
)
def test_records_may_go_seven_years_after_the_last_case_and_never_while_a_customer(
    api: Any, left_on: str | None, last_case: str | None, expected: str | None
) -> None:
    assert api.config()["retention"]["years"] == 7
    assert api.delete_after(left_on, last_case) == expected


# ---------------------------------------------------- reaching one customer


def test_a_request_is_given_one_customers_table_and_key_and_nothing_else(api: Any) -> None:
    policy = api.session_policy("0007")
    table, key = policy["Statement"]
    assert table["Resource"] == "arn:aws:dynamodb:eu-west-2:111122223333:table/test-customer-0007-tbl"
    assert table["Action"] == ["dynamodb:Query", "dynamodb:GetItem"]
    assert key["Condition"] == {"ForAnyValue:StringEquals": {"kms:ResourceAliases": "alias/test-customer-0007-key"}}
    assert "0008" not in json.dumps(policy) and "*" not in table["Resource"]


# ---------------------------------------------------------------------- saving


def test_details_are_split_between_the_person_and_the_firm_and_read_back_whole(firm: Any) -> None:
    seen = view(firm)
    assert seen["signup"]["values"] == {**YOU, **FIRM}
    mine = firm.tables["0001"]
    assert mine.data("PERSON#" + OWNER, "person")["values"] == YOU
    firm_details = mine.items[("FIRM", "firm")]
    assert firm_details["data"]["values"] == FIRM


def test_only_known_fields_on_show_are_kept(firm: Any) -> None:
    sent = {**YOU, **FIRM, "is_admin": True, "person_password": "Secret-password-1", "firm_company_number": "12345678"}
    stored = answer(firm.write(event({"values": sent}, section="signup")))[1]["signup"]["values"]
    assert not {"is_admin", "person_password", "firm_company_number"} & set(stored)


def test_details_that_fail_the_form_rules_are_refused_and_nothing_changes(firm: Any) -> None:
    before = dict(firm.tables["0001"].items)
    bad = {**YOU, **FIRM, "person_email": "sam-at-example", "firm_name": ""}
    status, body = answer(firm.write(event({"values": bad}, section="signup")))
    assert status == 422
    assert set(body["errors"]) == {"person_email", "firm_name"}
    assert firm.tables["0001"].items == before


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


def test_company_information_is_saved_without_fee_earners_or_charging_answers(firm: Any) -> None:
    sent = {"values": {**company_values(firm), "private_rate_a": "300"}, "feeEarners": [{"name": "Sam"}]}
    status, body = answer(firm.write(event(sent, section="company")))
    assert status == 200, body
    assert set(body["company"]) == {"values", "savedAt"}
    assert not any(name.startswith(("private_", "position_")) for name in body["company"]["values"])
    assert body["company"]["values"]["product_version"] == "v1.0"


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
    assert firm.tables["0001"].data("FIRM", "firm")["values"]["firm_name"] == FIRM["firm_name"]
    assert firm.tables["0002"].data("FIRM", "firm")["values"]["firm_name"] == "Other Firm"
    assert (firm.labels.label("0001")["name"], firm.labels.label("0002")["name"]) == (FIRM["firm_name"], "Other Firm")


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
    assert firm.people_service.calls[-1] == ("create", "alex@example.test")
    invited = member(firm, "alex@example.test")
    assert firm.people_service.number_of(invited["sub"]) == "0001", "their sign-in carries the same customer number"
    assert list(firm.tables) == ["0001"], "an invitation takes no new number"
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
    assert not any(call[0] == "create" for call in firm.people_service.calls)


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
    assert firm.tables["0001"].sorts("PERSON#" + alex) == []
    assert "member#" + alex not in firm.tables["0001"].sorts("FIRM")
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
    assert [change["what"] for change in changes] == ["agreement", "invited", "company", "version", "signup", "created"]
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


# -------------------------------------------------------------------- versions


def tag_made(name: str, kind: str = "tag") -> dict[str, Any]:
    """The event the repository raises when a reference is created."""
    return {"detail": {"event": "referenceCreated", "referenceType": kind, "referenceName": name}}


def choose(api: Any, version: str) -> tuple[int, dict[str, Any]]:
    values = {**company_values(api), "product_version": version}
    return answer(api.write(event({"values": values}, section="company")))


def test_the_versions_on_offer_are_read_with_the_account(firm: Any) -> None:
    assert view(firm)["versions"] == ["v1.0"]
    assert answer(firm.read(event(stale=True)))[1]["versions"] == ["v1.0"], "and before a person has a firm"


def test_tagging_a_release_puts_it_on_offer_in_order(api: Any) -> None:
    assert api.catalogue(tag_made("v1.10")) == {"versions": ["v1.0", "v1.10"]}
    assert api.catalogue(tag_made("v1.2"))["versions"] == ["v1.0", "v1.2", "v1.10"], "by number, not as text"
    assert api.catalogue(tag_made("v1.2"))["versions"] == ["v1.0", "v1.2", "v1.10"], "a tag made twice is offered once"
    assert api.labels.versions() == ["v1.0", "v1.2", "v1.10"]


@pytest.mark.parametrize(
    "event_made",
    [tag_made("release-candidate"), tag_made("v2"), tag_made("v1.1; rm -rf"), tag_made("v1.1", kind="branch"), {}],
    ids=["not a version", "no minor number", "not a clean name", "a branch", "no detail"],
)
def test_anything_that_is_not_a_version_tag_is_left_out(api: Any, event_made: dict[str, Any]) -> None:
    assert api.catalogue(event_made) == {"versions": ["v1.0"]}
    assert api.labels.versions() == ["v1.0"]


def test_a_firm_chooses_a_version_and_can_move_to_a_newer_one(firm: Any) -> None:
    assert choose(firm, "v1.0")[0] == 200
    assert firm.labels.label("0001")["version"] == "v1.0"

    status, body = choose(firm, "v1.1")
    assert status == 422
    assert "product_version" in body["errors"], "a version that is not on offer cannot be chosen"

    firm.catalogue(tag_made("v1.1"))
    assert choose(firm, "v1.1")[0] == 200
    assert view(firm)["company"]["values"]["product_version"] == "v1.1"
    assert firm.labels.label("0001")["version"] == "v1.1"
    moves = [change for change in view(firm)["changes"] if change["what"] == "version"]
    assert [move["subject"] for move in moves] == ["v1.1", "v1.0"], "each move is in the change record"


def test_a_firm_is_not_moved_back_to_an_older_version(firm: Any) -> None:
    firm.catalogue(tag_made("v1.1"))
    choose(firm, "v1.1")
    status, body = choose(firm, "v1.0")
    assert status == 422
    assert body["errors"]["product_version"] == firm.config()["messages"]["version_older"]
    assert view(firm)["company"]["values"]["product_version"] == "v1.1"


def test_saving_again_on_the_same_version_records_no_move(firm: Any) -> None:
    choose(firm, "v1.0")
    choose(firm, "v1.0")
    assert sum(change["what"] == "version" for change in view(firm)["changes"]) == 1
