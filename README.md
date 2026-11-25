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
| Sign up | Account type, about you, the questions for that type, your sign-in, and confirm. No payment yet. |
| Portal: My account | The checklist a firm sees after signing up |
| Portal: Your details | The person's and the firm's details |
| Portal: Company information | Funding types, billing set-up and the version the firm runs. How a firm charges its own clients is set up in the product, not here. |
| Portal: People | Owners and administrators, invitations and the change record |
| Portal: Agreements | The data processing agreement (draft text) and its acceptance |

The order is deliberate: sign up and pay first; company information and the
agreement come afterwards, inside the portal; the firm's account is created once
both are done.

## Layout

```
site/config/site.json    every value the pages show: names, routes, pages, price
site/config/forms.json   every form field, declared once
site/templates/          the pages (Jinja)
site/static/             one stylesheet and the browser scripts (no libraries)
tools/build.py           renders the pages into dist/
tools/smoke.py           checks a deployed copy
tests/                   build tests (pytest) and browser-side tests (node + jsdom)
infra/modules/           naming, web, account
infra/seed/              seed.yaml: the CloudFormation seed, the one thing applied by hand
infra/envs/dev/          platform.tfvars.json, the bootstrap stack and the site stack
scripts/                 seed.sh (by hand), names.sh, bootstrap.sh, destroy.sh (workflows)
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
- **Deployment values are worked out from the tfvars at run time** by
  `scripts/names.sh`: the roles, Region, state bucket, state keys and
  environment names. GitHub holds two repository variables, both set by
  `scripts/seed.sh`: `AWS_ACCOUNT_ID` and `OIDC_SUBJECT_PREFIX`.
- **Site values can be overridden at deploy** without a commit, from GitHub
  variables: price, refund period, contact address and the preview banner.

## Working on it

```bash
python3 -m venv ~/.venvs/customer-site
. ~/.venvs/customer-site/bin/activate
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
| The API | `api/handler.py`, `api/validation.py` | Five functions (read, enrol, write, accept, people), each under its own role. Checks every value against the same field definitions the pages are built from; keeps only known fields that are on show. An agreement acceptance is written once. |
| The package | `tools/build_api.py` | Copies `api/` and writes its settings to `build/api/`. |
| Infrastructure | `infra/modules/account` | User pool, table, key, functions, HTTP API; served under `/api/*` on the site's address. |

Payment is switched off (`pricing.payment_enabled`). Sign-up is free.

### A sign-up for each kind of account

Sign-up starts with an **account type**. Each type has a set of questions of its own,
defined separately in `signup.types` in `forms.json`. They are not one form with parts
hidden: a question only exists for the types it is asked of, the browser shows and
checks only the chosen type's block, and the API accepts only that type's answers.

| Type | Regulated by | Asked only of this kind |
|---|---|---|
| Solicitor: sole practice | SRA, as a firm | firm SRA number; trading name allowed |
| Solicitors: partnership | SRA, as a firm | firm SRA number; the partners |
| Solicitors: LLP | SRA, as a firm | LLP number; firm SRA number; designated members |
| Solicitors: limited company | SRA, as a firm | company number; firm SRA number; directors |
| Solicitor: freelance | SRA, as an individual | their own SRA number; no trading name, company or staff |
| Costs Lawyer | Costs Lawyer Standards Board, as an individual | CL number; how the business is set up; who instructs them |
| Costs draftsman | nobody | how the business is set up; who instructs them; who supervises |

Why they differ is recorded with its sources in the sibling repository:
`../automation-portal/.claude/context/signup-practice-types.md` and
`clsb-costs-lawyer-regulation.md`.

**One shape for whatever creates the account.** Whatever was asked, the API reduces
the answers to the same few facts, kept as `account` beside the answers and copied to
the customer's label:

