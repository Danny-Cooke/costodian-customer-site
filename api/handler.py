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
    catalogue  (no route)                          add a newly tagged version to those on offer

Each customer has a table and a key of its own, made in advance and numbered.
A person's sign-in carries their customer number, which only this API can set.
For every request the function takes short-lived credentials that reach that
one customer's table and nothing else. Each customer number also has a small
label kept as a parameter: who the customer is and how far they have got.

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
import re
import secrets
import time
from datetime import UTC, date, datetime
from decimal import Decimal
from functools import cache
from pathlib import Path
from typing import Any

import validation

CONFIG_PATH = Path(os.environ.get("API_CONFIG", Path(__file__).with_name("config.json")))
SECTION_PARAMETER = "section"
MEMBER_PARAMETER = "member"
USERNAME_EXISTS = "UsernameExistsException"
USER_NOT_FOUND = "UserNotFoundException"
CONDITION_FAILED = "ConditionalCheckFailedException"
NUMBER_PLACEHOLDER = "{number}"
CUSTOMER_NUMBER = re.compile(r"^[0-9]{1,12}$")
SESSION_SECONDS = 900
SESSION_MARGIN_SECONDS = 60
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


def now() -> str:
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def today() -> date:
    return datetime.now(UTC).date()


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


def names() -> dict[str, str]:
    found: dict[str, str] = config()["keys"]
    return found


# ------------------------------------------------------------- AWS services


@cache
def directory() -> Any:
    """The sign-in service: who a person is, and inviting and removing people."""
    import boto3

    return boto3.client("cognito-idp")


@cache
def parameters() -> Any:
    """Where each customer number's label is kept."""
    import boto3

    return boto3.client("ssm")


@cache
def tokens() -> Any:
    import boto3

    return boto3.client("sts")


@cache
def registry() -> Any:
    """Every UID ever issued, so that none is issued twice. Holds no customer data."""
    import boto3

    return boto3.resource("dynamodb").Table(os.environ["REGISTRY_TABLE_NAME"])


def for_customer(template_variable: str, number: str) -> str:
    return os.environ[template_variable].replace(NUMBER_PLACEHOLDER, number)


def session_policy(number: str) -> dict[str, Any]:
    """What one request may touch: this customer's table, through this customer's key."""
    return {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": [action for action in os.environ["DATA_ACTIONS"].split(",") if action],
                "Resource": for_customer("CUSTOMER_TABLE_ARN_TEMPLATE", number),
            },
            {
                "Effect": "Allow",
                "Action": ["kms:Decrypt", "kms:GenerateDataKey"],
                "Resource": "*",
                "Condition": {
                    "ForAnyValue:StringEquals": {
                        "kms:ResourceAliases": for_customer("CUSTOMER_KEY_ALIAS_TEMPLATE", number)
                    }
                },
            },
        ],
    }


_stores: dict[str, tuple[float, Any]] = {}


def store(number: str) -> Any:
    """One customer's table, reached with credentials that can reach no other customer's."""
    if not CUSTOMER_NUMBER.fullmatch(number):
        raise Refused(400, {"error": "unknown_customer"})
    held = _stores.get(number)
    if held and held[0] > time.time():
        return held[1]

    import boto3

    granted = tokens().assume_role(
        RoleArn=os.environ["DATA_ROLE_ARN"],
        RoleSessionName=f"customer-{number}",
        Policy=json.dumps(session_policy(number)),
        DurationSeconds=SESSION_SECONDS,
    )["Credentials"]
    table = boto3.resource(
        "dynamodb",
        aws_access_key_id=granted["AccessKeyId"],
        aws_secret_access_key=granted["SecretAccessKey"],
        aws_session_token=granted["SessionToken"],
    ).Table(for_customer("CUSTOMER_TABLE_NAME_TEMPLATE", number))
    _stores[number] = (time.time() + SESSION_SECONDS - SESSION_MARGIN_SECONDS, table)
    return table


