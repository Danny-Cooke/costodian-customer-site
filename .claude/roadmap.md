---
name: sign-up-portal-roadmap
description: The road map for the customer sign-up portal only — what is live, what is next in order, what is parked, and the decisions waiting on Dan. Written 25 November 2026.
metadata:
  type: roadmap
---

# Customer sign-up portal: road map

Written 25 November 2026. This covers the sign-up portal only: the public site, sign-up,
sign-in, My account, the customer record, and the hand-off that will create a
customer's account. The product itself (bill drafting, case storage, the portals
customers work in) is not in this repository.

## What is live

Deployed by the GitHub workflows into the Account Factory management account, London.

| Part | State |
|---|---|
| Public site | Home, Features, How it works, Security, SRA compliance, Pricing. The product name is one value. |
| Sign-up | An account type, then that type's own questions. Seven types: sole practice, partnership, LLP, limited company, freelance solicitor, Costs Lawyer, costs draftsman. Email confirmed by code. No payment. |
| Sign-in | Email and password; password reset; an invited person chooses their own password. No second factor. |
| My account | Your details, Company information (funding types, billing set-up, version), People, Agreements. |
| People | Owners and administrators; invitations by email; role changes; removal; the change record. |
| Customer record | A DynamoDB table and KMS key per customer number, pre-created as a pool with spares; a label per customer in Parameter Store; one `account` record in the same shape for every type. |
| UID | Six random digits per customer, unique through a registry, shown on My account. Statuses on the label include `dormant` and `left`. |
| Versions | A list in Parameter Store, starting at v1.0, added to when a tag is made in the repository holding each customer account's set-up. |
| Delivery | Seed by script once; Bootstrap, Site and Destroy as GitHub workflows with OIDC; one role per service. Destroyed and rebuilt from nothing by the workflows on 22 November 2026. |

## Where this repository is going (Dan, 25 November 2026)

Dan is now building a full minimum viable product. This repository is the customer
site, and it will always live in the same AWS account as the Account Factory, in the
production organisation. It must be deployable again from a different repository into a
different account with a different GitHub sign-in. See "Portability" below.

## What is left, in order

| # | Item | Size |
|---|---|---|
| 1 | Make the portal pages feel quick (see "Speed") | Small |
| 2 | The "Build portal" box on My account, not clickable until details, company information and the agreement are all done | Small |
| 3 | The hand-off behind it: approval, the workflow, one file per customer in the Account Factory's request repository ([design](context/account-factory-hand-off.md)) | Large |
| 4 | Operator actions: approve a build; mark a customer dormant or left | Medium |
| 5 | Put the UID in the sign-in token in place of the internal customer number | Small |
| 6 | An agreement written for Costs Lawyers and draftsmen, who hold an instructing firm's client's file | Wording; needs a lawyer |
| 7 | A second factor at sign-in | Medium |
| 8 | Payment, the price and the refund period | Medium; needs Dan's figures |
| 9 | The site on its own domain, and emails from our own address | Medium |
| 10 | Deploy into the production organisation's Account Factory account (see "Portability") | Medium; before real customers, because sign-ins cannot be moved afterwards |
| 11 | Top the customer table pool up without a manual run | Small; waiting on Dan |
| 12 | Check SRA, CL and company numbers against their registers | Medium |

Not part of this repository, and next after it: the portal itself. Each customer's own
sign-in in their own account; a shared sign-in page asking for UID, email and password;
portal roles; two portals, one for the five solicitor types and one for the two costs
types.

### The portal's sign-in, as agreed (not built)

- The customer site keeps one central user pool: billing, subscription, the firm's
  record, version, and who the overall administrators are.
- Each customer's portal has a user pool of its own, in that customer's AWS account,
  created when they click Build.
- The person who signed up is invited as the first user of that pool, as overall
  administrator. The same email address is in two pools, with a password for each.
- The portal's sign-in page is shared: UID, email and password. A public lookup turns
  the UID into that customer's sign-in settings and API address; the page then talks
  only to that customer's own pool and API. One error message for a wrong UID, email or
  password.
- A change to the overall administrators on the customer site is carried to the
  customer's pool by the same workflow that keeps the Account Factory in step.
