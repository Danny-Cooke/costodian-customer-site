// The site with sign-in switched on: creating a sign-in, confirming the email
// address, signing in, and reading and saving the account through the API.
// The network is a stand-in; no request leaves the test.

import assert from "node:assert/strict";
import { test } from "node:test";

import { fakeNetwork, liveData, memoryStorage, openLive, routes, sessionWith, settle } from "./harness.mjs";

const PASSWORD = "Correct-horse-9-battery";
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
const SIGNUP = { values: { ...YOU, ...FIRM }, completedAt: "2026-11-18T10:00:00.000Z" };
const TOKENS = { AuthenticationResult: { IdToken: "token-1", RefreshToken: "refresh-1", ExpiresIn: 3600 } };
const OWNER = { sub: "sub-owner", email: YOU.person_email, role: "owner", addedBy: YOU.person_email, addedAt: "2026-11-18T10:00:00.000Z" };
const ADMIN = { sub: "sub-admin", email: "alex@example.test", role: "admin", addedBy: YOU.person_email, addedAt: "2026-11-18T11:00:00.000Z" };
// What the API answers for a person in a firm; `more` replaces any part of it.
const accountOf = (member, more = {}) => ({
  body: {
    member: member && { role: member.role, sub: member.sub },
    signup: SIGNUP,
    company: null,
    agreement: null,
    people: [OWNER, ADMIN],
    changes: [],
    ...more,
  },
});
const data = liveData();
const fill = (page, values) => Object.entries(values).forEach(([id, value]) => page.set(id, value));
const visibleStep = (page) => page.all("[data-step]").filter((step) => !step.hidden).map((step) => step.dataset.step);
const everythingStored = (storage) => JSON.stringify([storage.getItem(data.storageKey), storage.getItem(data.auth.sessionKey)]);

// Answers sign-in service calls by action, and API calls by method and path.
const network = (answers) =>
  fakeNetwork((request) => answers[request.target || `${request.method} ${request.url}`]?.(request) ?? { status: 500 });

async function reachConfirm(page) {
  fill(page, YOU);
  page.submit();
  fill(page, FIRM);
  page.submit();
  assert.deepEqual(visibleStep(page), ["signin"]);
}

test("the live build asks for a password, and the two entries must match", async () => {
  const page = await openLive("signup", memoryStorage(), network({}));
  await reachConfirm(page);

  fill(page, { person_password: "short", person_password_again: "short" });
  page.submit();
  assert.match(page.error("person_password"), /at least \d+ characters/);

  fill(page, { person_password: PASSWORD, person_password_again: `${PASSWORD}x` });
  page.submit();
  assert.equal(page.error("person_password_again"), "The two entries do not match");
  assert.deepEqual(visibleStep(page), ["signin"]);
});

