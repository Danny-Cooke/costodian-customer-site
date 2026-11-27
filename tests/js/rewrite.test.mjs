// The CloudFront viewer-request function, run here exactly as it is deployed:
// the template is filled in the same way Terraform fills it.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const INDEX = "index.html";
const template = readFileSync(
  new URL("../../infra/modules/web/functions/rewrite.js.tftpl", import.meta.url),
  "utf8",
);
const HOST = "site.example.test";
const filled = (host) =>
  template.replaceAll("${index_document}", INDEX).replaceAll("${canonical_host}", host);
const build = (host) => new Function(`${filled(host)}; return handler;`)();
const handler = build("");
const named = build(HOST);
const rewrite = (uri) => handler({ request: { uri } }).uri;
const arriving = (host, uri, querystring = {}) =>
  named({ request: { uri, querystring, headers: { host: { value: host } } } });

test("the root and folder addresses are answered with their index document", () => {
  assert.equal(rewrite("/"), `/${INDEX}`);
  assert.equal(rewrite("/pricing/"), `/pricing/${INDEX}`);
  assert.equal(rewrite("/portal/company/"), `/portal/company/${INDEX}`);
});

test("a page address without its trailing slash still reaches the page", () => {
  assert.equal(rewrite("/pricing"), `/pricing/${INDEX}`);
  assert.equal(rewrite("/portal/company"), `/portal/company/${INDEX}`);
});

test("files are left alone", () => {
  assert.equal(rewrite("/404.html"), "/404.html");
  assert.equal(rewrite("/static/css/site.css"), "/static/css/site.css");
  assert.equal(rewrite("/static/js/signup.js"), "/static/js/signup.js");
});

test("a dot in a folder name does not make the last segment a file", () => {
  assert.equal(rewrite("/v1.2/pricing"), `/v1.2/pricing/${INDEX}`);
});

test("the template has no placeholder left over", () => {
  assert.equal(filled(HOST).includes("${"), false);
});

test("a request at the site's own name is served, not redirected", () => {
  assert.equal(arriving(HOST, "/pricing").uri, `/pricing/${INDEX}`);
});

test("any other address is sent on to the same page at the site's own name", () => {
  const moved = arriving(`www.${HOST}`, "/pricing/");
  assert.equal(moved.statusCode, 301);
  assert.equal(moved.headers.location.value, `https://${HOST}/pricing/`);

  const old = arriving("d111111abcdef8.cloudfront.net", "/signin/", {
    next: { value: "account" },
    tag: { value: "a", multiValue: [{ value: "a" }, { value: "b" }] },
    bare: { value: "" },
  });
  assert.equal(old.headers.location.value, `https://${HOST}/signin/?next=account&tag=a&tag=b&bare`);
});

test("with no name set, nothing is redirected", () => {
  const request = { uri: "/", querystring: {}, headers: { host: { value: "anything.example.test" } } };
  assert.equal(handler({ request }).uri, `/${INDEX}`);
});
