import assert from "node:assert/strict";
import { test } from "node:test";

import { open, routes, site, storageWith } from "./harness.mjs";

const YOU = {
  person_name: "Sam Example",
  person_role: "partner",
  person_email: "sam@example.test",
  person_phone: "020 7946 0000",
};
const FIRM = {
  firm_name: "Example Law LLP",
  firm_sra_number: "123456",
  firm_type: "partnership",
  firm_office_line1: "1 High Street",
  firm_office_town: "London",
  firm_office_postcode: "SE1 1AA",
};
const SIGNED_UP = { signup: { values: { ...YOU, ...FIRM }, completedAt: "2026-11-17T10:00:00.000Z" } };
const visibleStep = (page) => page.all("[data-step]").filter((step) => !step.hidden).map((step) => step.dataset.step);
const fill = (page, values, root) => Object.entries(values).forEach(([id, value]) => page.set(id, value, root));

// ------------------------------------------------------------------ sign-up

test("sign-up starts on the first step and will not move on while it is incomplete", async () => {
  const page = await open("signup");
  assert.deepEqual(visibleStep(page), ["you"]);

  page.submit();
  assert.deepEqual(visibleStep(page), ["you"]);
  assert.equal(page.one("[data-summary]").hidden, false);
  assert.equal(page.error("person_name"), "Enter full name");
  assert.equal(page.error("person_role"), "Choose role at the firm");
  assert.equal(page.error("person_sra_number"), "", "an optional field is not reported");
  assert.equal(page.one('[data-input="person_name"]').getAttribute("aria-invalid"), "true");
  assert.deepEqual(page.state(), {}, "nothing is kept from a step that failed");
});

test("a wrong email address is refused with the format message", async () => {
  const page = await open("signup");
  fill(page, { ...YOU, person_email: "sam-at-example" });
  page.submit();
  assert.deepEqual(visibleStep(page), ["you"]);
  assert.match(page.error("person_email"), /name@example\.com/);
});

test("the company number is asked for only when the firm is a company or an LLP", async () => {
  const page = await open("signup");
  assert.equal(page.field("firm_company_number").hidden, true);
  page.set("firm_type", "llp");
  assert.equal(page.field("firm_company_number").hidden, false);
  page.set("firm_type", "sole_practice");
  assert.equal(page.field("firm_company_number").hidden, true);
});

test("a separate correspondence address appears, and is required, only when the box is unticked", async () => {
  const page = await open("signup");
  fill(page, YOU);
  page.submit();
  assert.deepEqual(visibleStep(page), ["firm"]);
  assert.equal(page.field("firm_correspondence").hidden, true);

  fill(page, FIRM);
  page.set("firm_correspondence_same", false);
  assert.equal(page.field("firm_correspondence").hidden, false);
  page.submit();
  assert.deepEqual(visibleStep(page), ["firm"]);
  assert.equal(page.error("firm_correspondence_line1"), "Enter address line 1");
  assert.equal(page.error("firm_correspondence_line2"), "", "the second line is optional");

  page.set("firm_correspondence_same", true);
  page.submit();
  assert.deepEqual(visibleStep(page), ["confirm"]);
});

test("the whole sign-up: review, confirm, saved, and on to the portal", async () => {
  const page = await open("signup");
  fill(page, YOU);
  page.submit();
  fill(page, { ...FIRM, firm_type: "llp", firm_company_number: "OC123456" });
  page.set("firm_type", "partnership");
  page.submit();
  assert.deepEqual(visibleStep(page), ["confirm"]);

  const review = page.one("[data-review]").textContent;
  assert.match(review, /Sam Example/);
  assert.match(review, /Partner or director/, "a choice is shown by its wording, not its code");
  assert.match(review, /Example Law LLP/);
  assert.doesNotMatch(review, /OC123456/, "a field that is no longer on show is not reviewed");
  assert.equal(page.one('[data-progress-step="confirm"]').getAttribute("aria-current"), "step");

  page.submit();
  assert.equal(page.error("confirm_authorised"), "Tick the box to continue");
  assert.deepEqual(page.visited, []);

  page.set("confirm_authorised", true);
  page.submit();
  assert.deepEqual(page.visited, [routes.portal]);
  const saved = page.state();
  assert.ok(saved.signup.completedAt);
  assert.equal(saved.signup.values.person_email, YOU.person_email);
  assert.equal(saved.signup.values.firm_type, "partnership");
  assert.equal("firm_company_number" in saved.signup.values, false, "a hidden field's value is not kept");
  assert.equal("firm_correspondence_line1" in saved.signup.values, false);
  assert.equal("signupDraft" in saved, false);
});