- One email address belongs to one customer for now.

Open: whether removing an overall administrator here disables their portal sign-in
automatically (Claude recommends yes).

### A way for a customer to leave, or to go dormant

The label has the statuses `dormant` and `left` and the dates; nothing sets them (item
4). A dormant customer has paused: their number, UID and records are kept and no
retention clock runs. Leaving locks the account, retires the customer number and the
UID, and starts the retention clock: records may go seven years after the last case was
finished, or after leaving if no case was finished. Removal is always a reviewed change
naming the customer number.

## Speed

Dan found moving around the portal "a bit clunky". Measured on the live site on
25 November 2026:

| Step | Time |
|---|---|
| A page's HTML | about 0.4 s |
| Reading the account, first call after a pause | 1.4 to 1.7 s |
| Reading the account, calls straight after | about 0.4 s |
| Signing in | about 0.5 s |
| Creating a new customer, once | about 4 s |

Every move between portal pages is a full page load and a fresh read of the account, so
a page sits part-drawn for one to two seconds. To do, in order:

1. Keep the account in the browser for the session; draw from it at once and refresh in
   the background.
2. Hold the page, or show a loading state, until it is ready, so nothing jumps.
3. Make the API quicker to wake: more memory for the functions (they run at 256 MB);
   cache the version list instead of reading it on every request.

If that is not enough: one portal page with sections, so there are no reloads.

## Portability

Asked by Dan on 25 November 2026: can this be deployed again from a different
repository, into a different account, with a different GitHub sign-in? Checked the same
day by searching the tracked files.

**Already portable.**

- No AWS account id, site address or sign-in service id is written anywhere. Names are
  composed; the account id comes from whoever runs the seed and is stored as a GitHub
  variable by it.
- The GitHub trust is read from GitHub by the seed script, not typed, so a different
  repository or organisation is picked up.
- The seed script, the Bootstrap, Site and Destroy workflows build everything from
  nothing. Proven on 22 November 2026 (destroyed and rebuilt in the same account).
- The product's name, the Region and the tags are values.

**Values to change for a new home** (all in `infra/envs/<environment>/`):

| Value | Where | Why |
|---|---|---|
| `github_owner` | `bootstrap/terraform.tfvars` | the GitHub account or organisation that owns the repository |
| `owner` | `platform.tfvars.json` | the Owner tag |
| `repository_suffix` | `platform.tfvars.json` | only if the repository is not named `<product>-customer-site` |
| `create_oidc_provider` | `bootstrap/terraform.tfvars` | `false` if the account already has GitHub's sign-in provider; an account can hold one |
| `version_source_repository` | `site/terraform.tfvars` | the repository whose tags are the versions, in that account |

**Not portable yet: there is one environment, and its name is typed in six places.**

- Only `infra/envs/dev` exists. Production needs `infra/envs/prod` with its own values.
- The three workflows say `ENVIRONMENT: dev`, and the Site workflow also types the two
  folder paths.
- The site build reads the product's name from the `dev` values file unless told
  otherwise, and one test names that file.

So today it can be stood up in another account as a second `dev`. To stand it up as
production it needs: a `prod` values folder; the workflows taking the environment as an
input (or from the branch); the build and the test following the same environment.
That is item 10. Nothing in the design stands in the way.

**What does not move with it.** The data: sign-ins, customer tables, labels and the UID
registry belong to the account they are in. A new account starts empty. Moving existing
customers would mean everyone resetting their password.

**To check in the production organisation before deploying:** that its service control
policies allow CloudFront and the WAF in `us-east-1`; that the Account Factory's
repositories are where `version_source_repository` expects them; the account quota.

## Waiting on Dan

- How the two portals should differ.
- The root email scheme for customer accounts: plus addressing on one mailbox, or an
  alias per account.
- The organisational unit for customer accounts.
- Whether a build needs his approval for now, or goes straight through.
- Whether a firm may accept the agreement while it is a draft (it currently can; the
  version is recorded).
- The price, the refund period and the contact address.

## Stated on the site, not yet built

The list is kept in `README.md`, and the preview banner stays up while it has entries.
