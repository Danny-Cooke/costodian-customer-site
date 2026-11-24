// The sign-up steps: one shown at a time, each checked before the next, with a
// review of everything entered on the last one. With sign-in switched on, the
// last step creates the sign-in, asks for the code sent by email, and then
// saves the details to the new account.

import { openAccount } from "./account.js";
import { applyVisibility, fillValues, readValues, showErrors, showMessage, showSummary } from "./form.js";
import { focusOn, pageData } from "./page.js";
import { createPractice } from "./practice.js";
import { displayValue, isVisible, validateFields, visibleValues } from "./validate.js";

const data = pageData();
const account = openAccount(data);
const form = document.querySelector("[data-form]");
const summary = form.querySelector("[data-summary]");
const review = form.querySelector("[data-review]");
const verify = document.querySelector("[data-verify]");
const steps = data.steps;
const allFields = steps.flatMap((step) => step.fields);
const allGroups = steps.flatMap((step) => step.groups);
const profileFields = steps.filter((step) => step.profile).flatMap((step) => step.fields);
const practice = createPractice(form, data);
// A step's questions: its own, or those of the kind of account chosen.
const fieldsOf = (step) => (step.kind === "types" ? practice.fields() : step.fields);
const lastIndex = steps.length - 1;
const identity = data.identity;
let current = 0;
// Held only while this page is open, to sign in once the email is confirmed.
let credentials = null;

const sectionOf = (step) => form.querySelector(`[data-step="${CSS.escape(step.id)}"]`);
const values = () => ({ ...readValues(form, allFields), ...practice.values() });
// What is worth keeping of the answers given: the fields on show.
const kept = (fields) => ({ ...visibleValues(fields, readValues(form, fields)), ...practice.kept() });
const asProblems = (messages) => messages.map((message) => ({ message }));

function refreshVisibility() {
  const entered = values();
  applyVisibility(form, allFields, entered);
  applyVisibility(form, allGroups, entered);
  practice.refresh();
}

function renderReview() {
  const entered = values();
  review.replaceChildren();
  steps.slice(0, lastIndex).forEach((step) => {
    const shown = fieldsOf(step).filter((field) => field.type !== "note" && !field.secret && isVisible(field, entered));
    if (shown.length === 0) return;
    const heading = document.createElement("h3");
    heading.textContent = step.title;
    const list = document.createElement("dl");
    for (const field of shown) {
      const term = document.createElement("dt");
      term.textContent = field.label.charAt(0).toUpperCase() + field.label.slice(1);
      const detail = document.createElement("dd");
      detail.textContent = displayValue(field, entered[field.id], data.labels);
      list.append(term, detail);
    }
    review.append(heading, list);
  });
}

function show(index, moveFocus = true) {
  current = index;
  steps.forEach((step, position) => {
    sectionOf(step).hidden = position !== index;
    const marker = document.querySelector(`[data-progress-step="${CSS.escape(step.id)}"]`);
    if (position === index) marker.setAttribute("aria-current", "step");
    else marker.removeAttribute("aria-current");
    marker.classList.toggle("done", position < index);
  });
  showSummary(summary, []);
  if (index === lastIndex) renderReview();
  if (moveFocus) focusOn(sectionOf(steps[index]).querySelector("h2"));
}

function finish() {
  account.save(
    "signup",
    { values: kept(account.live ? profileFields : allFields) },
    () => {
      account.clearDraft();
      window.location.assign(data.routes.portal);
    },
    // Signed in, but the details did not save: the details page asks again.
    () => window.location.assign(data.routes[data.detailsRoute]),
  );
}

function askForCode() {
  form.hidden = true;
  verify.hidden = false;
  verify.querySelector("[data-verify-email]").textContent = credentials.email;
  focusOn(verify.querySelector("h2"));
}

async function createSignIn(entered) {
  credentials = { email: entered[identity.person_email_field], password: entered[identity.password_field] };
  try {
    await account.auth.signUp(credentials.email, credentials.password, entered[identity.person_name_field]);
    askForCode();
  } catch (error) {
    showSummary(summary, asProblems([data.messages[error.messageKey]]));
  }
}

form.addEventListener("input", refreshVisibility);
form.addEventListener("change", refreshVisibility);

form.addEventListener("click", (event) => {
  if (event.target.closest("[data-back]")) show(current - 1);
});

form.addEventListener("submit", (event) => {
  event.preventDefault();
  const step = steps[current];
  const entered = values();
  const problems =
    step.kind === "types"
      ? practice.check(data.messages)
      : showErrors(form, step.fields, validateFields(step.fields, entered, data.messages));
  showSummary(summary, problems);
  if (problems.length > 0) return;

  if (current < lastIndex) {
    account.saveDraft(kept(allFields));
    show(current + 1);
    return;
  }

  if (account.live) createSignIn(entered);
  else finish();
});

if (verify) {
  const verifyForm = verify.querySelector("[data-verify-form]");
  const verifySummary = verify.querySelector("[data-summary]");
  const notice = verify.querySelector("[data-verify-notice]");

  verifyForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    showMessage(notice, "");
    const entered = readValues(verifyForm, data.verifyFields);
    const problems = showErrors(verifyForm, data.verifyFields, validateFields(data.verifyFields, entered, data.messages));
    showSummary(verifySummary, problems);
    if (problems.length > 0) return;
    try {
      await account.auth.confirm(credentials.email, entered[data.verifyFields[0].id]);
      await account.auth.signIn(credentials.email, credentials.password);
      credentials = null;
      finish();
    } catch (error) {
      showSummary(verifySummary, asProblems([data.messages[error.messageKey]]));
    }
  });

  verify.querySelector("[data-resend]").addEventListener("click", async () => {
    try {
      await account.auth.resend(credentials.email);
      showMessage(notice, data.messages.code_sent);
    } catch (error) {
      showSummary(verifySummary, asProblems([data.messages[error.messageKey]]));
    }
  });
}

const earlier = { ...(account.state().signup?.values ?? {}), ...account.draft() };
fillValues(form, allFields, earlier);
// The kind of account has to be chosen before its questions can be filled.
practice.refresh();
practice.fill(earlier);
refreshVisibility();
show(0, false);