test("signing up creates the sign-in, confirms the code, signs in and saves the details", async () => {
  const storage = memoryStorage();
  const net = network({
    SignUp: () => ({ body: { UserConfirmed: false } }),
    ConfirmSignUp: () => ({ body: {} }),
    InitiateAuth: () => ({ body: TOKENS }),
    [`POST ${data.api.firm}`]: () => ({ body: { member: { role: "owner" } } }),
    [`GET ${data.api.account}`]: () => accountOf(OWNER, { signup: null }),
    [`PUT ${data.api.account}/signup`]: (request) => ({ body: { signup: { ...request.body, completedAt: SIGNUP.completedAt } } }),
  });
  const page = await openLive("signup", storage, net);
  await reachConfirm(page);
  fill(page, { person_password: PASSWORD, person_password_again: PASSWORD });
  page.submit();
  assert.deepEqual(visibleStep(page), ["confirm"]);
  assert.ok(!page.one("[data-review]").textContent.includes(PASSWORD), "the review never shows the password");
  assert.equal(page.one('[data-field="payment_note"]'), null, "no payment is asked for");

  page.set("confirm_authorised", true);
  page.submit();
  await settle();
  const [signUp] = net.requests;
  assert.equal(signUp.url, data.auth.endpoint);
  assert.equal(signUp.target, "SignUp");
  assert.deepEqual(
    { client: signUp.body.ClientId, user: signUp.body.Username, password: signUp.body.Password },
    { client: data.auth.clientId, user: YOU.person_email, password: PASSWORD },
  );
  assert.equal(page.one("[data-verify]").hidden, false);
  assert.equal(page.one("[data-verify-email]").textContent, YOU.person_email);
  assert.deepEqual(page.visited, [], "nothing moves on until the email address is confirmed");

  const verifyForm = page.one("[data-verify-form]");
  page.set("verify_code", "123456", verifyForm);
  page.submit(verifyForm);
  await settle();
  assert.deepEqual(
    net.requests.map((request) => request.target || `${request.method} ${request.url}`),
    ["SignUp", "ConfirmSignUp", "InitiateAuth", `POST ${data.api.firm}`, `GET ${data.api.account}`, `PUT ${data.api.account}/signup`],
  );
  const save = net.requests.at(-1);
  assert.equal(save.headers.Authorization, "token-1");
  for (const [id, value] of Object.entries({ ...YOU, ...FIRM })) assert.equal(save.body.values[id], value, id);
  assert.ok(!Object.keys(save.body.values).some((id) => id.includes("password") || id.startsWith("confirm_")));
  assert.ok(!JSON.stringify(save.body).includes(PASSWORD), "the password is never sent to our API");
  assert.ok(!everythingStored(storage).includes(PASSWORD), "the password is never kept in the browser");
  assert.deepEqual(page.visited, [routes.portal]);
});

test("an email address that already has an account is told to sign in", async () => {
  const net = network({ SignUp: () => ({ status: 400, body: { __type: "UsernameExistsException" } }) });
  const page = await openLive("signup", memoryStorage(), net);
  await reachConfirm(page);
  fill(page, { person_password: PASSWORD, person_password_again: PASSWORD });
  page.submit();
  page.set("confirm_authorised", true);
  page.submit();
  await settle();
  assert.match(page.one("[data-summary]").textContent, /already an account/);
  assert.equal(page.one("[data-verify]").hidden, true);
});

test("a wrong code is reported and a new one can be sent", async () => {
  const net = network({
    SignUp: () => ({ body: {} }),
    ConfirmSignUp: () => ({ status: 400, body: { __type: "CodeMismatchException" } }),
    ResendConfirmationCode: () => ({ body: {} }),
  });
  const page = await openLive("signup", memoryStorage(), net);
  await reachConfirm(page);
  fill(page, { person_password: PASSWORD, person_password_again: PASSWORD });
  page.submit();
  page.set("confirm_authorised", true);
  page.submit();
  await settle();

  const verifyForm = page.one("[data-verify-form]");
  page.set("verify_code", "000000", verifyForm);
  page.submit(verifyForm);
  await settle();
  assert.match(page.one("[data-verify] [data-summary]").textContent, /code is not right/);
  assert.deepEqual(page.visited, []);

  page.click(page.one("[data-resend]"));
  await settle();
  assert.equal(net.requests.at(-1).target, "ResendConfirmationCode");
  assert.equal(page.one("[data-verify-notice]").hidden, false);
});

test("a portal page sends a visitor who is not signed in to sign in, without calling the API", async () => {
  const net = network({});
  const page = await openLive("portal", memoryStorage(), net);
  assert.deepEqual(page.visited, [routes.signin]);
  assert.deepEqual(net.requests, []);
});

test("a signed-in person whose details were never saved is asked for them first", async () => {
  const net = network({ [`GET ${data.api.account}`]: () => accountOf(OWNER, { signup: null }) });
  const page = await openLive("company", sessionWith(memoryStorage()), net);
  assert.deepEqual(page.visited, [routes.details]);
});

