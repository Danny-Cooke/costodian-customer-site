// Connects field definitions to the inputs the build rendered from them.
// Inputs are found by data-input="<field id>" inside a root element, so the
// same code serves a whole form or one repeated row.

import { isVisible } from "./validate.js";

const INVALID_CLASS = "invalid";

function wrapperOf(root, id) {
  return root.querySelector(`[data-field="${CSS.escape(id)}"]`);
}

function inputsOf(root, id) {
  return [...root.querySelectorAll(`[data-input="${CSS.escape(id)}"]`)];
}

export function readValues(root, fields) {
  const values = {};
  for (const field of fields) {
    const inputs = inputsOf(root, field.id);
    if (field.type === "note" || inputs.length === 0) continue;
    if (field.type === "checkbox") values[field.id] = inputs[0].checked;
    else if (field.type === "radio") values[field.id] = inputs.find((input) => input.checked)?.value ?? "";
    else values[field.id] = field.secret ? inputs[0].value : inputs[0].value.trim();
  }
  return values;
}

export function fillValues(root, fields, values) {
  for (const field of fields) {
    if (!(field.id in values)) continue;
    const inputs = inputsOf(root, field.id);
    if (inputs.length === 0) continue;
    const value = values[field.id];
    if (field.type === "checkbox") inputs[0].checked = Boolean(value);
    else if (field.type === "radio") inputs.forEach((input) => (input.checked = input.value === value));
    else inputs[0].value = value ?? "";
  }
}

// items are fields, groups or sections: anything with an id and a show_if.
export function applyVisibility(root, items, values, attribute = "data-field") {
  for (const item of items) {
    if (!item.show_if) continue;
    const element = root.querySelector(`[${attribute}="${CSS.escape(item.id)}"]`);
    if (element) element.hidden = !isVisible(item, values);
  }
}

// Shows each message beside its field. Returns [{ message, input }] in field order.
export function showErrors(root, fields, errors) {
  const shown = [];
  for (const field of fields) {
    const wrapper = wrapperOf(root, field.id);
    if (!wrapper) continue;
    const message = errors[field.id] ?? "";
    const inputs = inputsOf(root, field.id);
    const slot = wrapper.querySelector("[data-error]");
    wrapper.classList.toggle(INVALID_CLASS, Boolean(message));
    inputs.forEach((input) => input.setAttribute("aria-invalid", String(Boolean(message))));
    if (slot) {
      slot.textContent = message;
      slot.hidden = !message;
    }
    if (message) shown.push({ message, input: inputs[0] });
  }
  return shown;
}

// Fills the "There is a problem" box and moves focus to it, or hides it.
export function showSummary(summary, problems) {
  const list = summary.querySelector("ul");
  list.replaceChildren();
  for (const problem of problems) {
    const item = document.createElement("li");
    if (problem.input?.id) {
      const link = document.createElement("a");
      link.href = `#${problem.input.id}`;
      link.textContent = problem.message;
      item.append(link);
    } else {
      item.textContent = problem.message;
    }
    list.append(item);
  }
  summary.hidden = problems.length === 0;
  if (problems.length > 0) summary.focus();
}

export function showMessage(element, message) {
  if (!element) return;
  element.textContent = message;
  element.hidden = !message;
}
