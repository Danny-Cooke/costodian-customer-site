// My account: marks each step done or to do, and shows whether the firm's
// account can be created yet.

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
  const done = Boolean(status[step.id]);
  badge.textContent = done ? badge.dataset.labelDone : badge.dataset.labelTodo;
  badge.classList.toggle("done", done);
}

const uid = account?.state().uid;
const uidPanel = document.querySelector("[data-uid-panel]");
uidPanel.querySelector("[data-uid]").textContent = uid ?? "";
uidPanel.hidden = !uid;

const panel = document.querySelector("[data-account]");
panel.querySelector('[data-when="waiting"]').hidden = status.ready;
panel.querySelector('[data-when="ready"]').hidden = !status.ready;