# ----------------------------------------------------------------- one table


def key(partition: str, sort: str) -> dict[str, str]:
    return {os.environ["TABLE_HASH_KEY"]: partition, os.environ["TABLE_RANGE_KEY"]: sort}


def person_partition(subject: str) -> str:
    return names()["person_prefix"] + subject


def agreement_key() -> str:
    agreement = config()["agreement"]["agreement"]
    return f"{names()['agreement_prefix']}{agreement['id']}#{agreement['version']}"


def everything_under(table: Any, partition: str) -> dict[str, Any]:
    """Every item in one partition of a table, as {sort key: its data}."""
    found = table.query(
        KeyConditionExpression="#hash = :partition",
        ExpressionAttributeNames={"#hash": os.environ["TABLE_HASH_KEY"]},
        ExpressionAttributeValues={":partition": partition},
    )
    return {item[os.environ["TABLE_RANGE_KEY"]]: item["data"] for item in found.get("Items", [])}


def one(table: Any, partition: str, sort: str) -> Any:
    found = table.get_item(Key=key(partition, sort)).get("Item")
    return found["data"] if found else None


def put(table: Any, partition: str, sort: str, data: Any, **condition: Any) -> None:
    table.put_item(Item={**key(partition, sort), "data": data, "updated_at": now()}, **condition)


def put_once(table: Any, partition: str, sort: str, data: Any) -> bool:
    """Writes an item only if it is not there yet. False means it already was."""
    try:
        put(
            table,
            partition,
            sort,
            data,
            ConditionExpression="attribute_not_exists(#hash)",
            ExpressionAttributeNames={"#hash": os.environ["TABLE_HASH_KEY"]},
        )
    except Exception as error:
        if type(error).__name__ == CONDITION_FAILED:
            return False
        raise
    return True


def remove(table: Any, partition: str, sort: str) -> None:
    table.delete_item(Key=key(partition, sort))


# --------------------------------------------------------- customer labels


def label_name(number: str) -> str:
    return f"{os.environ['CUSTOMER_PARAMETER_PATH'].rstrip('/')}/{number}"


def read_label(number: str) -> dict[str, Any]:
    raw = parameters().get_parameter(Name=label_name(number))["Parameter"]["Value"]
    found: dict[str, Any] = json.loads(raw)
    return found


def delete_after(left_on: str | None, last_case_completed_on: str | None) -> str | None:
    """The day a customer's records may go.

    Never while they are a customer. Once they have left: the retention period
    after their last case was finished, or after they left if they never
    finished one.
    """
    if not left_on:
        return None
    counted_from = date.fromisoformat(last_case_completed_on or left_on)
    years = config()["retention"]["years"]
    try:
        return counted_from.replace(year=counted_from.year + years).isoformat()
    except ValueError:  # 29 February, in a year that has none
        return counted_from.replace(year=counted_from.year + years, day=28).isoformat()


def write_label(number: str, **changes: Any) -> dict[str, Any]:
    """Updates a customer's label, and writes it only when something has changed."""
    before = read_label(number)
    if before.get("status") in config()["customerStatusesHeld"]:
        # A customer who is dormant or has left stays so, whatever is saved
        # after: only an operator moves a customer into or out of those.
        changes.pop("status", None)
    after = {**before, **changes, "customer": number}
    after["delete_after"] = delete_after(after.get("left_on"), after.get("last_case_completed_on"))
    if after != before:
        parameters().put_parameter(
            Name=label_name(number), Value=json.dumps(after, sort_keys=True), Type="String", Overwrite=True
        )
    return after


