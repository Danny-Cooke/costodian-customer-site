"""The account API: a firm's account, the people who manage it, and what they enter.

One entry point per Lambda function, so that each runs under a role that can do
only its own job:

    read    GET    <base>/account                  the signed-in person's firm, in full
    enrol   POST   <base>/account/firm             give a new person a firm of their own
    write   PUT    <base>/account/{section}        save one section (signup, company)
    accept  POST   <base>/account/agreement        record acceptance of the agreement, once
    people  POST   <base>/account/people           invite a person
            PUT    <base>/account/people/{member}  change a person's role
            DELETE <base>/account/people/{member}  remove a person

API Gateway has already checked the token; the person is the token's subject.
What a person may do comes from their role in the firm, looked up on every
request, so a change of role or a removal takes effect at once.

Nothing a person submits is ever logged. No answer is a 403 or a 404: the
distribution in front of this API turns those into the site's not-found page.
"""

from __future__ import annotations

import base64
import itertools
import json
import os
import secrets
import uuid
from datetime import UTC, datetime
from decimal import Decimal
from functools import cache
from pathlib import Path
from typing import Any

import validation

CONFIG_PATH = Path(os.environ.get("API_CONFIG", Path(__file__).with_name("config.json")))
SECTION_PARAMETER = "section"
MEMBER_PARAMETER = "member"
USERNAME_EXISTS = "UsernameExistsException"
CONDITION_FAILED = "ConditionalCheckFailedException"
SEQUENCE = itertools.count()

Event = dict[str, Any]
Item = dict[str, Any]
Response = dict[str, Any]


class Refused(Exception):
    """The request cannot be accepted. Carries the status and what to tell the browser."""

    def __init__(self, status: int, body: dict[str, Any]) -> None:
        super().__init__(body.get("error", ""))
        self.status = status
        self.body = body


@cache
def config() -> dict[str, Any]:
    return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))


@cache
def table() -> Any:
    import boto3

    return boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])


@cache
def directory() -> Any:
    """The sign-in service, for inviting and removing people."""
    import boto3

    return boto3.client("cognito-idp")


def now() -> str:
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def respond(status: int, body: dict[str, Any]) -> Response:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json", "cache-control": "no-store"},
        "body": json.dumps(body, default=plain),
    }


def plain(value: Any) -> Any:
    """DynamoDB returns numbers as Decimal; JSON wants int or float."""
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    raise TypeError(f"cannot serialise {type(value).__name__}")


def refuse(status: int, error: str, **more: Any) -> Refused:
    """A refusal with the message a person should read, when there is one for it."""
    message = config()["messages"].get(error)
    return Refused(status, {"error": error, **({"problems": [message]} if message else {}), **more})


# ----------------------------------------------------------------------- keys


def names() -> dict[str, str]:
    found: dict[str, str] = config()["keys"]
    return found


def key(partition: str, sort: str) -> dict[str, str]:
    return {os.environ["TABLE_HASH_KEY"]: partition, os.environ["TABLE_RANGE_KEY"]: sort}


def account(subject: str) -> str:
    return names()["account_prefix"] + subject


def firm(firm_id: str) -> str:
    return names()["firm_prefix"] + firm_id


def agreement_key() -> str:
    agreement = config()["agreement"]["agreement"]
    return f"{names()['agreement_prefix']}{agreement['id']}#{agreement['version']}"


def everything_under(partition: str) -> dict[str, Any]:
    """Every item in one partition, as {sort key: its data}."""
    hash_key = os.environ["TABLE_HASH_KEY"]
    found = table().query(
        KeyConditionExpression="#hash = :partition",
        ExpressionAttributeNames={"#hash": hash_key},
        ExpressionAttributeValues={":partition": partition},
    )
    return {item[os.environ["TABLE_RANGE_KEY"]]: item["data"] for item in found.get("Items", [])}


def put(partition: str, sort: str, data: Any, **condition: Any) -> None:
    table().put_item(Item={**key(partition, sort), "data": data, "updated_at": now()}, **condition)


def remove(partition: str, sort: str) -> None:
    table().delete_item(Key=key(partition, sort))


# --------------------------------------------------------------------- person


def claims(event: Event) -> dict[str, str]:
    found: dict[str, str] = event.get("requestContext", {}).get("authorizer", {}).get("jwt", {}).get("claims", {})
    if not found.get("sub"):
        raise Refused(401, {"error": "not_signed_in"})
    return found