test("my account shows who is signed in and what is done, read from the API", async () => {
  const net = network({
    [`GET ${data.api.account}`]: () => accountOf(OWNER, { company: { savedAt: "2026-11-18T11:00:00.000Z" } }),
  });
  const page = await openLive("portal", sessionWith(memoryStorage()), net);
  assert.deepEqual(page.visited, []);
  assert.equal(net.requests.length, 1, "the account is read once for the whole page");
  assert.equal(net.requests[0].headers.Authorization, "token-1");
  assert.equal(page.one("[data-user-name]").textContent, YOU.person_name);
  assert.equal(page.one('[data-setup-step="details"] [data-badge]').textContent, "Done");
  assert.equal(page.one('[data-setup-step="company"] [data-badge]').textContent, "Done");
  assert.equal(page.one('[data-setup-step="agreement"] [data-badge]').textContent, "To do");
});

test("your details are filled from the account and saved back to it", async () => {
  const net = network({
    [`GET ${data.api.account}`]: () => accountOf(OWNER),
    [`PUT ${data.api.account}/signup`]: (request) => ({ body: { signup: { ...request.body, completedAt: SIGNUP.completedAt } } }),
  });
  const page = await openLive("details", sessionWith(memoryStorage()), net);
  assert.equal(page.one('[data-input="firm_name"]').value, FIRM.firm_name);

  page.set("person_phone", "020 7946 0999");
  page.submit();
  await settle();
  assert.equal(net.requests.at(-1).body.values.person_phone, "020 7946 0999");
  assert.equal(page.one("[data-saved]").hidden, false);
});

test("what the API refuses is shown, and the page does not claim it was saved", async () => {
  const net = network({
    [`GET ${data.api.account}`]: () => accountOf(OWNER),
    [`PUT ${data.api.account}/signup`]: () => ({ status: 422, body: { errors: { firm_name: "Enter firm name" } } }),
  });
  const page = await openLive("details", sessionWith(memoryStorage()), net);
  page.submit();
  await settle();
  assert.match(page.one("[data-summary]").textContent, /Enter firm name/);
  assert.equal(page.one("[data-saved]").hidden, true);
});

test("a token about to run out is renewed before the API is called", async () => {
  const net = network({
    InitiateAuth: (request) => {
      assert.equal(request.body.AuthFlow, "REFRESH_TOKEN_AUTH");
      return { body: { AuthenticationResult: { IdToken: "token-2", ExpiresIn: 3600 } } };
    },
    [`GET ${data.api.account}`]: () => accountOf(OWNER),
  });
  await openLive("portal", sessionWith(memoryStorage(), "token-1", 5), net);
  assert.deepEqual(net.requests.map((request) => request.target || request.url), ["InitiateAuth", data.api.account]);
  assert.equal(net.requests[1].headers.Authorization, "token-2");
});

test("signing in with the wrong password says so and goes nowhere", async () => {
  const net = network({ InitiateAuth: () => ({ status: 400, body: { __type: "NotAuthorizedException" } }) });
  const page = await openLive("signin", memoryStorage(), net);
  const form = page.one('[data-panel="signin"] form');
  page.set("signin_email", YOU.person_email, form);
  page.set("signin_password", "wrong", form);
  page.submit(form);
  await settle();
  assert.match(form.textContent, /email address or password is not right/);
  assert.deepEqual(page.visited, []);
});

test("signing in keeps the session and opens my account", async () => {
  const storage = memoryStorage();
  const page = await openLive("signin", storage, network({ InitiateAuth: () => ({ body: TOKENS }) }));
  const form = page.one('[data-panel="signin"] form');
  page.set("signin_email", YOU.person_email, form);
  page.set("signin_password", PASSWORD, form);
  page.submit(form);
  await settle();
  assert.deepEqual(page.visited, [routes.portal]);
  assert.equal(JSON.parse(storage.getItem(data.auth.sessionKey)).idToken, "token-1");
  assert.ok(!everythingStored(storage).includes(PASSWORD));
});

