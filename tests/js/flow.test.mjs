import assert from "node:assert/strict";
import { test } from "node:test";

import { open, routes, site, storageWith } from "./harness.mjs";

const YOU = {
  person_name: "Sam Example",
  person_role: "partner",
  person_email: "sam@example.test",
  person_phone: "020 7946 0000",
};
const KIND = "partnership";
const PRACTICE = {
  account_name: "Example Law",
  sra_number: "123456",
  principals: "Sam Example, Alex Example",
  office_line1: "1 High Street",
  office_town: "London",
  office_postcode: "SE1 1AA",
};
const SIGNED_UP = {
  signup: { values: { ...YOU, account_type: KIND, ...PRACTICE }, completedAt: "2026-11-17T10:00:00.000Z" },
};
const visibleStep = (page) => page.all("[data-step]").filter((step) => !step.hidden).map((step) => step.dataset.step);
const fill = (page, values, root) => Object.entries(values).forEach(([id, value]) => page.set(id, value, root));
// The block of questions for one kind of account, and the kinds whose block is on show.
const block = (page, kind) => page.one(`[data-type="${kind}"]`);
const shownKinds = (page) => page.all("[data-type]").filter((kind) => !kind.hidden).map((kind) => kind.dataset.type);
const asked = (page, kind) => [...block(page, kind).querySelectorAll("[data-input]")].map((input) => input.dataset.input);
const KINDS = ["sole_practice", "partnership", "llp", "company", "freelance_solicitor", "costs_lawyer", "costs_draftsman"];

// Chooses the kind of account and answers the questions about the person.
function reachPractice(page, kind = KIND) {
  page.set("account_type", kind);
  page.submit();
  fill(page, YOU);
  page.submit();
}

// ------------------------------------------------------------------ sign-up

test("sign-up starts by asking the kind of account and will not move on without one", async () => {
  const page = await open("signup");
  assert.deepEqual(visibleStep(page), ["type"]);
  assert.deepEqual(
    [...page.one('[data-input="account_type"]').options].map((option) => option.value).filter(Boolean),
    KINDS,
  );

  page.submit();
  assert.deepEqual(visibleStep(page), ["type"]);
  assert.equal(page.one("[data-summary]").hidden, false);
  assert.equal(page.error("account_type"), "Choose account type");
  assert.deepEqual(page.state(), {}, "nothing is kept from a step that failed");
});

test("the questions about the person are checked before the practice is asked about", async () => {
  const page = await open("signup");
  page.set("account_type", KIND);
  page.submit();
  assert.deepEqual(visibleStep(page), ["you"]);

  page.submit();
  assert.deepEqual(visibleStep(page), ["you"]);
  assert.equal(page.error("person_name"), "Enter full name");
  assert.equal(page.error("person_sra_number"), "", "an optional field is not reported");
  assert.equal(page.one('[data-input="person_name"]').getAttribute("aria-invalid"), "true");

  fill(page, { ...YOU, person_email: "sam-at-example" });
  page.submit();
  assert.deepEqual(visibleStep(page), ["you"]);
  assert.match(page.error("person_email"), /name@example\.com/);
});

test("each kind of account is shown its own questions and nobody else's", async () => {
  for (const kind of KINDS) {
    const page = await open("signup");
    reachPractice(page, kind);
    assert.deepEqual(visibleStep(page), ["practice"], kind);
    assert.deepEqual(shownKinds(page), [kind], kind);
  }
});

test("what only some kinds have is asked only of them", async () => {
  const page = await open("signup");
  assert.ok(!asked(page, "freelance_solicitor").includes("trading_name"), "a freelance solicitor has no trading name");
  for (const kind of ["sole_practice", "partnership", "freelance_solicitor"]) {
    assert.ok(!asked(page, kind).includes("company_number"), `${kind} has no company number`);
  }
  for (const kind of ["llp", "company"]) assert.ok(asked(page, kind).includes("company_number"), kind);
  assert.ok(asked(page, "costs_lawyer").includes("cl_number"));
  assert.ok(!asked(page, "costs_draftsman").includes("cl_number"));
  for (const kind of ["costs_lawyer", "costs_draftsman"]) assert.ok(!asked(page, kind).includes("sra_number"), kind);
});

test("a costs business is asked for a company number only if it is a company or an LLP", async () => {
  const page = await open("signup");
  reachPractice(page, "costs_draftsman");
  const mine = block(page, "costs_draftsman");
  assert.equal(page.field("company_number", mine).hidden, true);
  page.set("legal_form", "llp", mine);
  assert.equal(page.field("company_number", mine).hidden, false);
  page.set("legal_form", "sole", mine);
  assert.equal(page.field("company_number", mine).hidden, true);
});

test("the practice's own questions are checked, and only that kind's", async () => {
  const page = await open("signup");
  reachPractice(page);
  page.submit();
  assert.deepEqual(visibleStep(page), ["practice"]);
  assert.equal(page.error("account_name", block(page, KIND)), "Enter name of the partnership");
  assert.equal(page.error("principals", block(page, KIND)), "Enter partners");
  assert.equal(page.error("office_line2", block(page, KIND)), "", "the second address line is optional");
  assert.equal(page.error("cl_number", block(page, "costs_lawyer")), "", "another kind's questions are not checked");
});

