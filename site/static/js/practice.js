// The questions for the kind of account chosen. Each kind has a block of its
// own in the page; only the chosen kind's block is shown, read, checked and
// kept. The other kinds' questions take no part.

import { applyVisibility, fillValues, readValues, showErrors } from "./form.js";
import { validateFields, visibleValues } from "./validate.js";

export function createPractice(form, data) {
  const select = form.querySelector(`[data-input="${CSS.escape(data.identity.account_type_field)}"]`);
  const blockOf = (kind) => form.querySelector(`[data-type="${CSS.escape(kind.id)}"]`);
  const chosen = () => data.types.find((kind) => kind.id === select.value) ?? null;
  const read = (kind) => readValues(blockOf(kind), kind.fields);

  return {
    chosen,
    fields: () => chosen()?.fields ?? [],
    values: () => (chosen() ? read(chosen()) : {}),
    kept: () => (chosen() ? visibleValues(chosen().fields, read(chosen())) : {}),

    // Shows the chosen kind's block and hides the rest.
    refresh() {
      const kind = chosen();
      for (const other of data.types) blockOf(other).hidden = other !== kind;
      if (!kind) return;
      const entered = read(kind);
      applyVisibility(blockOf(kind), kind.fields, entered);
      applyVisibility(blockOf(kind), kind.groups, entered);
    },

    fill(values) {
      const kind = chosen();
      if (kind) fillValues(blockOf(kind), kind.fields, values);
    },

    // Checks the chosen kind's questions. Returns [{ message, input }].
    check(messages) {
      const kind = chosen();
      if (!kind) return [];
      return showErrors(blockOf(kind), kind.fields, validateFields(kind.fields, read(kind), messages));
    },
  };
}