test("back returns to the previous step with the entries still there", async () => {
  const page = await open("signup");
  fill(page, YOU);
  page.submit();
  page.click(page.one('[data-step="firm"] [data-back]'));
  assert.deepEqual(visibleStep(page), ["you"]);
  assert.equal(page.one('[data-input="person_name"]').value, YOU.person_name);
});

test("a half-finished sign-up is offered again in the same tab", async () => {
  const first = await open("signup");
  fill(first, YOU);
  first.submit();
  const again = await open("signup", first.storage);
  assert.equal(again.one('[data-input="person_email"]').value, YOU.person_email);
  assert.deepEqual(visibleStep(again), ["you"]);
});

// ------------------------------------------------------------------- portal

test("a visitor who has not signed up is sent from every portal page to sign-up", async () => {
  for (const route of ["portal", "company", "agreements"]) {
    const page = await open(route, storageWith({ signupDraft: YOU }));
    assert.deepEqual(page.visited, [routes.signup], route);
  }
});

test("the portal shows who is signed in, and sign out forgets everything", async () => {
  const page = await open("portal", storageWith(SIGNED_UP));
  assert.deepEqual(page.visited, []);
  assert.equal(page.one("[data-user-name]").textContent, YOU.person_name);
  assert.equal(page.one("[data-firm-name]").textContent, FIRM.firm_name);

  page.click(page.one("[data-sign-out]"));
  assert.deepEqual(page.state(), {});
  assert.deepEqual(page.visited, [routes.home]);
});

test("the checklist starts with only the sign-up details done and the account waiting", async () => {
  const page = await open("portal", storageWith(SIGNED_UP));
  const badges = page.all("[data-badge]");
  assert.equal(badges.length, site.setup_steps.length);
  const done = page.one('[data-setup-step="details"] [data-badge]');
  assert.equal(done.textContent, site.labels.done);
  assert.ok(badges.filter((badge) => badge !== done).every((badge) => badge.textContent === site.labels.to_do));
  assert.equal(page.one('[data-when="waiting"]').hidden, false);
  assert.equal(page.one('[data-when="ready"]').hidden, true);
});

test("the account is ready only when both steps are done for the current agreement", async () => {
  const company = { savedAt: "2026-11-17T10:10:00.000Z" };
  const agreement = { version: site.agreement.version, acceptedAt: "2026-11-17T10:20:00.000Z", acceptedBy: "Sam" };

  const half = await open("portal", storageWith({ ...SIGNED_UP, company }));
  assert.equal(half.one('[data-setup-step="company"] [data-badge]').textContent, site.labels.done);
  assert.equal(half.one('[data-setup-step="agreement"] [data-badge]').textContent, site.labels.to_do);
  assert.equal(half.one('[data-when="ready"]').hidden, true);

  const done = await open("portal", storageWith({ ...SIGNED_UP, company, agreement }));
  assert.ok(done.all("[data-badge]").every((badge) => badge.textContent === site.labels.done));
  assert.equal(done.one('[data-when="ready"]').hidden, false);
  assert.equal(done.one('[data-when="waiting"]').hidden, true);

  const outdated = { ...agreement, version: "an-older-version" };
  const stale = await open("portal", storageWith({ ...SIGNED_UP, company, agreement: outdated }));
  assert.equal(stale.one('[data-when="ready"]').hidden, true);
});

// ------------------------------------------------------ company information

const BILLING = { laa_account_number: "0A123B", office_region: "London", vat_number: "123456789" };

test("company information opens with the cautious positions chosen and no fee earners to enter", async () => {
  const page = await open("company", storageWith(SIGNED_UP));
  assert.equal(page.all("[data-row], [data-add-row]").length, 0, "fee earners are managed in the product");
  assert.equal(page.one('[data-input="position_UNITS-6MIN"]:checked').value, "round_down");
  assert.equal(page.one('[data-input="position_ROUTINE-COUNT"]:checked').value, "per_message");
  assert.equal(page.one('[data-section="legal_aid"]').hidden, false);
  assert.equal(page.one('[data-section="private"]').hidden, true, "private charging is off until chosen");
});

test("company information is not saved while anything on show is missing", async () => {
  const page = await open("company", storageWith(SIGNED_UP));
  page.submit();
  assert.equal(page.one("[data-summary]").hidden, false);
  assert.equal(page.error("laa_account_number"), "Enter LAA account number");
  assert.equal(page.error("office_region"), "Choose office region");
  assert.equal(page.error("vat_number"), "Enter VAT number");
  assert.equal(page.error("private_rate_a"), "", "a hidden section is not checked");
  assert.equal(page.one("[data-saved]").hidden, true);
  assert.equal("company" in page.state(), false);
});