def member_of(person: dict[str, str]) -> dict[str, str]:
    """The firm this person belongs to and their role in it: {firmId, role}."""
    found = table().get_item(Key=key(account(person["sub"]), names()["membership"])).get("Item")
    if not found:
        raise refuse(400, "no_firm")
    membership: dict[str, str] = found["data"]
    return membership


def allowed(membership: dict[str, str], permission: str) -> None:
    if membership["role"] not in config()["permissions"][permission]:
        raise refuse(400, "not_allowed")


def record(firm_id: str, person: dict[str, str], what: str, **detail: str) -> None:
    """Adds one line to the firm's change record: who did what, and when."""
    at = now()
    # The record is read back in the order of its keys. Microseconds, then the
    # order within this process, keep two changes made together in sequence;
    # the random part keeps two processes from ever writing the same key.
    moment = datetime.now(UTC).strftime("%Y%m%dT%H%M%S.%f")
    sort = f"{names()['change_prefix']}{moment}#{next(SEQUENCE):06d}#{secrets.token_hex(4)}"
    put(firm(firm_id), sort, {"at": at, "by": person.get("email", ""), "what": what, **detail})


# ----------------------------------------------------------------------- body


def body_of(event: Event) -> dict[str, Any]:
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8", errors="replace")
    if len(raw.encode("utf-8")) > config()["limits"]["max_body_bytes"]:
        raise Refused(400, {"error": "too_large"})
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as error:
        raise Refused(400, {"error": "not_json"}) from error
    if not isinstance(parsed, dict):
        raise Refused(400, {"error": "not_an_object"})
    return parsed


def object_of(body: dict[str, Any], name: str) -> dict[str, Any]:
    value = body.get(name, {})
    if not isinstance(value, dict):
        raise Refused(400, {"error": "not_an_object", "field": name})
    return value


def check(fields: list[dict[str, Any]], values: dict[str, Any]) -> dict[str, str]:
    settings = config()
    return validation.validate_fields(fields, values, settings["messages"], settings["limits"]["max_text_length"])


def checked(fields: list[dict[str, Any]], values: dict[str, Any]) -> dict[str, Any]:
    errors = check(fields, values)
    if errors:
        raise Refused(422, {"error": "invalid", "errors": errors})
    return validation.visible_values(fields, values)


# ------------------------------------------------------------------- sections


def profile_fields(scope: str | None = None) -> list[dict[str, Any]]:
    """The fields of the sign-up steps that describe the person and the firm."""
    return [
        field
        for step in config()["signup"]["steps"]
        if step["profile"] and scope in (None, step["scope"])
        for field in step["fields"]
    ]


