// The account a page works on: what the firm has entered, and how it is saved.
//
// With sign-in switched on, the account is read from and saved to the API as
// the signed-in person. Without it (a local build), the site is a preview and
// the account lives in this browser tab only.
//
// Saving takes callbacks, not a promise, so that the preview stays immediate:
// done() or failed(problems) is called as soon as the outcome is known.

import { createAuth } from "./auth.js";
import { now, pageStore } from "./page.js";
import { isSignedUp } from "./status.js";

const opened = new WeakMap();

function previewAccount(data) {
  const store = pageStore(data);
  const put = (section, value, done) => {
    store.save({ ...store.load(), [section]: value });
    done(value);
  };
  return {
    live: false,
    // A preview has one person, who can do everything.
    can: () => true,
    signedIn: () => isSignedUp(store.load()),
    load: async () => store.load(),
    state: () => store.load(),
    draft: () => store.load().signupDraft ?? {},
    saveDraft: (values) => store.save({ ...store.load(), signupDraft: values }),
    clearDraft() {
      const state = store.load();
      delete state.signupDraft;
      store.save(state);
    },
    save: (section, payload, done) => put(section, { ...payload, [section === "signup" ? "completedAt" : "savedAt"]: now() }, done),
    accept: (values, nameFieldId, done) =>
      put("agreement", { id: data.agreement.id, version: data.agreement.version, acceptedBy: values[nameFieldId], acceptedAt: now() }, done),
    signOut(done) {
      store.clear();
      done();
    },
  };
}

function liveAccount(data, options) {
  const auth = createAuth(data, options);
  const fetcher = options.fetcher ?? globalThis.fetch;
  const drafts = pageStore(data);
  let state = {};

  async function request(method, url, body) {
    const token = await auth.token();
    if (!token) return { status: 401, answer: {} };
    const response = await fetcher(url, {
      method,
      headers: { Authorization: token, ...(body ? { "Content-Type": "application/json" } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: response.status, answer: await response.json().catch(() => ({})) };
  }

  // Turns what the API said was wrong into messages a person can read.
  function problemsOf(answer) {
    const found = [...Object.values(answer.errors ?? {}), ...(answer.problems ?? [])];
    for (const row of answer.rowErrors ?? []) found.push(...Object.values(row));
    return found.length > 0 ? found : [data.messages.save_failed];
  }

  // A person who has just signed up has no firm yet: the first thing that
  // needs one creates it, with them as its owner.
  // Which firm a person belongs to is carried in their token, so a token from
  // before they had one is renewed.
  async function enrolled() {
    if (state.member) return;
    const { status, answer } = await request("POST", data.api.firm);
    if (status === 200 && answer.renew) await auth.token({ fresh: true });
    await read();
  }

  async function read() {
    const { status, answer } = await request("GET", data.api.account);
    if (status === 401) return null;
    if (status !== 200) throw new Error(`the account could not be read: ${status}`);
    state = Object.fromEntries(Object.entries(answer).filter(([, value]) => value !== null));
    return state;
  }

  // Sends one change. The answer's keys replace the same keys of the state.
  function send(method, url, body, done, failed) {
    enrolled()
      .then(() => request(method, url, body))
      .then(({ status, answer }) => {
        if (status === 401) return window.location.assign(data.routes.signin);
        if (status !== 200) return failed(problemsOf(answer));
        state = { ...state, ...answer };
        return done(answer);
      })
      .catch(() => failed([data.messages.save_failed]));
  }

  return {
    live: true,
    auth,
    signedIn: () => auth.signedIn(),
    async load() {
      if ((await read()) === null) return null;
      await enrolled();
      return state;
    },
    // Whether the signed-in person's role allows something: write, accept, people.
    can: (permission) => data.permissions[permission].includes(state.member?.role),
    state: () => state,
    draft: () => drafts.load().signupDraft ?? {},
    saveDraft: (values) => drafts.save({ signupDraft: values }),
    clearDraft: () => drafts.clear(),
    save: (section, payload, done, failed) =>
      send("PUT", `${data.api.account}/${section}`, payload, (answer) => done(answer[section]), failed),
    accept: (values, nameFieldId, done, failed) =>
      send("POST", data.api.agreement, { values }, (answer) => done(answer.agreement), failed),
    invite: (values, done, failed) => send("POST", data.api.people, { values }, done, failed),
    changeRole: (member, role, done, failed) => send("PUT", `${data.api.people}/${member}`, { role }, done, failed),
    removePerson: (member, done, failed) => send("DELETE", `${data.api.people}/${member}`, undefined, done, failed),
    signOut(done) {
      drafts.clear();
      auth.signOut().finally(done);
    },
  };
}

// One account per page, shared by every script on it.
export function openAccount(data, options = {}) {
  if (!opened.has(document)) {
    opened.set(document, data.auth.enabled ? liveAccount(data, options) : previewAccount(data));
  }
  return opened.get(document);
}

// The account with its saved state read, or null when the person must sign in.
export async function loadAccount(data, options = {}) {
  const account = openAccount(data, options);
  if (!account.loading) account.loading = account.load();
  const state = await account.loading;
  return state === null ? null : account;
}
