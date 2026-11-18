// Sign in, confirm an email address that was never confirmed, and reset a
// forgotten password. One panel is shown at a time.

import { openAccount } from "./account.js";
import { readValues, showErrors, showMessage, showSummary } from "./form.js";
import { focusOn, pageData } from "./page.js";
import { validateFields } from "./validate.js";

const data = pageData();
const account = openAccount(data);
const panels = [...document.querySelectorAll("[data-panel]")];
const notice = document.querySelector("[data-notice]");
const asProblems = (messages) => messages.map((message) => ({ message }));
// Held only while this page is open.
let credentials = null;
let resetEmail = "";
let challenge = "";

function show(name, moveFocus = true) {
  for (const panel of panels) panel.hidden = panel.dataset.panel !== name;
  if (moveFocus) focusOn(document.querySelector(`[data-panel="${name}"] h2`));
}

// Wires one panel's form: checks its fields, then runs the action, showing any
// failure in that panel's own summary.
function wire(name, fields, action) {
  const form = document.querySelector(`[data-panel="${name}"] form`);
  const summary = form.querySelector("[data-summary]");
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    showMessage(notice, "");
    const entered = readValues(form, fields);
    const problems = showErrors(form, fields, validateFields(fields, entered, data.messages));
    showSummary(summary, problems);
    if (problems.length > 0) return;
    try {
      await action(entered);
    } catch (error) {
      if (error.newPasswordNeeded && credentials) {
        challenge = error.session;
        show("new-password");
        return;
      }
      if (error.notConfirmed && credentials) {
        await account.auth.resend(credentials.email).catch(() => {});
        show("verify");
        return;
      }
      showSummary(summary, asProblems([data.messages[error.messageKey] ?? data.messages.auth_failed]));
    }
  });
}

if (!account.live) {
  // A build without sign-in is the preview: sign-up is the only way in.
  window.location.replace(data.routes.signup);
} else {
  const [emailField, passwordField] = data.signinFields;
  const [codeField] = data.verifyFields;
  const [resetEmailField] = data.resetRequestFields;
  const [resetCodeField, resetPasswordField] = data.resetConfirmFields;

  wire("signin", data.signinFields, async (entered) => {
    credentials = { email: entered[emailField.id], password: entered[passwordField.id] };
    await account.auth.signIn(credentials.email, credentials.password);
    credentials = null;
    window.location.assign(data.routes.portal);
  });

  wire("verify", data.verifyFields, async (entered) => {
    await account.auth.confirm(credentials.email, entered[codeField.id]);
    await account.auth.signIn(credentials.email, credentials.password);
    credentials = null;
    window.location.assign(data.routes.portal);
  });

  const [newPasswordField] = data.newPasswordFields;
  wire("new-password", data.newPasswordFields, async (entered) => {
    await account.auth.newPassword(credentials.email, entered[newPasswordField.id], challenge);
    credentials = null;
    challenge = "";
    window.location.assign(data.routes.portal);
  });

  wire("reset-request", data.resetRequestFields, async (entered) => {
    resetEmail = entered[resetEmailField.id];
    await account.auth.forgot(resetEmail);
    show("reset-confirm");
  });

  wire("reset-confirm", data.resetConfirmFields, async (entered) => {
    await account.auth.reset(resetEmail, entered[resetCodeField.id], entered[resetPasswordField.id]);
    show("signin");
    showMessage(notice, data.messages.reset_done);
  });

  document.addEventListener("click", (event) => {
    const target = event.target.closest("[data-show]");
    if (target) show(target.dataset.show);
  });

  show("signin", false);
}
