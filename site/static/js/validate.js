// Checks values against the field definitions in forms.json. No DOM here, so
// the same rules can be tested on their own.

export function isVisible(item, values) {
  const condition = item.show_if;
  if (!condition) return true;
  const value = values[condition.field];
  if ("equals" in condition) return value === condition.equals;
  if ("in" in condition) return condition.in.includes(value);
  return true;
}

export function isEmpty(value) {
  return value === undefined || value === null || value === "" || value === false;
}

export function format(template, field) {
  return template.replace(/\{(\w+)\}/g, (whole, name) => (name in field ? String(field[name]) : whole));
}

function requiredMessage(field, messages) {
  if (field.type === "checkbox") return messages.required_tick;
  if (field.type === "radio" || field.type === "select") return messages.required_choice;
  return messages.required;
}

export function validateField(field, values, messages) {
  if (field.type === "note" || !isVisible(field, values)) return null;
  const value = values[field.id];
  if (isEmpty(value)) {
    return field.required ? format(requiredMessage(field, messages), field) : null;
  }
  if (field.type === "number") {
    const number = Number(value);
    if (!Number.isFinite(number)) return format(messages.number, field);
    if (typeof field.min === "number" && number < field.min) return format(messages.too_small, field);
    if (typeof field.max === "number" && number > field.max) return format(messages.too_large, field);
    return null;
  }
  if (typeof value === "string") {
    if (field.max_length && value.length > field.max_length) return format(messages.too_long, field);
    if (field.min_length && value.length < field.min_length) return format(messages.too_short, field);
    if (field.pattern && !new RegExp(field.pattern).test(value)) {
      return field.pattern_message ?? format(messages.pattern, field);
    }
    if (field.matches && value !== values[field.matches]) return format(messages.mismatch, field);
  }
  return null;
}

// Returns { fieldId: message } for the fields that are wrong; empty when all pass.
export function validateFields(fields, values, messages) {
  const errors = {};
  for (const field of fields) {
    const message = validateField(field, values, messages);
    if (message) errors[field.id] = message;
  }
  return errors;
}

// The values worth keeping: fields that are on show and are not just notes.
// A secret field, such as a password, is never kept.
export function visibleValues(fields, values) {
  const kept = {};
  for (const field of fields) {
    if (field.type !== "note" && !field.secret && isVisible(field, values) && field.id in values) {
      kept[field.id] = values[field.id];
    }
  }
  return kept;
}

// What a person reads back on a review screen for one field.
export function displayValue(field, value, labels) {
  if (field.type === "checkbox") return value ? labels.yes : labels.no;
  if (isEmpty(value)) return labels.blank;
  const option = (field.options ?? []).find((candidate) => candidate.value === value);
  return option ? option.label : String(value);
}