def free_numbers() -> list[str]:
    """Customer numbers nobody has taken yet, lowest first."""
    free = os.environ["CUSTOMER_FREE_STATUS"]
    path = os.environ["CUSTOMER_PARAMETER_PATH"]
    found: list[str] = []
    request: dict[str, Any] = {"Path": path, "Recursive": False}
    while True:
        page = parameters().get_parameters_by_path(**request)
        for parameter in page.get("Parameters", []):
            number = parameter["Name"].rsplit("/", 1)[-1]
            try:
                status = json.loads(parameter["Value"]).get("status")
            except (ValueError, AttributeError):
                continue
            if status == free and CUSTOMER_NUMBER.fullmatch(number):
                found.append(number)
        if not page.get("NextToken"):
            return sorted(found)
        request["NextToken"] = page["NextToken"]


def describe(number: str, table: Any, items: dict[str, Any] | None = None) -> None:
    """Brings the customer's label up to date with what the firm has saved."""
    statuses = config()["customerStatuses"]
    shared = items if items is not None else everything_under(table, names()["firm_partition"])
    account = shared.get(names()["firm"], {}).get("account", {})
    answers = shared.get(names()["company"], {}).get("values", {})
    done = all(sort in shared for sort in (names()["firm"], names()["company"], agreement_key()))
    label = {
        **{name: account.get(field) or None for name, field in config()["customerLabel"].items()},
        **{name: answers.get(field) or None for name, field in config()["customerLabelAnswers"].items()},
    }
    write_label(number, status=statuses["complete"] if done else statuses["signed_up"], **label)


# --------------------------------------------------------------------- person


def claims(event: Event) -> dict[str, str]:
    found: dict[str, str] = event.get("requestContext", {}).get("authorizer", {}).get("jwt", {}).get("claims", {})
    if not found.get("sub"):
        raise Refused(401, {"error": "not_signed_in"})
    return found


def customer_of(person: dict[str, str]) -> str | None:
    """The customer number the sign-in service put in this person's token, if any."""
    number = person.get(os.environ["CUSTOMER_ATTRIBUTE"])
    return number if number and CUSTOMER_NUMBER.fullmatch(number) else None


class Membership:
    """A signed-in person in their firm: which customer, which table, which role."""

    def __init__(self, number: str, table: Any, member: dict[str, Any]) -> None:
        self.number = number
        self.table = table
        self.role: str = member["role"]


def member_of(person: dict[str, str]) -> Membership:
    number = customer_of(person)
    if number is None:
        raise refuse(400, "no_firm")
    table = store(number)
    member = one(table, names()["firm_partition"], names()["member_prefix"] + person["sub"])
    if member is None:
        raise refuse(400, "no_firm")
    return Membership(number, table, member)


def allowed(membership: Membership, permission: str) -> None:
    if membership.role not in config()["permissions"][permission]:
        raise refuse(400, "not_allowed")


def record(table: Any, person: dict[str, str], what: str, **detail: str) -> None:
    """Adds one line to the firm's change record: who did what, and when."""
    at = now()
    # The record is read back in the order of its keys. Microseconds, then the
    # order within this process, keep two changes made together in sequence;
    # the random part keeps two processes from ever writing the same key.
    moment = datetime.now(UTC).strftime("%Y%m%dT%H%M%S.%f")
    sort = f"{names()['change_prefix']}{moment}#{next(SEQUENCE):06d}#{secrets.token_hex(4)}"
    put(table, names()["firm_partition"], sort, {"at": at, "by": person.get("email", ""), "what": what, **detail})


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


def person_fields() -> list[dict[str, Any]]:
    """The questions about the person signing up, whatever kind of account it is."""
    return [
        field
        for step in config()["signup"]["steps"]
        if step["profile"] and step["scope"] == "person"
        for field in step["fields"]
    ]


def account_type_field() -> dict[str, Any]:
    wanted = config()["identity"]["account_type_field"]
    return next(field for step in config()["signup"]["steps"] for field in step["fields"] if field["id"] == wanted)


