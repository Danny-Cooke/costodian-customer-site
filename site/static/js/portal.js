// My account: marks each step done or to do, and shows whether the firm's
// account can be created yet. Until the account has been read the page says
// it is checking, and if it cannot be read it says so: a step is never shown
// as still to do when the truth is that nobody has looked yet.

import { loadAccount } from "./account.js";
import { pageData } from "./page.js";
import { setupStatus } from "./status.js";

const data = pageData();
const account = await loadAccount(data).catch(() => null);
const status = setupStatus(account?.state() ?? {}, data.agreement.version);

for (const step of data.setupSteps) {
  const row = document.querySelector(`[data-setup-step="${CSS.escape(step.id)}"]`);
  const badge = row?.querySelector("[data-badge]");
  if (!badge) continue;
  if (!account) {
    badge.textContent = badge.dataset.labelUnknown;
    continue;
  }
  const done = Boolean(status[step.id]);
  badge.textContent = done ? badge.dataset.labelDone : badge.dataset.labelTodo;
  badge.classList.remove("pending");
  badge.classList.toggle("done", done);
}

const uid = account?.state().uid;
const uidPanel = document.querySelector("[data-uid-panel]");
uidPanel.querySelector("[data-uid]").textContent = uid ?? "";
uidPanel.hidden = !uid;

const panel = document.querySelector("[data-account]");
panel.querySelector('[data-when="checking"]').hidden = Boolean(account);
panel.querySelector('[data-when="waiting"]').hidden = !account || status.ready;
panel.querySelector('[data-when="ready"]').hidden = !account || !status.ready;
