// People: who can manage the firm's account. Everyone sees the list; an owner
// can invite a person, change a role and remove a person. Below it, the record
// of who changed what.

import { loadAccount } from "./account.js";
import { fillValues, readValues, showErrors, showMessage, showSummary } from "./form.js";
import { focusOn, pageData } from "./page.js";
import { format, validateFields } from "./validate.js";

const data = pageData();
const list = document.querySelector("[data-people]");
const rowTemplate = document.querySelector("[data-person-template]");
const changes = document.querySelector("[data-changes]");
const invitePanel = document.querySelector("[data-invite]");
const form = invitePanel.querySelector("[data-form]");
const summary = form.querySelector("[data-summary]");
const notice = document.querySelector("[data-notice]");
const fields = data.inviteFields;
const account = await loadAccount(data).catch(() => null);
const asProblems = (messages) => messages.map((message) => ({ message }));

function failed(messages) {
  showMessage(notice, "");
  showSummary(summary, asProblems(messages));
}

function succeeded(message) {
  showSummary(summary, []);
  render();
  showMessage(notice, message);
  focusOn(notice);
}

function render() {
  const state = account?.state() ?? {};
  const mayManage = account?.can("people") ?? false;
  invitePanel.hidden = !mayManage;

  list.replaceChildren();
  for (const person of state.people ?? []) {
    const row = rowTemplate.content.firstElementChild.cloneNode(true);
    row.dataset.person = person.sub;
    row.querySelector("[data-person-email]").textContent = person.email;
    row.querySelector("[data-person-role]").textContent = data.roles[person.role]?.label ?? person.role;
    row.querySelector("[data-person-you]").hidden = person.sub !== state.member?.sub;
    const manage = row.querySelector("[data-person-manage]");
    manage.hidden = !mayManage;
    for (const button of manage.querySelectorAll("[data-make]")) button.hidden = button.dataset.make === person.role;
    list.append(row);
  }

  changes.replaceChildren();
  for (const change of state.changes ?? []) {
    const item = document.createElement("li");
    const what = format(data.changes[change.what] ?? change.what, {
      subject: change.subject ?? "",
      role: (data.roles[change.role]?.label ?? change.role ?? "").toLowerCase(),
    });
    const when = document.createElement("time");
    when.dateTime = change.at;
    when.textContent = new Date(change.at).toLocaleString();
    item.append(`${change.by} ${what} `, when);
    changes.append(item);
  }
}

form.addEventListener("submit", (event) => {
  event.preventDefault();
  if (!account) return;
  const entered = readValues(form, fields);
  const problems = showErrors(form, fields, validateFields(fields, entered, data.messages));
  showSummary(summary, problems);
  if (problems.length > 0) return;
  account.invite(
    entered,
    () => {
      fillValues(form, [fields[0]], { [fields[0].id]: "" });
      succeeded(data.messages.invite_sent);
    },
    failed,
  );
});

list.addEventListener("click", (event) => {
  if (!account) return;
  const row = event.target.closest("[data-person]");
  const make = event.target.closest("[data-make]");
  if (make) account.changeRole(row.dataset.person, make.dataset.make, () => succeeded(data.messages.role_changed), failed);
  if (event.target.closest("[data-remove]")) {
    account.removePerson(row.dataset.person, () => succeeded(data.messages.member_removed), failed);
  }
});

render();