def kind_of(values: dict[str, Any]) -> dict[str, Any]:
    """The kind of account chosen, with its own questions. Refuses a kind that is not one of ours."""
    field = account_type_field()
    chosen = values.get(field["id"])
    for kind in config()["signup"]["types"]:
        if kind["id"] == chosen:
            found: dict[str, Any] = kind
            return found
    raise Refused(422, {"error": "invalid", "errors": {field["id"]: config()["messages"]["account_type_unknown"]}})


def slug_of(name: str) -> str | None:
    """A name cut down to what is safe inside the name of a resource: a-z, 0-9 and hyphens."""
    limit = config()["account"]["slug_max_length"]
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:limit].strip("-")
    return slug or None


def account_of(kind: dict[str, Any], answers: dict[str, Any]) -> dict[str, Any]:
    """The same few facts about every customer, whichever sign-up they came through.

    A registered company name, an LLP's name, a partnership's name and a
    draftsman's own name all become `name`. Whatever creates the customer's
    account reads these and never needs to know which questions were asked.
    """
    identity = config()["identity"]
    settings = config()["account"]
    name = answers.get(identity["firm_name_field"])
    trading = answers.get(identity["trading_name_field"]) or None
    spoken = next((answers[field] for field in settings["slug_from"] if answers.get(field)), "")
    number_field = kind["regulator_number_field"]
    number = answers.get(number_field) if number_field else None
    return {
        "type": kind["id"],
        "portal": kind["portal"],
        "regulator": kind["regulator"],
        "legal_form": kind["legal_form"] or answers.get(kind["legal_form_field"]),
        "name": name,
        "trading_name": trading,
        "slug": slug_of(spoken),
        "regulator_number": number.replace(" ", "").upper() if isinstance(number, str) else None,
        "company_number": answers.get(settings["company_number_field"]) or None,
    }


def save_signup(person: dict[str, str], membership: Membership, body: dict[str, Any]) -> dict[str, Any]:
    values = object_of(body, "values")
    kind = kind_of(values)
    own_fields = person_fields()
    shared_fields = [account_type_field(), *kind["fields"]]
    kept = checked([*own_fields, *shared_fields], values)
    own_ids = {field["id"] for field in own_fields}
    own = {name: value for name, value in kept.items() if name in own_ids}
    shared = {name: value for name, value in kept.items() if name not in own_ids}
    completed = now()
    put(membership.table, person_partition(person["sub"]), names()["person"], {"values": own})
    put(
        membership.table,
        names()["firm_partition"],
        names()["firm"],
        {"values": shared, "account": account_of(kind, shared), "completedAt": completed},
    )
    return {"values": kept, "completedAt": completed}


def version_order(version: str) -> tuple[int, ...]:
    """v1.10 comes after v1.9: versions are ordered by their numbers, not as text."""
    return tuple(int(part) for part in re.findall(r"[0-9]+", version))


def versions() -> list[str]:
    """The versions a firm may run, oldest first. A new one appears when its tag is made."""
    held = json.loads(parameters().get_parameter(Name=os.environ["VERSIONS_PARAMETER"])["Parameter"]["Value"])
    return sorted((version for version in held if isinstance(version, str)), key=version_order)


def save_company(person: dict[str, str], membership: Membership, body: dict[str, Any]) -> dict[str, Any]:
    company = config()["company"]
    version_field = company["versionField"]
    on_offer = [{"value": version, "label": version} for version in versions()]
    fields = [
        {**field, "options": on_offer} if field["id"] == version_field else field
        for section in company["sections"]
        for field in section["fields"]
    ]
    values = object_of(body, "values")
    errors = check(fields, values)
    problems = []
    if not any(values.get(field_id) is True for field_id in company["fundingIds"]):
        problems.append(config()["messages"]["funding_required"])

    before = one(membership.table, names()["firm_partition"], names()["company"]) or {}
    current = before.get("values", {}).get(version_field)
    chosen = values.get(version_field)
    if current and version_field not in errors and version_order(str(chosen)) < version_order(current):
        # A firm moves forward to a newer version; it is not moved back.
        errors[version_field] = config()["messages"]["version_older"]
    if errors or problems:
        raise Refused(422, {"error": "invalid", "errors": errors, "problems": problems})

    data = {"values": validation.visible_values(fields, values), "savedAt": now()}
    put(membership.table, names()["firm_partition"], names()["company"], data)
    if chosen != current:
        record(membership.table, person, "version", subject=str(chosen))
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


