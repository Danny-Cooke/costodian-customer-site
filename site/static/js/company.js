// Company information: the firm's billing set-up, fee earners and positions.
// Saved only when everything on show is valid.

import { applyVisibility, fillValues, readValues, showErrors, showMessage, showSummary } from "./form.js";
import { loadAccount } from "./account.js";
import { focusOn, pageData } from "./page.js";
import { validateFields, visibleValues } from "./validate.js";

const ROW_TOKEN = "__row__";

const data = pageData();
const form = document.querySelector("[data-form]");
const summary = form.querySelector("[data-summary]");
const savedPanel = document.querySelector("[data-saved]");
const rows = form.querySelector("[data-rows]");
const rowTemplate = form.querySelector("[data-row-template]");
const fundingError = form.querySelector("[data-funding-error]");
const earnersError = form.querySelector("[data-fee-earners-error]");

const sections = data.sections;
const fields = sections.flatMap((section) => section.fields);
const groups = sections.flatMap((section) => section.groups);
const earnerFields = data.feeEarners.fields;
let nextRow = 0;

const values = () => readValues(form, fields);
const rowElements = () => [...rows.querySelectorAll("[data-row]")];

function refreshVisibility() {
  const entered = values();
  applyVisibility(form, fields, entered);
  applyVisibility(form, groups, entered);
  applyVisibility(form, sections, entered, "data-section");
  for (const row of rowElements()) {
    applyVisibility(row, earnerFields, readValues(row, earnerFields));
  }
}

function addRow(entered = {}) {
  // The template is this site's own markup; only the row number is filled in.
  const holder = document.createElement("div");
  holder.innerHTML = rowTemplate.innerHTML.replaceAll(ROW_TOKEN, String(nextRow));
  nextRow += 1;
  const row = holder.querySelector("[data-row]");
  rows.append(row);
  fillValues(row, earnerFields, entered);
  applyVisibility(row, earnerFields, readValues(row, earnerFields));
  return row;
}

form.addEventListener("input", refreshVisibility);
form.addEventListener("change", refreshVisibility);

form.addEventListener("click", (event) => {
  if (event.target.closest("[data-add-row]")) {
    focusOn(addRow().querySelector("input"));
    return;
  }
  const remove = event.target.closest("[data-remove-row]");
  if (remove) remove.closest("[data-row]").remove();
});

form.addEventListener("submit", (event) => {
  event.preventDefault();
  savedPanel.hidden = true;
  const entered = values();
  const problems = showErrors(form, fields, validateFields(fields, entered, data.messages));

  const hasFunding = data.fundingIds.some((id) => entered[id] === true);
  showMessage(fundingError, hasFunding ? "" : data.messages.funding_required);
  if (!hasFunding) problems.unshift({ message: data.messages.funding_required });

  const earnerRows = rowElements();
  showMessage(earnersError, earnerRows.length > 0 ? "" : data.messages.fee_earner_required);
  if (earnerRows.length === 0) problems.push({ message: data.messages.fee_earner_required });

  const feeEarners = earnerRows.map((row) => {
    const rowValues = readValues(row, earnerFields);
    problems.push(...showErrors(row, earnerFields, validateFields(earnerFields, rowValues, data.messages)));
    return visibleValues(earnerFields, rowValues);
  });

  showSummary(summary, problems);
  if (problems.length > 0 || !account) return;

  account.save(
    "company",
    { values: visibleValues(fields, entered), feeEarners, registerVersion: data.registerVersion },
    () => {
      savedPanel.hidden = false;
      focusOn(savedPanel);
    },
    (messages) => showSummary(summary, messages.map((message) => ({ message }))),
  );
});

const account = await loadAccount(data).catch(() => null);
const saved = account?.state().company;
fillValues(form, fields, saved?.values ?? {});
const earlier = saved?.feeEarners ?? [];
if (earlier.length > 0) earlier.forEach((earner) => addRow(earner));
else addRow();
refreshVisibility();
