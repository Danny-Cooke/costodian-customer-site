import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import {
  displayValue,
  isVisible,
  validateField,
  validateFields,
  visibleValues,
} from "../../site/static/js/validate.js";

const forms = JSON.parse(readFileSync(new URL("../../site/config/forms.json", import.meta.url), "utf8"));
const messages = forms.messages;
const pattern = (name) => forms.formats[name].pattern;
const matches = (name, value) => new RegExp(pattern(name)).test(value);

test("a field with no condition is always on show", () => {
  assert.equal(isVisible({ id: "a" }, {}), true);
});

test("a condition on one value or on a list of values decides whether a field is on show", () => {
  const equals = { id: "a", show_if: { field: "same", equals: false } };
  assert.equal(isVisible(equals, { same: false }), true);
  assert.equal(isVisible(equals, { same: true }), false);
  const oneOf = { id: "b", show_if: { field: "type", in: ["llp", "limited"] } };
  assert.equal(isVisible(oneOf, { type: "llp" }), true);
  assert.equal(isVisible(oneOf, { type: "partnership" }), false);
});

test("a required field that is empty is reported with its label", () => {
  const field = { id: "n", label: "full name", type: "text", required: true };
  assert.equal(validateField(field, { n: "" }, messages), "Enter full name");
  assert.equal(validateField(field, { n: "Sam" }, messages), null);
});

test("an optional field that is empty passes, whatever its pattern", () => {
  const field = { id: "s", label: "x", type: "text", required: false, pattern: "^[0-9]+$" };
  assert.equal(validateField(field, { s: "" }, messages), null);
});

test("a required tick box and a required choice have their own wording", () => {
  const tick = { id: "t", label: "x", type: "checkbox", required: true };
  assert.equal(validateField(tick, { t: false }, messages), messages.required_tick);
  assert.equal(validateField(tick, { t: true }, messages), null);
  const choice = { id: "c", label: "office region", type: "radio", required: true };
  assert.equal(validateField(choice, { c: "" }, messages), "Choose office region");
});

test("a hidden field is never reported, even when required and empty", () => {
  const field = { id: "c", label: "x", type: "text", required: true, show_if: { field: "t", in: ["llp"] } };
  assert.equal(validateField(field, { t: "partnership", c: "" }, messages), null);
  assert.notEqual(validateField(field, { t: "llp", c: "" }, messages), null);
});

test("a value that breaks the pattern gets the pattern's own message", () => {
  const field = { id: "e", label: "email", type: "email", pattern: pattern("email"), pattern_message: "bad email" };
  assert.equal(validateField(field, { e: "not-an-email" }, messages), "bad email");
  assert.equal(validateField(field, { e: "sam@example.test" }, messages), null);
});

test("a value longer than the field allows is reported", () => {
  const field = { id: "n", label: "name", type: "text", max_length: 3 };
  assert.equal(validateField(field, { n: "abcd" }, messages), "name is too long");
});

test("a number must be a number and inside its range", () => {
  const field = { id: "m", label: "minutes", type: "number", required: true, min: 0, max: 600 };
  assert.equal(validateField(field, { m: "abc" }, messages), "minutes must be a number");
  assert.equal(validateField(field, { m: "-1" }, messages), "minutes must be 0 or more");
  assert.equal(validateField(field, { m: "601" }, messages), "minutes must be 600 or less");
  assert.equal(validateField(field, { m: "30" }, messages), null);
  assert.equal(validateField(field, { m: "0" }, messages), null);
});

test("only the fields that are wrong are returned", () => {
  const fields = [
    { id: "a", label: "a", type: "text", required: true },
    { id: "b", label: "b", type: "text", required: true },
    { id: "note", type: "note" },
  ];
  assert.deepEqual(Object.keys(validateFields(fields, { a: "x", b: "" }, messages)), ["b"]);
});

test("values of hidden fields and notes are not kept", () => {
  const fields = [
    { id: "type", type: "select" },
    { id: "number", type: "text", show_if: { field: "type", in: ["llp"] } },
    { id: "note", type: "note" },
  ];
  assert.deepEqual(visibleValues(fields, { type: "partnership", number: "12345678" }), { type: "partnership" });
});

test("a review shows the option's wording, yes or no for a tick, and a marker for a blank", () => {
  const labels = { yes: "Yes", no: "No", blank: "Not given" };
  const select = { type: "select", options: [{ value: "llp", label: "LLP" }] };
  assert.equal(displayValue(select, "llp", labels), "LLP");
  assert.equal(displayValue({ type: "checkbox" }, true, labels), "Yes");
  assert.equal(displayValue({ type: "checkbox" }, false, labels), "No");
  assert.equal(displayValue({ type: "text" }, "", labels), "Not given");
});

test("the configured formats accept real values and refuse wrong ones", () => {
  assert.ok(matches("email", "sam@example.co.uk"));
  assert.ok(!matches("email", "sam@example"));
  assert.ok(matches("phone", "+44 (0)20 7946 0000"));
  assert.ok(!matches("phone", "call me"));
  assert.ok(matches("sra_number", "661249"));
  assert.ok(!matches("sra_number", "SRA661249"));
  assert.ok(matches("company_number", "10759009"));
  assert.ok(matches("company_number", "OC123456"));
  assert.ok(!matches("company_number", "1234"));
  assert.ok(matches("postcode", "SE8 3NU"));
  assert.ok(matches("postcode", "LL11 1AA"));
  assert.ok(!matches("postcode", "12345"));
  assert.ok(matches("vat_number", "GB123456789"));
  assert.ok(matches("vat_number", "123456789"));
  assert.ok(!matches("vat_number", "12345"));
  assert.ok(matches("url", "www.example.co.uk"));
  assert.ok(matches("url", "https://example.co.uk/contact"));
  assert.ok(!matches("url", "not a site"));
});

// The same cases are run against the API's copy of these rules in
// tests/test_api.py, so the browser and the API cannot drift apart.
{
  const { readFileSync } = await import("node:fs");
  const read = (file) => JSON.parse(readFileSync(new URL(file, import.meta.url), "utf8"));
  const sharedMessages = read("../../site/config/forms.json").messages;
  for (const shared of read("../fixtures/validation_cases.json")) {
    test(`shared rule: ${shared.name}`, () => {
      assert.equal(validateField(shared.field, shared.values, sharedMessages), shared.message);
    });
  }
}