def add_member(table: Any, subject: str, email: str, role: str, added_by: str) -> None:
    member = {"sub": subject, "email": email, "role": role, "addedBy": added_by, "addedAt": now()}
    put(table, names()["firm_partition"], names()["member_prefix"] + subject, member)


def attach(subject: str, number: str) -> None:
    """Tells the sign-in service which customer a person belongs to."""
    directory().admin_update_user_attributes(
        UserPoolId=os.environ["USER_POOL_ID"],
        Username=subject,
        UserAttributes=[{"Name": os.environ["CUSTOMER_ATTRIBUTE"], "Value": number}],
    )


def keep_an_owner(members: list[dict[str, Any]], leaving: dict[str, Any]) -> None:
    """Refuses a change that would leave the firm with no owner."""
    owner = config()["firstMemberRole"]
    if leaving["role"] == owner and sum(member["role"] == owner for member in members) <= 1:
        raise refuse(409, "last_owner")


def invite(person: dict[str, str], membership: Membership, members: list[dict[str, Any]], body: dict[str, Any]) -> None:
    fields = config()["people"]["inviteFields"]
    values = checked(fields, object_of(body, "values"))
    email, role = values[fields[0]["id"]].lower(), values[fields[1]["id"]]
    if len(members) >= config()["limits"]["max_members"]:
        raise refuse(409, "too_many_members")
    try:
        created = directory().admin_create_user(
            UserPoolId=os.environ["USER_POOL_ID"],
            Username=email,
            UserAttributes=[
                {"Name": "email", "Value": email},
                {"Name": "email_verified", "Value": "true"},
                {"Name": os.environ["CUSTOMER_ATTRIBUTE"], "Value": membership.number},
            ],
            DesiredDeliveryMediums=["EMAIL"],
        )
    except Exception as error:
        if type(error).__name__ == USERNAME_EXISTS:
            raise refuse(409, "invite_exists") from error
        raise
    subject = next(a["Value"] for a in created["User"]["Attributes"] if a["Name"] == "sub")
    add_member(membership.table, subject, email, role, person.get("email", ""))
    email_field = next((field["id"] for field in person_fields() if field["type"] == "email"), None)
    if email_field:
        put(membership.table, person_partition(subject), names()["person"], {"values": {email_field: email}})
    record(membership.table, person, "invited", subject=email, role=role)


def change_role(
    person: dict[str, str],
    membership: Membership,
    members: list[dict[str, Any]],
    target: dict[str, Any],
    body: dict[str, Any],
) -> None:
    role = body.get("role")
    if role not in config()["roles"]:
        problem = config()["messages"]["option"].replace("{label}", "role")
        raise Refused(422, {"error": "invalid", "errors": {"role": problem}})
    if role == target["role"]:
        return
    keep_an_owner(members, target)
    put(membership.table, names()["firm_partition"], names()["member_prefix"] + target["sub"], {**target, "role": role})
    record(membership.table, person, "role", subject=target["email"], role=role)


def remove_member(
    person: dict[str, str], membership: Membership, members: list[dict[str, Any]], target: dict[str, Any]
) -> None:
    keep_an_owner(members, target)
    # Access first, then their own details, then the sign-in itself.
    remove(membership.table, names()["firm_partition"], names()["member_prefix"] + target["sub"])
    remove(membership.table, person_partition(target["sub"]), names()["person"])
    pool = os.environ["USER_POOL_ID"]
    directory().admin_user_global_sign_out(UserPoolId=pool, Username=target["sub"])
    directory().admin_delete_user(UserPoolId=pool, Username=target["sub"])
    record(membership.table, person, "removed", subject=target["email"])


