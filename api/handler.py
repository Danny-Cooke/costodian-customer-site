"""The account API: what a signed-in person's firm has entered, read and saved.

Three entry points, one per Lambda function, so that each runs under a role that
can do only its own job:

    read    GET  <base>/account             everything saved for this account
    write   PUT  <base>/account/{section}   save one section (signup, company)
    accept  POST <base>/account/agreement   record acceptance of the agreement, once

API Gateway has already checked the token; the person is the token's subject.
Nothing a person submits is ever logged.
"""

from __future__ import annotations

import base64
import json
import os
from datetime import UTC, datetime
from decimal import Decimal
from functools import cache
from pathlib import Path
from typing import Any

import validation

CONFIG_PATH = Path(os.environ.get("API_CONFIG", Path(__file__).with_name("config.json")))
SECTION_PARAMETER = "section"

Event = dict[str, Any]
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


def claims(event: Event) -> dict[str, str]:
    found: dict[str, str] = event.get("requestContext", {}).get("authorizer", {}).get("jwt", {}).get("claims", {})
    if not found.get("sub"):
        raise Refused(401, {"error": "not_signed_in"})
    return found


def keys(subject: str, section: str) -> dict[str, str]:
    names = config()["keys"]
    return {
        os.environ["TABLE_HASH_KEY"]: names["account_prefix"] + subject,
        os.environ["TABLE_RANGE_KEY"]: section,
    }


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


def object_of(body: dict[str, Any], key: str) -> dict[str, Any]:
    value = body.get(key, {})
    if not isinstance(value, dict):
        raise Refused(400, {"error": "not_an_object", "field": key})
    return value


def check(fields: list[dict[str, Any]], values: dict[str, Any]) -> dict[str, str]:
    settings = config()
    return validation.validate_fields(fields, values, settings["messages"], settings["limits"]["max_text_length"])


# ------------------------------------------------------------------ sections


def signup_section(body: dict[str, Any]) -> dict[str, Any]:
    fields = [field for step in config()["signup"]["steps"] if step["profile"] for field in step["fields"]]
    values = object_of(body, "values")
    errors = check(fields, values)
    if errors:
        raise Refused(422, {"error": "invalid", "errors": errors})
    return {"values": validation.visible_values(fields, values), "completedAt": now()}


def company_section(body: dict[str, Any]) -> dict[str, Any]:
    settings = config()
    company = settings["company"]
    messages = settings["messages"]
    fields = [field for section in company["sections"] for field in section["fields"]]
    values = object_of(body, "values")
    errors = check(fields, values)
    problems = []

    if not any(values.get(field_id) is True for field_id in company["fundingIds"]):
        problems.append(messages["funding_required"])

    rows = body.get("feeEarners", [])
    if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
        raise Refused(400, {"error": "not_a_list", "field": "feeEarners"})
    if not rows:
        problems.append(messages["fee_earner_required"])
    if len(rows) > company["maxFeeEarners"]:
        problems.append(messages["too_many_rows"])
        rows = []
    earner_fields = company["feeEarners"]["fields"]
    row_errors = [check(earner_fields, row) for row in rows]

    if errors or problems or any(row_errors):
        raise Refused(422, {"error": "invalid", "errors": errors, "problems": problems, "rowErrors": row_errors})
    return {
        "values": validation.visible_values(fields, values),
        "feeEarners": [validation.visible_values(earner_fields, row) for row in rows],
        "registerVersion": company["registerVersion"],
        "savedAt": now(),
    }


SECTIONS = {"signup": signup_section, "company": company_section}


def agreement_key() -> str:
    agreement = config()["agreement"]["agreement"]
    return f"{config()['keys']['agreement_prefix']}{agreement['id']}#{agreement['version']}"


# ------------------------------------------------------------------- handlers


def guarded(handler: Any) -> Any:
    def run(event: Event, context: Any = None) -> Response:
        try:
            return respond(200, handler(event))
        except Refused as refusal:
            return respond(refusal.status, refusal.body)

    return run


@guarded
def read(event: Event) -> dict[str, Any]:
    from boto3.dynamodb.conditions import Key

    subject = claims(event)["sub"]
    hash_key = os.environ["TABLE_HASH_KEY"]
    found = table().query(KeyConditionExpression=Key(hash_key).eq(keys(subject, "")[hash_key]))
    by_section = {item[os.environ["TABLE_RANGE_KEY"]]: item["data"] for item in found.get("Items", [])}
    return {
        "signup": by_section.get("signup"),
        "company": by_section.get("company"),
        "agreement": by_section.get(agreement_key()),
    }


@guarded
def write(event: Event) -> dict[str, Any]:
    person = claims(event)
    section = (event.get("pathParameters") or {}).get(SECTION_PARAMETER, "")
    if section not in SECTIONS:
        raise Refused(400, {"error": "unknown_section"})
    data = SECTIONS[section](body_of(event))
    table().put_item(Item={**keys(person["sub"], section), "data": data, "updated_at": now()})
    return {section: data}


@guarded
def accept(event: Event) -> dict[str, Any]:
    person = claims(event)
    settings = config()["agreement"]
    values = object_of(body_of(event), "values")
    errors = check(settings["fields"], values)
    if errors:
        raise Refused(422, {"error": "invalid", "errors": errors})
    agreement = settings["agreement"]
    data = {
        "id": agreement["id"],
        "version": agreement["version"],
        "acceptedBy": values[settings["fields"][0]["id"]],
        "acceptedAt": now(),
    }
    item = {**keys(person["sub"], agreement_key()), "data": data, "updated_at": data["acceptedAt"]}
    try:
        # Written once: an acceptance is a record, and a record is not rewritten.
        table().put_item(
            Item=item,
            ConditionExpression="attribute_not_exists(#hash)",
            ExpressionAttributeNames={"#hash": os.environ["TABLE_HASH_KEY"]},
        )
    except Exception as error:
        if type(error).__name__ == "ConditionalCheckFailedException":
            raise Refused(409, {"error": "already_accepted"}) from error
        raise
    return {"agreement": data}