test("signing in before the email address is confirmed asks for the code", async () => {
  const net = network({
    InitiateAuth: () => ({ status: 400, body: { __type: "UserNotConfirmedException" } }),
    ResendConfirmationCode: () => ({ body: {} }),
  });
  const page = await openLive("signin", memoryStorage(), net);
  const form = page.one('[data-panel="signin"] form');
  page.set("signin_email", YOU.person_email, form);
  page.set("signin_password", PASSWORD, form);
  page.submit(form);
  await settle();
  assert.equal(page.one('[data-panel="verify"]').hidden, false);
  assert.equal(net.requests.at(-1).target, "ResendConfirmationCode");
});

test("signing out forgets the session and ends it at the sign-in service", async () => {
  const storage = sessionWith(memoryStorage());
  const net = network({
    [`GET ${data.api.account}`]: () => accountOf(OWNER),
    RevokeToken: () => ({ body: {} }),
  });
  const page = await openLive("portal", storage, net);
  page.click(page.one("[data-sign-out]"));
  await settle();
  assert.equal(storage.getItem(data.auth.sessionKey), null);
  assert.equal(net.requests.at(-1).target, "RevokeToken");
  assert.deepEqual(page.visited, [routes.home]);
});

// ------------------------------------------------------- firms, roles, people

const personRows = (page) => page.all("[data-people] [data-person]");
const shown = (elements) => elements.filter((element) => !element.hidden);

test("a signed-in person with no firm is given one before anything else", async () => {
  let enrolled = false;
  const net = network({
    [`GET ${data.api.account}`]: () => (enrolled ? accountOf(OWNER, { signup: null }) : accountOf(null, { signup: null, people: [] })),
    [`POST ${data.api.firm}`]: () => {
      enrolled = true;
      return { body: { member: { role: "owner" } } };
    },
  });
  const page = await openLive("details", sessionWith(memoryStorage()), net);
  assert.deepEqual(
    net.requests.map((request) => `${request.method} ${request.url}`),
    [`GET ${data.api.account}`, `POST ${data.api.firm}`, `GET ${data.api.account}`],
  );
  assert.deepEqual(page.visited, []);
});

test("an owner sees everyone, can invite, change a role and remove a person", async () => {
  const net = network({
    [`GET ${data.api.account}`]: () => accountOf(OWNER),
    [`POST ${data.api.people}`]: (request) => ({
      body: {
        people: [OWNER, ADMIN, { sub: "sub-new", email: request.body.values.invite_email, role: request.body.values.invite_role }],
        changes: [{ at: "2026-11-18T12:00:00.000Z", by: OWNER.email, what: "invited", subject: request.body.values.invite_email, role: "admin" }],
      },
    }),
    [`PUT ${data.api.people}/${ADMIN.sub}`]: () => ({ body: { people: [OWNER, { ...ADMIN, role: "owner" }], changes: [] } }),
    [`DELETE ${data.api.people}/${ADMIN.sub}`]: () => ({ body: { people: [OWNER], changes: [] } }),
  });
  const page = await openLive("people", sessionWith(memoryStorage()), net);
  assert.deepEqual(personRows(page).map((row) => row.querySelector("[data-person-email]").textContent), [OWNER.email, ADMIN.email]);
  assert.equal(page.one(`[data-person="${OWNER.sub}"] [data-person-you]`).hidden, false);
  assert.equal(page.one("[data-invite]").hidden, false);
  const adminRow = () => page.one(`[data-person="${ADMIN.sub}"]`);
  assert.deepEqual(shown([...adminRow().querySelectorAll("[data-make]")]).map((button) => button.dataset.make), ["owner"]);
  assert.equal(page.one('[data-input="invite_role"]:checked').value, "admin", "an invitation is for the lower role unless chosen otherwise");

  page.set("invite_email", "not-an-address");
  page.submit();
  assert.match(page.error("invite_email"), /name@example\.com/);

  page.set("invite_email", "jo@example.test");
  page.submit();
  await settle();
  assert.deepEqual(net.requests.at(-1).body, { values: { invite_email: "jo@example.test", invite_role: "admin" } });
  assert.equal(personRows(page).length, 3);
  assert.equal(page.one("[data-notice]").hidden, false);
  assert.match(page.one("[data-changes]").textContent, /invited jo@example\.test as administrator/);

  page.click(adminRow().querySelector('[data-make="owner"]'));
  await settle();
  assert.deepEqual([net.requests.at(-1).method, net.requests.at(-1).body], ["PUT", { role: "owner" }]);
  assert.equal(adminRow().querySelector("[data-person-role]").textContent, "Owner");

  page.click(adminRow().querySelector("[data-remove]"));
  await settle();
  assert.equal(net.requests.at(-1).method, "DELETE");
  assert.equal(personRows(page).length, 1);
});

