// Loads a built page into jsdom and runs the page's own scripts against it, so
// the tests exercise the real markup and the real modules together.

import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

import { JSDOM } from "jsdom";

import { memoryStorage } from "../../site/static/js/store.js";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const DIST = path.resolve(ROOT, process.env.DIST_DIR ?? "dist");
// A second build with sign-in switched on, for the tests of the live site:
//   python tools/build.py --out dist-live --set auth.client_id=test-client --set auth.endpoint=https://auth.test/
const DIST_LIVE = path.resolve(ROOT, process.env.DIST_LIVE_DIR ?? "dist-live");
const SITE = JSON.parse(readFileSync(path.join(ROOT, "site/config/site.json"), "utf8"));
const PAGE_DATA = 'script[type="application/json"]';
const INDEX = "index.html";
let run = 0;

export const site = SITE;
export const routes = SITE.routes;
export { memoryStorage };

function fileFor(urlPath, dist = DIST) {
  const relative = urlPath.replace(/^\//, "");
  return path.join(dist, urlPath.endsWith("/") ? path.join(relative, INDEX) : relative);
}

function pageDataOf(file) {
  const page = new JSDOM(readFileSync(file, "utf8"));
  return JSON.parse(page.window.document.querySelector(PAGE_DATA).textContent);
}

// The storage key is derived from other site values at build time, so it is read
// from a built page, not from site.json.
let storageKey;
function builtStorageKey() {
  if (!storageKey) {
    const home = new JSDOM(readFileSync(fileFor(routes.home), "utf8"));
    storageKey = JSON.parse(home.window.document.querySelector(PAGE_DATA).textContent).storageKey;
  }
  return storageKey;
}

export function storageWith(state) {
  const storage = memoryStorage();
  if (state) storage.setItem(builtStorageKey(), JSON.stringify(state));
  return storage;
}

export function stateIn(storage) {
  return JSON.parse(storage.getItem(builtStorageKey()) ?? "{}");
}

// The live build's page data: where sign-in and the API are, and the session key.
export function liveData(route = "home") {
  return pageDataOf(fileFor(routes[route], DIST_LIVE));
}

// A signed-in session in storage, as the sign-in module keeps it.
export function sessionWith(storage, token = "token-1", expiresInSeconds = 3600) {
  const session = { idToken: token, refreshToken: "refresh-1", expiresAt: Date.now() + expiresInSeconds * 1000 };
  storage.setItem(liveData().auth.sessionKey, JSON.stringify(session));
  return storage;
}

// A stand-in for the network: answers each request from `answer(request)` and
// keeps what was asked. A request is { url, method, target, headers, body }.
export function fakeNetwork(answer) {
  const requests = [];
  const fetcher = async (url, options = {}) => {
    const request = {
      url,
      method: options.method ?? "GET",
      headers: options.headers ?? {},
      target: (options.headers?.["X-Amz-Target"] ?? "").split(".").pop(),
      body: options.body ? JSON.parse(options.body) : undefined,
    };
    requests.push(request);
    const { status = 200, body = {} } = (await answer(request)) ?? {};
    return { ok: status >= 200 && status < 300, status, json: async () => body };
  };
  return { fetcher, requests };
}

// Lets the page finish what it started: every promise and callback in flight.
export async function settle() {
  for (let turn = 0; turn < 20; turn += 1) await new Promise((resolve) => setTimeout(resolve, 0));
}

export const openLive = (route, storage, network) => open(route, storage, { dist: DIST_LIVE, fetcher: network.fetcher });

export async function open(route, storage = memoryStorage(), { dist = DIST, fetcher } = {}) {
  const file = fileFor(routes[route], dist);
  if (!existsSync(file)) throw new Error(`${file} is missing: run "python tools/build.py" first`);
  const dom = new JSDOM(readFileSync(file, "utf8"));
  const { document } = dom.window;
  const visited = [];
  let printed = 0;

  dom.window.Element.prototype.scrollIntoView = () => {};
  globalThis.document = document;
  globalThis.CSS = { escape: (value) => String(value).replace(/[^\w-]/g, (character) => `\\${character}`) };
  globalThis.window = {
    sessionStorage: storage,
    location: { assign: (url) => visited.push(url), replace: (url) => visited.push(url) },
    print: () => {
      printed += 1;
    },
  };

  globalThis.fetch = fetcher ?? (async () => {
    throw new Error("this page should not use the network");
  });

  const sources = [...document.querySelectorAll('script[type="module"]')].map((script) => script.getAttribute("src"));
  for (const source of sources) {
    run += 1;
    await import(`${pathToFileURL(fileFor(source, dist)).href}?run=${run}`);
  }

  const one = (selector, root = document) => root.querySelector(selector);
  const fire = (element, type) => element.dispatchEvent(new dom.window.Event(type, { bubbles: true, cancelable: true }));
  const inputs = (id, root = document) => [...root.querySelectorAll(`[data-input="${id}"]`)];

  return {
    document,
    visited,
    storage,
    one,
    all: (selector, root = document) => [...root.querySelectorAll(selector)],
    printed: () => printed,
    state: () => stateIn(storage),
    field: (id, root = document) => one(`[data-field="${id}"]`, root),
    error: (id, root = document) => one(`[data-field="${id}"] [data-error]`, root).textContent,
    // Sets a field the way a person would: type, tick or choose, then the change is announced.
    set(id, value, root = document) {
      const found = inputs(id, root);
      if (found.length === 0) throw new Error(`no input for ${id}`);
      const [first] = found;
      if (first.type === "checkbox") first.checked = Boolean(value);
      else if (first.type === "radio") found.forEach((input) => (input.checked = input.value === value));
      else first.value = value;
      fire(first, "input");
      fire(first, "change");
    },
    click: (element) => fire(element, "click"),
    submit: (form = one("[data-form]")) => fire(form, "submit"),
  };
}
