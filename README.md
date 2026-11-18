# Customer site and sign-up portal

The public site for the product and its customer sign-up portal. The product's name is
`product_name` in `infra/envs/dev/platform.tfvars.json`: the one place it is written.
Terraform derives the AWS names from it and the site build puts it on every page, so a
rename is that one value and a pipeline run.

**Status: preview.** Every page and form works, and nothing a visitor types is
saved or sent. Entries are kept in the browser tab only, so the whole journey can
be clicked through. There is no API, no database, no sign-in and no payment yet.

## What is here

| Page | What it does |
|---|---|
| Home, How it works, Security and compliance, Pricing | The public site, for legally aided and privately funded work. Security and compliance maps each feature to the SRA duty it answers |
| Sign up | Three steps: about you, your firm, payment (placeholder) and confirm |
| Portal: Set-up | The checklist a firm sees after signing up |
| Portal: Company information | Billing set-up, funding types, fee earners, the firm's positions on the legal aid rules that leave a choice, and private client charging |
| Portal: Agreements | The data processing agreement (draft text) and its acceptance |

The order is deliberate: sign up and pay first; company information and the
agreement come afterwards, inside the portal; the firm's account is created once
both are done.

## Layout

```
site/config/site.json    every value the pages show: names, routes, pages, price
site/config/forms.json   every form field, declared once
site/data/               the rules a firm decides, copied from the product's rule register
site/templates/          the pages (Jinja)
site/static/             one stylesheet and the browser scripts (no libraries)
tools/build.py           renders the pages into dist/
tools/smoke.py           checks a deployed copy
tools/sync_rules.py      refreshes site/data from the product's rule register
tests/                   build tests (pytest) and browser-side tests (node + jsdom)
infra/modules/           naming, web
infra/envs/dev/          platform.tfvars.json, the bootstrap stack and the site stack
scripts/                 bootstrap.sh and destroy.sh: the only things run by hand
runbooks/                bootstrap and deploy
```

## How configuration works

- **Nothing is typed into a template or a script.** Names, routes and prices come
  from `site/config/site.json`. A test fails if the product or company name
  appears in a template.
- **A form field is declared once**, in `site/config/forms.json`. The build
  renders the input from it, and the browser validates against the same
  definition, which the build writes into the page.
- **Infrastructure values are in tfvars.** `infra/envs/dev/platform.tfvars.json` holds
  the naming slots and Regions shared by both stacks; each stack has its own
  `terraform.tfvars`. Every resource name is composed by `infra/modules/naming`.
- **Deployment values are GitHub environment variables** (role, Region, state
  bucket and key), listed at the top of `.github/workflows/site.yml`.
- **Site values can be overridden at deploy** without a commit, from GitHub
  variables: price, refund period, contact address and the preview banner.

## Working on it

```bash
python3 -m venv ~/.venvs/draftsman-site
. ~/.venvs/draftsman-site/bin/activate
pip install -e ".[dev]"
npm ci                                   # test tooling only

python tools/build.py                    # writes dist/
python -m http.server 8080 -d dist       # http://localhost:8080
```

```bash
ruff check . && ruff format --check .
pytest -q                                # the build and the forms
python tools/build.py --out dist-live --set auth.client_id=test-client --set auth.endpoint=https://auth.test/
npm test                                 # the built pages, driven in jsdom (both builds first)
python tools/build_api.py                # writes build/api/, which Terraform zips
terraform fmt -check -recursive infra
```

Try a setting without editing a file:

```bash
python tools/build.py --set pricing.per_bill=12 --set preview.enabled=false
```

## The rules a firm decides

`site/data/rules.generated.json` is a copy of the rules in the product's rule
register that are not fixed, with the register version it came from. The question
wording for each is in `forms.json`. The build stops if the two disagree: a rule
with no wording, wording for a rule that is not there, or options that differ.

To refresh the copy after the register changes:

```bash
python tools/sync_rules.py --register ../automation-portal/draftsman-poc/src/draftsman/rules/register.yaml
```

This is a copy kept by hand. When the portal has an API, it should read the rules
from the product, and this file should go.

## Sign-up, sign-in and the account

A build is one of two things, decided by whether it is given an app client
(`auth.client_id`):

- **Preview** (no client; what `python tools/build.py` makes): nothing leaves the
  browser tab. Sign-up has no password step and there is no sign-in page to use.
- **Live** (the deployed site): sign-up creates a sign-in, confirms the email
  address with a code, and saves to the account API. The pipeline passes the client,
  the endpoint and the password length from the Terraform outputs.

| Part | Where | What |
|---|---|---|
| Sign-in | `site/static/js/auth.js` | Calls the sign-in service directly. The password is sent to that service only and is never stored; the tokens are kept in the browser tab until sign out. |
| The account | `site/static/js/account.js` | One interface for the pages, backed by the API when live and by the browser tab in a preview. |
| The API | `api/handler.py`, `api/validation.py` | Three functions (read, write, accept), each under its own role. Checks every value against the same field definitions the pages are built from; keeps only known fields that are on show. An agreement acceptance is written once. |
| The package | `tools/build_api.py` | Copies `api/` and writes its settings to `build/api/`. |
| Infrastructure | `infra/modules/account` | User pool, table, key, functions, HTTP API; served under `/api/*` on the site's address. |

Payment is switched off (`pricing.payment_enabled`). Sign-up is free.

## What is tested

- **Build (pytest):** every page is built, every internal link resolves, ids are
  unique, every label points at a field, no page has inline code, every field
  that is validated is rendered, overrides work and bad ones are refused, the
  rule copy and the wording agree.
- **Browser side (node + jsdom, against the built pages):** validation rules; the
  whole sign-up journey; conditional fields; the portal guard and sign out; the
  set-up checklist; company information for a legal aid firm, a private-only
  firm, with and without VAT, with several fee earners; the agreement and its
  version.