def split_profile(values: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    """(the person's own details, the firm's details)."""
    own = {field["id"] for field in profile_fields("person")}
    return (
        {name: value for name, value in values.items() if name in own},
        {name: value for name, value in values.items() if name not in own},
    )


def save_signup(person: dict[str, str], membership: dict[str, str], body: dict[str, Any]) -> dict[str, Any]:
    values = checked(profile_fields(), object_of(body, "values"))
    own, shared = split_profile(values)
    completed = now()
    put(account(person["sub"]), names()["person"], {"values": own})
    put(firm(membership["firmId"]), names()["firm"], {"values": shared, "completedAt": completed})
    return {"values": values, "completedAt": completed}


def save_company(person: dict[str, str], membership: dict[str, str], body: dict[str, Any]) -> dict[str, Any]:
    company = config()["company"]
    fields = [field for section in company["sections"] for field in section["fields"]]
    values = object_of(body, "values")
    errors = check(fields, values)
    problems = []
    if not any(values.get(field_id) is True for field_id in company["fundingIds"]):
        problems.append(config()["messages"]["funding_required"])
    if errors or problems:
        raise Refused(422, {"error": "invalid", "errors": errors, "problems": problems})
    data = {
        "values": validation.visible_values(fields, values),
        "registerVersion": company["registerVersion"],
        "savedAt": now(),
    }
    put(firm(membership["firmId"]), names()["company"], data)
    return data


SECTIONS = {"signup": save_signup, "company": save_company}


# --------------------------------------------------------------------- people


def people_in(items: dict[str, Any]) -> list[dict[str, Any]]:
    prefix = names()["member_prefix"]
    members = [data for sort, data in items.items() if sort.startswith(prefix)]
    owner = config()["firstMemberRole"]
    # Owners first, then in the order people were added.
    return sorted(members, key=lambda member: (member["role"] != owner, member["addedAt"], member["email"]))


def changes_in(items: dict[str, Any]) -> list[dict[str, Any]]:
    prefix = names()["change_prefix"]
    newest_first = sorted((sort for sort in items if sort.startswith(prefix)), reverse=True)
    return [items[sort] for sort in newest_first[: config()["limits"]["max_changes_shown"]]]


def add_member(firm_id: str, subject: str, email: str, role: str, added_by: str) -> None:
    # The firm's own list first: a person the firm lists but who cannot get in
    # is put right by inviting again; the reverse would be access nobody can see.
    member = {"sub": subject, "email": email, "role": role, "addedBy": added_by, "addedAt": now()}
    put(firm(firm_id), names()["member_prefix"] + subject, member)
    put(account(subject), names()["membership"], {"firmId": firm_id, "role": role})


def keep_an_owner(members: list[dict[str, Any]], leaving: dict[str, Any]) -> None:
    """Refuses a change that would leave the firm with no owner."""
    owner = config()["firstMemberRole"]
    if leaving["role"] == owner and sum(member["role"] == owner for member in members) <= 1:
        raise refuse(409, "last_owner")


def invite(person: dict[str, str], firm_id: str, members: list[dict[str, Any]], body: dict[str, Any]) -> None:
    fields = config()["people"]["inviteFields"]
    values = checked(fields, object_of(body, "values"))
    email, role = values[fields[0]["id"]].lower(), values[fields[1]["id"]]
    if len(members) >= config()["limits"]["max_members"]:
        raise refuse(409, "too_many_members")
    try:
        created = directory().admin_create_user(
            UserPoolId=os.environ["USER_POOL_ID"],
            Username=email,
            UserAttributes=[{"Name": "email", "Value": email}, {"Name": "email_verified", "Value": "true"}],
            DesiredDeliveryMediums=["EMAIL"],
        )
    except Exception as error:
        if type(error).__name__ == USERNAME_EXISTS:
            raise refuse(409, "invite_exists") from error
        raise
    subject = next(a["Value"] for a in created["User"]["Attributes"] if a["Name"] == "sub")
    add_member(firm_id, subject, email, role, person.get("email", ""))
    first_person_field = profile_fields("person")
    email_field = next((f["id"] for f in first_person_field if f["type"] == "email"), None)
    if email_field:
        put(account(subject), names()["person"], {"values": {email_field: email}})
    record(firm_id, person, "invited", subject=email, role=role)


def change_role(
    person: dict[str, str], firm_id: str, members: list[dict[str, Any]], target: dict[str, Any], body: dict[str, Any]
) -> None:
    role = body.get("role")
    if role not in config()["roles"]:
        raise Refused(
            422, {"error": "invalid", "errors": {"role": config()["messages"]["option"].replace("{label}", "role")}}
        )
    if role == target["role"]:
        return
    keep_an_owner(members, target)
    put(firm(firm_id), names()["member_prefix"] + target["sub"], {**target, "role": role})
    put(account(target["sub"]), names()["membership"], {"firmId": firm_id, "role": role})
    record(firm_id, person, "role", subject=target["email"], role=role)


def remove_member(person: dict[str, str], firm_id: str, members: list[dict[str, Any]], target: dict[str, Any]) -> None:
    keep_an_owner(members, target)
    # Access first, then the listing, then the sign-in itself.
    remove(account(target["sub"]), names()["membership"])
    remove(firm(firm_id), names()["member_prefix"] + target["sub"])
    remove(account(target["sub"]), names()["person"])
    pool = os.environ["USER_POOL_ID"]
    directory().admin_user_global_sign_out(UserPoolId=pool, Username=target["sub"])
    directory().admin_delete_user(UserPoolId=pool, Username=target["sub"])
    record(firm_id, person, "removed", subject=target["email"])


# ------------------------------------------------------------------- handlers


def guarded(handler: Any) -> Any:
    def run(event: Event, context: Any = None) -> Response:
        try:
            return respond(200, handler(event))
        except Refused as refusal:
            return respond(refusal.status, refusal.body)

    return run


def account_view(person: dict[str, str]) -> dict[str, Any]:
    own = everything_under(account(person["sub"]))
    membership = own.get(names()["membership"])
    if not membership:
        return {"member": None, "signup": None, "company": None, "agreement": None, "people": [], "changes": []}
    shared = everything_under(firm(membership["firmId"]))
    details = shared.get(names()["firm"])
    person_values = own.get(names()["person"], {}).get("values", {})
    return {
        "member": {"role": membership["role"], "sub": person["sub"]},
        "signup": {**details, "values": {**details["values"], **person_values}} if details else None,
        "company": shared.get(names()["company"]),
        "agreement": shared.get(agreement_key()),
        "people": people_in(shared),
        "changes": changes_in(shared),
    }


@guarded
def read(event: Event) -> dict[str, Any]:
    return account_view(claims(event))


@guarded
def enrol(event: Event) -> dict[str, Any]:
    """Gives a signed-in person with no firm a firm of their own, as its first owner.

    Anything they saved before firms existed is moved into it.
    """
    person = claims(event)
    own = everything_under(account(person["sub"]))
    if names()["membership"] in own:
        return {"member": own[names()["membership"]]}

    firm_id = str(uuid.uuid4())
    role = config()["firstMemberRole"]
    add_member(firm_id, person["sub"], person.get("email", ""), role, person.get("email", ""))
    record(firm_id, person, "created")

    earlier = own.get(names()["legacy_signup"])
    if earlier:
        mine, shared = split_profile(earlier.get("values", {}))
        put(account(person["sub"]), names()["person"], {"values": mine})
        put(firm(firm_id), names()["firm"], {"values": shared, "completedAt": earlier.get("completedAt", now())})
        remove(account(person["sub"]), names()["legacy_signup"])
    for sort, data in own.items():
        if sort == names()["company"]:
            put(firm(firm_id), sort, {name: value for name, value in data.items() if name != "feeEarners"})
            remove(account(person["sub"]), sort)
        elif sort.startswith(names()["agreement_prefix"]):
            put(firm(firm_id), sort, data)
            remove(account(person["sub"]), sort)
    return {"member": {"firmId": firm_id, "role": role}}


@guarded
def write(event: Event) -> dict[str, Any]:
    person = claims(event)
    section = (event.get("pathParameters") or {}).get(SECTION_PARAMETER, "")
    if section not in SECTIONS:
        raise Refused(400, {"error": "unknown_section"})
    membership = member_of(person)
    allowed(membership, "write")
    data = SECTIONS[section](person, membership, body_of(event))
    record(membership["firmId"], person, section)
    return {section: data}


@guarded
def accept(event: Event) -> dict[str, Any]:
    person = claims(event)
    membership = member_of(person)
    allowed(membership, "accept")
    settings = config()["agreement"]
    values = checked(settings["fields"], object_of(body_of(event), "values"))
    agreement = settings["agreement"]
    data = {
        "id": agreement["id"],
        "version": agreement["version"],
        "acceptedBy": values[settings["fields"][0]["id"]],
        "acceptedByEmail": person.get("email", ""),
        "acceptedAt": now(),
    }
    try:
        # Written once: an acceptance is a record, and a record is not rewritten.
        put(
            firm(membership["firmId"]),
            agreement_key(),
            data,
            ConditionExpression="attribute_not_exists(#hash)",
            ExpressionAttributeNames={"#hash": os.environ["TABLE_HASH_KEY"]},
        )
    except Exception as error:
        if type(error).__name__ == CONDITION_FAILED:
            raise Refused(409, {"error": "already_accepted"}) from error
        raise
    record(membership["firmId"], person, "agreement")
    return {"agreement": data}


@guarded
def people(event: Event) -> dict[str, Any]:
    person = claims(event)
    membership = member_of(person)
    allowed(membership, "people")
    firm_id = membership["firmId"]
    members = people_in(everything_under(firm(firm_id)))
    method = event.get("requestContext", {}).get("http", {}).get("method", "")

    if method == "POST":
        invite(person, firm_id, members, body_of(event))
    else:
        wanted = (event.get("pathParameters") or {}).get(MEMBER_PARAMETER, "")
        target = next((member for member in members if member["sub"] == wanted), None)
        if target is None:
            raise Refused(400, {"error": "unknown_member"})
        if method == "PUT":
            change_role(person, firm_id, members, target, body_of(event))
        elif method == "DELETE":
            remove_member(person, firm_id, members, target)
        else:
            raise Refused(400, {"error": "unknown_method"})

    shared = everything_under(firm(firm_id))
    return {"people": people_in(shared), "changes": changes_in(shared)}