test("an administrator sees the people but cannot invite, change or remove anyone", async () => {
  const net = network({ [`GET ${data.api.account}`]: () => accountOf(ADMIN) });
  const page = await openLive("people", sessionWith(memoryStorage()), net);
  assert.equal(personRows(page).length, 2);
  assert.equal(page.one("[data-invite]").hidden, true);
  assert.ok(page.all("[data-person-manage]").every((controls) => controls.hidden));
});

test("what the API refuses about a person is shown and the list is left as it was", async () => {
  const net = network({
    [`GET ${data.api.account}`]: () => accountOf(OWNER, { people: [OWNER] }),
    [`DELETE ${data.api.people}/${OWNER.sub}`]: () => ({ status: 409, body: { error: "last_owner", problems: ["A firm's account must always have at least one owner."] } }),
  });
  const page = await openLive("people", sessionWith(memoryStorage()), net);
  page.click(page.one("[data-remove]"));
  await settle();
  assert.match(page.one("[data-invite] [data-summary]").textContent, /at least one owner/);
  assert.equal(personRows(page).length, 1);
});

test("only an owner is offered the agreement to accept", async () => {
  const asAdmin = await openLive("agreements", sessionWith(memoryStorage()), network({ [`GET ${data.api.account}`]: () => accountOf(ADMIN) }));
  assert.equal(asAdmin.one("[data-form]").hidden, true);
  assert.equal(asAdmin.one("[data-owner-only]").hidden, false);

  const asOwner = await openLive("agreements", sessionWith(memoryStorage()), network({ [`GET ${data.api.account}`]: () => accountOf(OWNER) }));
  assert.equal(asOwner.one("[data-form]").hidden, false);
  assert.equal(asOwner.one("[data-owner-only]").hidden, true);
});

test("an invited person signs in with the temporary password and chooses their own", async () => {
  const storage = memoryStorage();
  const net = network({
    InitiateAuth: () => ({ body: { ChallengeName: "NEW_PASSWORD_REQUIRED", Session: "session-1" } }),
    RespondToAuthChallenge: () => ({ body: TOKENS }),
  });
  const page = await openLive("signin", storage, net);
  const form = page.one('[data-panel="signin"] form');
  page.set("signin_email", ADMIN.email, form);
  page.set("signin_password", "Temporary-1!", form);
  page.submit(form);
  await settle();
  assert.equal(page.one('[data-panel="new-password"]').hidden, false);
  assert.deepEqual(page.visited, [], "nobody is signed in on a temporary password");

  const choose = page.one('[data-panel="new-password"] form');
  page.set("new_password", PASSWORD, choose);
  page.set("new_password_again", PASSWORD, choose);
  page.submit(choose);
  await settle();
  const answer = net.requests.at(-1);
  assert.equal(answer.target, "RespondToAuthChallenge");
  assert.deepEqual(answer.body.ChallengeResponses, { USERNAME: ADMIN.email, NEW_PASSWORD: PASSWORD });
  assert.equal(answer.body.Session, "session-1");
  assert.deepEqual(page.visited, [routes.portal]);
  assert.ok(!everythingStored(storage).includes(PASSWORD));
});