# ------------------------------------------------------------------ enrolling


def claim_a_number(person: dict[str, str]) -> tuple[str, Any]:
    """Takes the lowest free customer number. Two people can never take the same one."""
    for number in free_numbers():
        table = store(number)
        claim = {"by": person["sub"], "at": now()}
        if put_once(table, names()["firm_partition"], names()["claim"], claim):
            return number, table
    raise refuse(409, "no_capacity")


def issue_uid(number: str) -> str:
    """A new UID for a customer: random, and unlike any issued before.

    A UID is claimed by a write to the registry that succeeds only if the UID
    is not there, so two customers can never be given the same one. On the rare
    occasion the number picked is taken, another is picked.
    """
    settings = config()["uid"]
    lowest = 10 ** (settings["digits"] - 1)
    entry = {"customer": number, "status": settings["issued"], "issuedOn": today().isoformat()}
    for _ in range(settings["attempts"]):
        uid = str(lowest + secrets.randbelow(9 * lowest))
        keys = config()["registryKeys"]
        if put_once(registry(), keys["uid_prefix"] + uid, keys["entry"], entry):
            return uid
    raise refuse(409, "no_capacity")


def uid_of(number: str, table: Any) -> str:
    """The customer's UID, issued now if they have none. It never changes once issued."""
    held = one(table, names()["firm_partition"], names()["uid"])
    if held is None:
        issued = {"uid": issue_uid(number), "issuedOn": today().isoformat()}
        # Written once: if two requests issue one each, the first to be written
        # is the customer's UID and the other is left unused in the registry.
        held = (
            issued
            if put_once(table, names()["firm_partition"], names()["uid"], issued)
            else one(table, names()["firm_partition"], names()["uid"])
        )
    write_label(number, uid=held["uid"])
    found: str = held["uid"]
    return found


def number_on_record(person: dict[str, str]) -> str | None:
    """The customer number the sign-in service holds, which a token issued earlier may not show."""
    try:
        user = directory().admin_get_user(UserPoolId=os.environ["USER_POOL_ID"], Username=person["sub"])
    except Exception as error:
        if type(error).__name__ == USER_NOT_FOUND:
            raise Refused(401, {"error": "not_signed_in"}) from error
        raise
    attribute = os.environ["CUSTOMER_ATTRIBUTE"]
    held = next((a["Value"] for a in user.get("UserAttributes", []) if a["Name"] == attribute), None)
    return held if held and CUSTOMER_NUMBER.fullmatch(held) else None


# ------------------------------------------------------------------- handlers


def guarded(handler: Any) -> Any:
    def run(event: Event, context: Any = None) -> Response:
        try:
            return respond(200, handler(event))
        except Refused as refusal:
            return respond(refusal.status, refusal.body)

    return run


NOBODY: dict[str, Any] = {
    "member": None,
    "signup": None,
    "company": None,
    "agreement": None,
    "people": [],
    "changes": [],
    "uid": None,
}


def account_view(person: dict[str, str]) -> dict[str, Any]:
    number = customer_of(person)
    if number is None:
        return {**NOBODY, "versions": versions()}
    table = store(number)
    shared = everything_under(table, names()["firm_partition"])
    member = shared.get(names()["member_prefix"] + person["sub"])
    if member is None:
        return {**NOBODY, "versions": versions()}
    details = shared.get(names()["firm"])
    own = one(table, person_partition(person["sub"]), names()["person"]) or {}
    return {
        "member": {"role": member["role"], "sub": person["sub"]},
        "signup": {**details, "values": {**details["values"], **own.get("values", {})}} if details else None,
        "company": shared.get(names()["company"]),
        "agreement": shared.get(agreement_key()),
        "people": people_in(shared),
        "changes": changes_in(shared),
        "versions": versions(),
        "uid": shared.get(names()["uid"], {}).get("uid"),
    }


