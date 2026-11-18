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
const handler = new Function(`${template.replaceAll("${index_document}", INDEX)}; return handler;`)();
const rewrite = (uri) => handler({ request: { uri } }).uri;

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
  assert.equal(template.replaceAll("${index_document}", INDEX).includes("${"), false);
});
