// What every page script starts from: the data the build wrote into the page,
// and the store for this visitor's entries.

import { browserStorage, createStore } from "./store.js";

export function pageData() {
  return JSON.parse(document.querySelector('script[type="application/json"]').textContent);
}

export function pageStore(data) {
  return createStore(data.storageKey, browserStorage(`${data.storageKey}-probe`));
}

export function now() {
  return new Date().toISOString();
}

export function focusOn(element) {
  if (!element) return;
  element.focus();
  element.scrollIntoView({ block: "start" });
}
