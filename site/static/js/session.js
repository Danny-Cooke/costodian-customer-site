// Runs on every portal page: sends a visitor who is not signed in away, shows
// who is signed in, and handles sign out.

import { loadAccount, openAccount } from "./account.js";
import { pageData } from "./page.js";

const data = pageData();
const entry = data.auth.enabled ? data.routes.signin : data.routes.signup;
const account = await loadAccount(data).catch(() => null);

if (!account || !account.signedIn()) {
  window.location.replace(entry);
} else {
  const entered = account.state().signup?.values;
  if (!entered && data.route !== data.detailsRoute) {
    // Signed in, but the firm's details were never saved: ask for them first.
    window.location.replace(data.routes[data.detailsRoute]);
  }
  const name = document.querySelector("[data-user-name]");
  const firm = document.querySelector("[data-firm-name]");
  if (name) name.textContent = entered?.[data.identity.person_name_field] ?? "";
  if (firm) firm.textContent = entered?.[data.identity.firm_name_field] ?? "";
}

document.querySelector("[data-sign-out]")?.addEventListener("click", () => {
  openAccount(data).signOut(() => window.location.assign(data.routes.home));
});