- **The CloudFront function** that maps page paths, run as deployed.
- **The smoke test**, against a stand-in site.
- **The live site's browser side (jsdom, against a second build, with a stand-in
  network):** the password step; creating the sign-in, confirming the code, signing
  in and saving; a taken email address; a wrong code and a new one; the portal guard;
  details never saved; reading and saving the account; a refusal from the API; token
  renewal; sign in, wrong password, unconfirmed address; sign out. The password is
  checked never to reach our API or the browser's storage.
- **The API (pytest, with a stand-in table):** no person, no access; saving and
  reading back; unknown and hidden fields dropped; bad values, shapes and sizes
  refused; company information rules; the agreement written once.
- **One set of validation cases** (`tests/fixtures/validation_cases.json`) is run
  against both the browser's rules and the API's.

## What is not tested or not built

- No real browser has run the pages. The browser-side tests use jsdom, which does
  not lay out or paint, so visual problems would not be caught.
- No accessibility audit has been run. The markup follows the usual patterns
  (labels, fieldsets, error summary, focus management).
- The agreement text is a draft written from the product's design. It has not
  been reviewed by a solicitor.
- The private client charging section is a first sketch.
- The sign-in service, the API gateway's token check and the table are stood in
  for in tests. They are proven only by using the deployed site.
- Two-step sign-in is off for the sign-up portal. The site says every user of the
  product signs in with two steps.
- Finishing set-up does nothing yet: nobody is told and no account is requested.
- `scripts/destroy.sh` has never been run, and needs `jq`, which the bootstrap
  script does not.
- Verification emails come from the sign-in service's shared sender, which is
  limited to a small number a day and is not branded.

## Stated on the site, not yet built

The site describes the product as it is designed to be sold. These features are
stated on it and do not exist yet. The preview banner is the only thing telling a
visitor so; do not take the banner down while this list has entries.

- **Privately funded bills.** The product drafts legal aid bills only.
- **Seven-year retention and deletion.** Nothing in the product keeps or deletes
  files on a schedule. The sources read say six years (LAA Standard Terms 8.6 and
  8.7; SRA Accounts Rules 13.1); seven is Dan's figure and covers it.
- **Roles, and roles given case by case.** The product has users, with no roles,
  no supervisor view and no per-case access: every user sees every case.
- **Auditing of account and case access.** The product records who uploaded,
  confirmed and approved. It does not record sign-ins, role changes, or who
  opened, viewed or downloaded a case.
- **Comparing two versions of a bill.** Each draft pass is kept; there is no view
  of what changed between two, or why.
- **A second check of every reading, flagged to the reviewer,** is built; that
  scanned and handwritten pages are read reliably is not yet proven on real files.
- **A case list showing where each bill stands** as the site describes it
  (uploaded, drafted, under review, approved). Check the proof of concept's case
  list against that wording before the banner comes down.
- **Storage as a feature.** The site says each case's costs file is stored for
  seven years. It does not say the product replaces the firm's own file, and must
  not until export, backup and availability promises exist.
- **An environment per firm.** The proof of concept runs in one account.
- **Central management of rates and fee earners,** beyond one shared firm
  settings page.
- **Data export on request,** and return or deletion on leaving.
- **Finding unrecorded work.** Facts are lifted from court documents and time
  records; letters and attendance notes are transcribed and not yet read for
  chargeable items.
- **Mixed funding in one case.**

**The speed claim is unmeasured.** The site says bills are drafted in minutes. No
draft has yet been run end to end on a real case, so how long one takes is not
known. Time one before the banner comes down.

One stated claim rests on configuration that has not yet run: that all AI models
are hosted within the UK and neither learn from nor store the data. It holds for
the models configured in the proof of concept when they are called in-Region in
London (see `bedrock-claude-terms-and-availability.md` in the knowledge base). It
would stop being true if a model were called through an EU or global inference
profile, or if a model with a retention period were chosen.

## How it is deployed

Nothing is applied by hand except `scripts/bootstrap.sh <environment>`, once, by a
person with an administrator profile. It creates the Terraform state bucket (in the
same account), GitHub's sign-in to AWS (OIDC; no keys are stored anywhere) and the
pipeline's roles, and writes their names into the GitHub environments.

After that, `.github/workflows/site.yml` does everything:

| When | Job | Signs in as | Does |
|---|---|---|---|
| Every push and pull request | Tests | nobody | lint, both test suites, both builds, Terraform format and validate |
| A pull request | Terraform plan | the read-only plan role | plans the site stack and shows what would change |
| A merge to `main` | Deploy | the deploy role | applies Terraform, builds the site with the stack's outputs, publishes it, clears the cache, smoke tests the live address |

The deploy role can do nothing but read and write the state and assume one role per
service (storage, keys, edge, identity, data, compute, access). Each Terraform provider
assumes the role for its own service. The roles the `access` role creates for the
functions must carry a permissions boundary. Publishing the pages uses an eighth role
that can only write the site's files and clear the cache.

A missing permission shows up as a failed deploy naming the action. Add it to
`service_roles` in `infra/envs/dev/bootstrap/terraform.tfvars`, run the bootstrap
script again, and re-run the pipeline.

## Known exceptions

- The pipeline roles are granted reads by service prefix (`s3:Get*`,
  `cloudfront:Get*`, `wafv2:Get*`) on the site's own resources, and CloudFront
  distributions, origin access controls and response headers policies are granted
  by type, because CloudFront assigns their ids. Both are narrower than the
  account but wider than "no wildcards".
- The shared variable and local declarations are repeated in the two stacks under
  `infra/envs/dev/`; Terraform has no way to share them between root modules.
