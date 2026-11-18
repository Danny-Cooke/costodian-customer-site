// The data processing agreement: shows whether this version has been accepted,
// and records who accepted it and when.

import { loadAccount } from "./account.js";
import { fillValues, readValues, showErrors, showSummary } from "./form.js";
import { focusOn, pageData } from "./page.js";
import { setupStatus } from "./status.js";
import { validateFields } from "./validate.js";

const data = pageData();
const form = document.querySelector("[data-form]");
const summary = form.querySelector("[data-summary]");
const accepted = document.querySelector("[data-accepted]");
const ownerOnly = document.querySelector("[data-owner-only]");
const fields = data.fields;
const nameField = fields[0];
const account = await loadAccount(data).catch(() => null);

function render(moveFocus) {
  const state = account?.state() ?? {};
  const done = setupStatus(state, data.agreement.version).agreement;
  const mayAccept = account?.can("accept") ?? false;
  form.hidden = done || !mayAccept;
  accepted.hidden = !done;
  ownerOnly.hidden = done || mayAccept;
  if (!done) return;
  accepted.querySelector("[data-accepted-name]").textContent = state.agreement.acceptedBy;
  accepted.querySelector("[data-accepted-at]").textContent = new Date(state.agreement.acceptedAt).toLocaleString();
  if (moveFocus) focusOn(accepted);
}

form.addEventListener("submit", (event) => {
  event.preventDefault();
  if (!account) return;
  const entered = readValues(form, fields);
  const problems = showErrors(form, fields, validateFields(fields, entered, data.messages));
  showSummary(summary, problems);
  if (problems.length > 0) return;

  account.accept(
    entered,
    nameField.id,
    () => render(true),
    (messages) => showSummary(summary, messages.map((message) => ({ message }))),
  );
});

accepted.querySelector("[data-print]").addEventListener("click", () => window.print());

fillValues(form, [nameField], {
  [nameField.id]: account?.state().signup?.values?.[data.identity.person_name_field] ?? "",
});
render(false);