| Fact | What it is |
|---|---|
| `name` | the legal name: a registered company or LLP name, a partnership's name, or a person's own |
| `trading_name` | the name traded under, where there is one |
| `slug` | the name cut down to a-z, 0-9 and hyphens, for use inside resource names with a prefix and postfix |
| `type`, `portal` | the kind of account, and which portal it belongs to (`practice` or `costs`) |
| `regulator`, `regulator_number` | `sra`, `clsb` or `none`, and the firm SRA number, own SRA number or CL number |
| `legal_form` | sole, partnership, llp, company or individual |
| `company_number` | where the business is registered at Companies House |

The portal after sign-up is still one portal. Separate ones for the solicitor types and
the costs types are to come; `portal` is recorded now so that they can be.

### Firms, owners and administrators

What is entered belongs to a **firm**, and people are members of it. The person who
signs up becomes the firm's first owner. Roles and what each may do are in `roles` and
`permissions` in `site/config/site.json`; the API reads the person's role on every
request.

| | Owner | Administrator |
|---|---|---|
| Accept the agreement; pay (when payment exists) | Yes | No |
| Invite and remove people, change roles | Yes | No |
| Edit the firm's details and its billing answers | Yes | Yes |

- An invitation creates the person's sign-in; they are emailed a temporary password
  and choose their own the first time they sign in.
- A firm always has at least one owner. Removing a person ends their access at once
  and deletes their sign-in.
- Every change is added to the firm's change record with who made it and when; the
  People page shows it.
- **The rule for the product:** every owner and administrator here is an administrator
  of the product itself, and the product takes that list from here. Who works on which
  case is managed in the product. Not built: no product account is created yet.
- **Fee earners are not entered here.** They are part of the product's own user
  management.

### A table, a key and a label for every customer

Each firm has a DynamoDB table and a KMS key of its own, identified by a customer
number (`0001`, `0002`, ...). Nothing is created when a firm signs up:

- **Terraform makes the tables in advance.** It keeps a number of spares
  (`customer_spares`) ahead of the highest number taken, so every run of the Site
  workflow tops the pool back up.
- **Signing up takes the lowest free number.** The claim is a write that succeeds
  only once, so two firms can never be given the same table.
- **A person's sign-in carries their customer number**, in an attribute only the API
  can set. The browser never sees the number.
- **Each request reaches one table.** The function has no access to customer tables
  of its own; it takes 15-minute credentials limited to that customer's table and key.
- **Each number has a label**, a parameter at `<customer path>/<number>` holding a
  small JSON: the firm's name, SRA number and company number once given, a status
  (`free`, `signed up`, `set-up complete`, `left`) and the dates below. It is what
  account creation will read.
- **Retention.** The label holds the day the customer left and the day their last case
  was finished; from those it works out a delete-after date, `retention.years` after
  the last case (or after leaving, if they never finished one). Nothing is deleted
  automatically. A customer's table is removed only by naming its number in
  `removed_customer_numbers`, in a reviewed change. See `runbooks/deploy.md`.

Inside a customer's table: `FIRM` holds `firm`, `company`, the agreement acceptance, one
`member#<person>` per member, one `change#<time>` per change and the `claim`;
`PERSON#<person>` holds that person's own details.

### The UID

Every customer also has a **UID**: six random digits, never duplicated, never changed
and never issued again. It is what the customer is known by outside the sign-up system:
what they will type, with their email address and password, to sign in to their portal,
and what their account is built under. The sequential customer number stays internal.

| | Customer number | UID |
|---|---|---|
| Example | `0001` | `483920` |
| Assigned | in sequence, from the pre-made pool | at random, when the customer is created |
| Seen by | us | the customer, on My account |

A UID is claimed by a write to the **registry** that succeeds only if that UID is not
there, so two customers can never share one; if chance picks one that is taken, another
is picked. The registry keeps every entry for ever, marked `issued` or `retired`. The
UID is kept with the customer's table, on their label and in the registry, and is called
`uid` in code.

A customer's label carries one of these statuses: `free`, `signed up`,
`set-up complete`, `dormant` (they have paused; everything is kept and nothing is due
for deletion) or `left`. A customer who is dormant or has left stays so whatever is
saved afterwards. Not built: anything that moves a customer into or out of those two.

