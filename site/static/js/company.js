// Company information: the firm's billing set-up and its positions.
// Saved only when everything on show is valid.

import { applyVisibility, fillValues, readValues, showErrors, showMessage, showSummary } from "./form.js";
import { loadAccount } from "./account.js";
import { focusOn, pageData } from "./page.js";
import { validateFields, visibleValues } from "./validate.js";

const data = pageData();
const form = document.querySelector("[data-form]");
const summary = form.querySelector("[data-summary]");
const savedPanel = document.querySelector("[data-saved]");
const fundingError = form.querySelector("[data-funding-error]");

const sections = data.sections;
const fields = sections.flatMap((section) => section.fields);
const groups = sections.flatMap((section) => section.groups);

const values = () => readValues(form, fields);

function refreshVisibility() {
  const entered = values();
  applyVisibility(form, fields, entered);
  applyVisibility(form, groups, entered);
  applyVisibility(form, sections, entered, "data-section");
}

form.addEventListener("input", refreshVisibility);
form.addEventListener("change", refreshVisibility);

form.addEventListener("submit", (event) => {
  event.preventDefault();
  savedPanel.hidden = true;
  const entered = values();
  const problems = showErrors(form, fields, validateFields(fields, entered, data.messages));

  const hasFunding = data.fundingIds.some((id) => entered[id] === true);
  showMessage(fundingError, hasFunding ? "" : data.messages.funding_required);
  if (!hasFunding) problems.unshift({ message: data.messages.funding_required });

  showSummary(summary, problems);
  if (problems.length > 0 || !account) return;

  account.save(
    "company",
    { values: visibleValues(fields, entered) },
    () => {
      savedPanel.hidden = false;
      focusOn(savedPanel);
    },
    (messages) => showSummary(summary, messages.map((message) => ({ message }))),
  );
});

const account = await loadAccount(data).catch(() => null);
const saved = account?.state().company;

// The versions on offer are read with the account, so a new one appears without
// the site being rebuilt. A firm that has chosen none yet is offered the newest.
const versions = account?.state().versions ?? data.versions;
const versionSelect = form.querySelector(`[data-input="${CSS.escape(data.versionField)}"]`);
versionSelect.replaceChildren(
  ...versions.map((version) => {
    const option = document.createElement("option");
    option.value = version;
    option.textContent = version;
    return option;
  }),
);
versionSelect.value = versions.at(-1) ?? "";

fillValues(form, fields, saved?.values ?? {});
refreshVisibility();
