// Your details: the person's and the firm's details given at sign-up, to check
// and change. Saved only when everything on show is valid.

import { loadAccount } from "./account.js";
import { applyVisibility, fillValues, readValues, showErrors, showSummary } from "./form.js";
import { focusOn, pageData } from "./page.js";
import { validateFields, visibleValues } from "./validate.js";

const data = pageData();
const form = document.querySelector("[data-form]");
const summary = form.querySelector("[data-summary]");
const savedPanel = document.querySelector("[data-saved]");
const fields = data.steps.flatMap((step) => step.fields);
const groups = data.steps.flatMap((step) => step.groups);
const account = await loadAccount(data).catch(() => null);

function refreshVisibility() {
  const entered = readValues(form, fields);
  applyVisibility(form, fields, entered);
  applyVisibility(form, groups, entered);
}

form.addEventListener("input", refreshVisibility);
form.addEventListener("change", refreshVisibility);

form.addEventListener("submit", (event) => {
  event.preventDefault();
  savedPanel.hidden = true;
  const entered = readValues(form, fields);
  const problems = showErrors(form, fields, validateFields(fields, entered, data.messages));
  showSummary(summary, problems);
  if (problems.length > 0 || !account) return;

  account.save(
    "signup",
    { values: visibleValues(fields, entered) },
    () => {
      account.clearDraft();
      savedPanel.hidden = false;
      focusOn(savedPanel);
    },
    (messages) => showSummary(summary, messages.map((message) => ({ message }))),
  );
});

// What was saved, or what was typed at sign-up if it was never saved.
fillValues(form, fields, account?.state().signup?.values ?? account?.draft() ?? {});
refreshVisibility();