test("the whole sign-up: review, confirm, saved, and on to the portal", async () => {
  const page = await open("signup");
  // Answers given as one kind are left behind when another kind is chosen instead.
  reachPractice(page, "llp");
  fill(page, { account_name: "Wrong LLP", company_number: "OC123456" }, block(page, "llp"));
  page.click(page.one('[data-step="practice"] [data-back]'));
  page.click(page.one('[data-step="you"] [data-back]'));
  reachPractice(page, KIND);
  fill(page, PRACTICE, block(page, KIND));
  page.submit();
  assert.deepEqual(visibleStep(page), ["confirm"]);

  const review = page.one("[data-review]").textContent;
  assert.match(review, /Sam Example/);
  assert.match(review, /Partner or director/, "a choice is shown by its wording, not its code");
  assert.match(review, /Solicitors: partnership/);
  assert.match(review, /Example Law/);
  assert.doesNotMatch(review, /OC123456|Wrong LLP/, "another kind's answers are not reviewed");
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
  assert.equal(saved.signup.values.account_type, KIND);
  assert.equal(saved.signup.values.account_name, PRACTICE.account_name);
  assert.equal("company_number" in saved.signup.values, false, "another kind's answers are not kept");
  assert.equal("signupDraft" in saved, false);
});

test("back returns to the previous step with the entries still there", async () => {
  const page = await open("signup");
  reachPractice(page);
  page.click(page.one('[data-step="practice"] [data-back]'));
  assert.deepEqual(visibleStep(page), ["you"]);
  assert.equal(page.one('[data-input="person_name"]').value, YOU.person_name);
});

test("a half-finished sign-up is offered again in the same tab, with its kind of account", async () => {
  const first = await open("signup");
  reachPractice(first, "costs_lawyer");
  fill(first, { account_name: "Example Costs", cl_number: "CL1234" }, block(first, "costs_lawyer"));
  first.submit();
  first.click(first.one('[data-step="practice"] [data-back]'));
  first.submit();

  const again = await open("signup", first.storage);
  assert.equal(again.one('[data-input="person_email"]').value, YOU.person_email);
  assert.equal(again.one('[data-input="account_type"]').value, "costs_lawyer");
  assert.equal(block(again, "costs_lawyer").querySelector('[data-input="account_name"]').value, "Example Costs");
  assert.deepEqual(visibleStep(again), ["type"]);
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
  assert.equal(page.one("[data-firm-name]").textContent, PRACTICE.account_name);

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

test("company information asks for billing set-up and the version, and nothing about how the firm charges", async () => {
  const page = await open("company", storageWith(SIGNED_UP));
  assert.equal(page.all("[data-row], [data-add-row]").length, 0, "fee earners are managed in the product");
  assert.equal(page.all('[data-input^="position_"], [data-input^="private_"]').length, 0, "charging is set up in the product");
  assert.deepEqual(
    page.all("[data-section]").map((section) => section.dataset.section),
    ["funding", "billing", "version"],
  );
});

test("the newest version is offered first to a firm that has chosen none", async () => {
  const page = await open("company", storageWith(SIGNED_UP));
  const select = page.one('[data-input="product_version"]');
  assert.ok(select.options.length >= 1);
  assert.equal(select.value, select.options[select.options.length - 1].value);
});

test("company information is not saved while anything on show is missing", async () => {
  const page = await open("company", storageWith(SIGNED_UP));
  page.submit();
  assert.equal(page.one("[data-summary]").hidden, false);
  assert.equal(page.error("laa_account_number"), "Enter LAA account number");
  assert.equal(page.error("office_region"), "Choose office region");
  assert.equal(page.error("vat_number"), "Enter VAT number");
  assert.equal(page.one("[data-saved]").hidden, true);
  assert.equal("company" in page.state(), false);
});

test("a complete company information page is saved with the version chosen", async () => {
  const page = await open("company", storageWith(SIGNED_UP));
  fill(page, BILLING);
  page.submit();

  assert.equal(page.one("[data-summary]").hidden, true);
  assert.equal(page.one("[data-saved]").hidden, false);
  const { company } = page.state();
  assert.ok(company.savedAt);
  assert.equal(company.values.office_region, "London");
  assert.equal(company.values.product_version, page.one('[data-input="product_version"]').value);
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

test("a private-only firm is not asked for a legal aid account number", async () => {
  const page = await open("company", storageWith(SIGNED_UP));
  page.set("funding_legal_aid", false);
  page.set("funding_private", true);
  assert.equal(page.field("laa_account_number").hidden, true);

  fill(page, { office_region: "London", vat_number: "123456789" });
  page.submit();
  assert.equal(page.error("laa_account_number"), "");
  assert.equal(page.one("[data-saved]").hidden, false);
  const { values } = page.state().company;
  assert.equal(values.funding_private, true);
  assert.equal("laa_account_number" in values, false);
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

test("a preview has no UID to show", async () => {
  const page = await open("portal", storageWith(SIGNED_UP));
  assert.equal(page.one("[data-uid-panel]").hidden, true);
});