Not built: a way for a customer to leave (the status and dates exist; nothing sets
them yet), and the product writing the last-case date.

### Versions

A firm chooses the version of the product its account runs, on the Company information
page. The choice is saved with the firm's answers, written to the customer's label,
and added to the change record. A firm can move to a newer version and is not moved
back.

The versions on offer are held in one parameter. It starts with `initial_versions`
from `platform.tfvars.json`, and a version is added when a tag matching the version
pattern is made in the repository that holds each customer account's set-up: tagging
a release is all it takes to offer it. The page reads the list with the account, so a
new version appears without the site being rebuilt.

Not built: anything acting on the choice. Recording a version does not change a
customer's account; that is the Account Factory's job, reading the label.

## What is tested

- **Build (pytest):** every page is built, every internal link resolves, ids are
  unique, every label points at a field, no page has inline code, every field
  that is validated is rendered, overrides work and bad ones are refused.
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
- The sign-in service, the API gateway's token check and the table are stood in
  for in tests. They are proven only by using the deployed site.
- Two-step sign-in is off for the sign-up portal. The site says every user of the
  product signs in with two steps.
- Finishing set-up does nothing yet: nobody is told and no account is requested.
- No workflow or script here has been run since they were rewritten to run in
  GitHub: the account is empty of this project. `infra/seed/seed.yaml` has never
  been applied, so the bootstrap role's permissions are reasoned, not proven,
  and CloudFormation has not parsed the template.
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

Everything runs in GitHub Actions. The only thing applied from a person's
machine is the seed, `scripts/seed.sh <environment>`, once per environment: a
CloudFormation stack holding GitHub's sign-in to AWS (OIDC; no keys are stored
anywhere) and one role, the bootstrap role, which GitHub may assume from one
environment of this repository and which may do nothing but apply and destroy
the Terraform bootstrap stack. It also sets the two repository variables a
workflow cannot work out for itself: `AWS_ACCOUNT_ID` and
`OIDC_SUBJECT_PREFIX`.

After that there are three workflows and nothing by hand:

| Workflow | When | Signs in as | Does |
|---|---|---|---|
| `bootstrap.yml` | by hand, with an approval | the bootstrap role | the Terraform state bucket and the pipeline's roles |
| `site.yml` | every push and pull request | nobody | lint, both test suites, both builds, Terraform format and validate |
| | a pull request | the read-only plan role | plans the site stack and shows what would change |
| | a merge to `main` | the deploy role | applies Terraform, builds the site with the stack's outputs, publishes it, clears the cache, smoke tests the live address |
| `destroy.yml` | by hand, project name typed | the deploy role, then the bootstrap role | takes the site down, then the roles and the state bucket. The seed survives |

Every role ARN, bucket, state key and environment name is worked out at run time
by `scripts/names.sh` from the tfvars, so none of them is typed into a workflow
or kept in a GitHub variable where it could drift.

The deploy role can do nothing but read and write the state and assume one role per
service (storage, keys, edge, identity, data, compute, access). Each Terraform provider
assumes the role for its own service. The roles the `access` role creates for the
functions must carry a permissions boundary. Publishing the pages uses an eighth role
that can only write the site's files and clear the cache.

A missing permission shows up as a failed deploy naming the action. Add it to
`service_roles` in `infra/envs/dev/bootstrap/terraform.tfvars`, run the
`Bootstrap` workflow again, and re-run the pipeline.

## Known exceptions

- The pipeline roles are granted reads by service prefix (`s3:Get*`,
  `cloudfront:Get*`, `wafv2:Get*`) on the site's own resources, and CloudFront
  distributions, origin access controls and response headers policies are granted
  by type, because CloudFront assigns their ids. Both are narrower than the
  account but wider than "no wildcards".
- The shared variable and local declarations are repeated in the two stacks under
  `infra/envs/dev/`; Terraform has no way to share them between root modules.