@guarded
def read(event: Event) -> dict[str, Any]:
    return account_view(claims(event))


@guarded
def enrol(event: Event) -> dict[str, Any]:
    """Gives a signed-in person with no firm a customer number, as its first owner.

    The answer says whether the browser must renew its token: the customer
    number is carried in the token, and a token issued before this call does
    not have it.
    """
    person = claims(event)
    if customer_of(person):
        # Already a member. A customer from before UIDs were issued is given one.
        membership = member_of(person)
        uid_of(membership.number, membership.table)
        return {"member": {"role": membership.role}, "renew": False}

    held = number_on_record(person)
    if held:
        # Already attached; only this token is out of date. A person the firm
        # has since removed is not given another firm.
        member = one(store(held), names()["firm_partition"], names()["member_prefix"] + person["sub"])
        if member is None:
            raise refuse(400, "no_firm")
        uid_of(held, store(held))
        return {"member": {"role": member["role"]}, "renew": True}

    number, table = claim_a_number(person)
    statuses = config()["customerStatuses"]
    write_label(number, status=statuses["signed_up"], signed_up_on=today().isoformat())
    uid_of(number, table)
    role = config()["firstMemberRole"]
    add_member(table, person["sub"], person.get("email", ""), role, person.get("email", ""))
    attach(person["sub"], number)
    record(table, person, "created")
    return {"member": {"role": role}, "renew": True}


@guarded
def write(event: Event) -> dict[str, Any]:
    person = claims(event)
    section = (event.get("pathParameters") or {}).get(SECTION_PARAMETER, "")
    if section not in SECTIONS:
        raise Refused(400, {"error": "unknown_section"})
    membership = member_of(person)
    allowed(membership, "write")
    data = SECTIONS[section](person, membership, body_of(event))
    record(membership.table, person, section)
    describe(membership.number, membership.table)
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
    # Written once: an acceptance is a record, and a record is not rewritten.
    if not put_once(membership.table, names()["firm_partition"], agreement_key(), data):
        raise Refused(409, {"error": "already_accepted"})
    record(membership.table, person, "agreement")
    describe(membership.number, membership.table)
    return {"agreement": data}


@guarded
def people(event: Event) -> dict[str, Any]:
    person = claims(event)
    membership = member_of(person)
    allowed(membership, "people")
    members = people_in(everything_under(membership.table, names()["firm_partition"]))
    method = event.get("requestContext", {}).get("http", {}).get("method", "")

    if method == "POST":
        invite(person, membership, members, body_of(event))
    else:
        wanted = (event.get("pathParameters") or {}).get(MEMBER_PARAMETER, "")
        target = next((member for member in members if member["sub"] == wanted), None)
        if target is None:
            raise Refused(400, {"error": "unknown_member"})
        if method == "PUT":
            change_role(person, membership, members, target, body_of(event))
        elif method == "DELETE":
            remove_member(person, membership, members, target)
        else:
            raise Refused(400, {"error": "unknown_method"})

    shared = everything_under(membership.table, names()["firm_partition"])
    return {"people": people_in(shared), "changes": changes_in(shared)}


def catalogue(event: Event, context: Any = None) -> dict[str, Any]:
    """Adds a newly tagged version to the ones firms can choose.

    Not part of the web API: it runs when a tag is made in the repository that
    holds each customer account's set-up, so tagging a release is all it takes
    to offer it.
    """
    detail = event.get("detail", {})
    tag = str(detail.get("referenceName", ""))
    held = versions()
    is_a_version = detail.get("referenceType") == "tag" and re.fullmatch(os.environ["VERSION_TAG_PATTERN"], tag)
    if is_a_version and tag not in held:
        held = sorted([*held, tag], key=version_order)
        parameters().put_parameter(
            Name=os.environ["VERSIONS_PARAMETER"], Value=json.dumps(held), Type="String", Overwrite=True
        )
    return {"versions": held}