test("a complete company information page is saved with the positions", async () => {
  const page = await open("company", storageWith(SIGNED_UP));
  fill(page, BILLING);
  page.set("position_ROUTINE-COUNT", "per_recipient");
  page.submit();

  assert.equal(page.one("[data-summary]").hidden, true);
  assert.equal(page.one("[data-saved]").hidden, false);
  const { company } = page.state();
  assert.ok(company.savedAt);
  assert.ok(company.registerVersion);
  assert.equal(company.values.office_region, "London");
  assert.equal(company.values["position_ROUTINE-COUNT"], "per_recipient");
  assert.equal(company.values["position_UNITS-6MIN"], "round_down");
  assert.equal(company.values["position_BILL-PREP-TIME"], "30");
  assert.equal("private_rate_a" in company.values, false);
  assert.equal("feeEarners" in company, false);
});

test("without VAT registration the VAT number is neither shown nor required", async () => {
  const page = await open("company", storageWith(SIGNED_UP));
  page.set("vat_registered", false);
  assert.equal(page.field("vat_number").hidden, true);
  fill(page, { laa_account_number: "0A123B", office_region: "Non-London" });
  page.submit();
  assert.equal(page.one("[data-saved]").hidden, false);
  assert.equal("vat_number" in page.state().company.values, false);
});

test("a private-only firm fills in private charging and is not asked for legal aid details", async () => {
  const page = await open("company", storageWith(SIGNED_UP));
  page.set("funding_legal_aid", false);
  page.set("funding_private", true);
  assert.equal(page.one('[data-section="legal_aid"]').hidden, true);
  assert.equal(page.one('[data-section="private"]').hidden, false);
  assert.equal(page.field("laa_account_number").hidden, true);

  fill(page, { office_region: "London", vat_number: "123456789" });
  page.submit();
  assert.equal(page.error("private_rate_a"), "Enter hourly rate for grade A in pounds");
  assert.equal(page.error("laa_account_number"), "");

  fill(page, {
    private_rate_a: "300",
    private_rate_b: "250",
    private_rate_c: "200",
    private_rate_d: "120",
    private_letters_out: "one_unit",
    private_letters_in: "not_charged",
    private_calls: "one_unit",
  });
  page.submit();
  assert.equal(page.one("[data-saved]").hidden, false);
  const { values } = page.state().company;
  assert.equal(values.private_unit_minutes, "6");
  assert.equal("position_UNITS-6MIN" in values, false, "legal aid positions are not kept for a private-only firm");
});

test("at least one type of funding is needed", async () => {
  const page = await open("company", storageWith(SIGNED_UP));
  page.set("funding_legal_aid", false);
  page.submit();
  assert.equal(page.one("[data-funding-error]").hidden, false);
  assert.equal("company" in page.state(), false);
});

test("saved company information is shown again when the page is reopened", async () => {
  const page = await open("company", storageWith(SIGNED_UP));
  fill(page, BILLING);
  page.submit();

  const again = await open("company", page.storage);
  assert.equal(again.one('[data-input="laa_account_number"]').value, BILLING.laa_account_number);
  assert.equal(again.one('[data-input="office_region"]:checked').value, "London");
});

// --------------------------------------------------------------- agreements

test("the agreement must be ticked, and acceptance records who, when and which version", async () => {
  const page = await open("agreements", storageWith(SIGNED_UP));
  assert.equal(page.one("[data-accepted]").hidden, true);
  assert.equal(page.one('[data-input="accept_name"]').value, YOU.person_name, "the name is offered from sign-up");

  page.submit();
  assert.equal(page.error("accept_tick"), "Tick the box to continue");
  assert.equal("agreement" in page.state(), false);

  page.set("accept_tick", true);
  page.submit();
  const { agreement } = page.state();
  assert.equal(agreement.version, site.agreement.version);
  assert.equal(agreement.acceptedBy, YOU.person_name);
  assert.ok(agreement.acceptedAt);
  assert.equal(page.one("[data-accepted]").hidden, false);
  assert.equal(page.one("[data-form]").hidden, true);
  assert.equal(page.one("[data-accepted-name]").textContent, YOU.person_name);

  page.click(page.one("[data-print]"));
  assert.equal(page.printed(), 1);
});

test("an acceptance of an older version is asked for again", async () => {
  const old = { version: "an-older-version", acceptedBy: "Sam", acceptedAt: "2026-11-01T09:00:00.000Z" };
  const page = await open("agreements", storageWith({ ...SIGNED_UP, agreement: old }));
  assert.equal(page.one("[data-form]").hidden, false);
  assert.equal(page.one("[data-accepted]").hidden, true);
});
