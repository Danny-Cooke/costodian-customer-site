import assert from "node:assert/strict";
import { test } from "node:test";

import { isSignedUp, setupStatus } from "../../site/static/js/status.js";
import { createStore, memoryStorage } from "../../site/static/js/store.js";

const VERSION = "v1";

test("nothing is done for a new visitor", () => {
  assert.deepEqual(setupStatus({}, VERSION), { details: false, company: false, agreement: false, ready: false });
  assert.equal(isSignedUp({}), false);
  assert.equal(isSignedUp({ signupDraft: { person_name: "Sam" } }), false);
});

test("the account is ready only when company information is saved and this version is accepted", () => {
  const company = { savedAt: "2026-11-17T10:00:00Z" };
  const agreement = { version: VERSION, acceptedAt: "2026-11-17T10:05:00Z" };
  assert.equal(setupStatus({ company }, VERSION).ready, false);
  assert.equal(setupStatus({ agreement }, VERSION).ready, false);
  const signup = { completedAt: "2026-11-17T10:00:00Z" };
  assert.equal(setupStatus({ company, agreement }, VERSION).ready, false, "the firm's details are part of set-up");
  assert.deepEqual(setupStatus({ signup, company, agreement }, VERSION), {
    details: true,
    company: true,
    agreement: true,
    ready: true,
  });
});

test("accepting an older version does not count once the agreement changes", () => {
  const state = { company: { savedAt: "x" }, agreement: { version: "v0", acceptedAt: "x" } };
  assert.equal(setupStatus(state, VERSION).agreement, false);
  assert.equal(setupStatus(state, VERSION).ready, false);
});

test("the store saves, loads and clears under its own key", () => {
  const storage = memoryStorage();
  const store = createStore("k", storage);
  assert.deepEqual(store.load(), {});
  assert.equal(store.save({ a: 1 }), true);
  assert.deepEqual(store.load(), { a: 1 });
  assert.deepEqual(createStore("other", storage).load(), {});
  store.clear();
  assert.deepEqual(store.load(), {});
});

test("damaged or unexpected stored data reads as empty, not as an error", () => {
  const storage = memoryStorage();
  for (const bad of ["{not json", "[1,2]", '"text"', "null"]) {
    storage.setItem("k", bad);
    assert.deepEqual(createStore("k", storage).load(), {});
  }
});

test("storage that refuses to work does not throw", () => {
  const refusing = {
    getItem() {
      throw new Error("blocked");
    },
    setItem() {
      throw new Error("blocked");
    },
    removeItem() {
      throw new Error("blocked");
    },
  };
  const store = createStore("k", refusing);
  assert.deepEqual(store.load(), {});
  assert.equal(store.save({ a: 1 }), false);
  assert.doesNotThrow(() => store.clear());
});
