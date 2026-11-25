---
name: sign-up-portal-decisions
description: The decisions taken for the customer sign-up portal from 17 to 25 November 2026, in order, each marked as Dan's or as Claude's choice stated to Dan
metadata:
  type: decisions
---

# Customer sign-up portal: decisions

In date order. "Dan" means he decided it. "Claude" means a choice made while building and
told to him, which he can change. The fuller record, with the product-wide decisions, is
in `../automation-portal/.claude/decisions/decision-log.md`.

## 17 November 2026: the first site

- **Dan.** Sign-up is self-service, not vetted. Payment at sign-up is what covers the
  cost of creating an account.
- **Dan.** The journey is sign up, then company information and the agreement inside
  the portal, then the account is created.
- **Dan.** Every value is in tfvars or GitHub values; names are composed, never typed.
- **Dan.** The site is for both legally aided and privately funded work. It states
  features without saying how they work inside. It never names a hosting or AI supplier:
  data is held in the UK.
- **Dan.** Bills are "drafted in minutes, not days". Unmeasured; noted in the README.

## 18 November 2026: a real, free sign-up

- **Dan.** The product is named Costodian.
- **Dan.** Sign-up is real and free; no payment step for now.
- **Dan.** Permissions are segregated: one role per function, one pipeline role per
  service, no role that does everything.
- **Dan.** Everything is built by the GitHub pipeline with OIDC; state is in a bucket in
  the same account; one value per fact; every resource is tagged.
- **Dan.** Fee earners are not entered here; they belong to the product's own user
  management.
- **Dan.** Two roles. Owners accept the agreement, pay, and decide who the owners and
  administrators are. Administrators keep the details and answers up to date. Both are
  administrators of the product by default, and the product takes that list from here.
- **Claude.** More than one owner is allowed and a firm always has one. The password
  goes straight to the sign-in service and is never stored by us.

## 22 to 24 November 2026: a record per customer

- **Dan.** Bootstrap and Destroy run in GitHub too. Only a one-off seed is applied from
  a person's machine.
- **Dan.** Each customer has a table and key of its own, numbered sequentially and
  pre-created as a pool. Cost per customer is not a concern.
- **Dan.** A parameter per customer number holds a small JSON label.
- **Dan.** A customer's records are kept until seven years after their last case was
  finished, and never deleted while they are a customer.
- **Dan.** Sign-up holds what identifies the firm. How a firm charges its own clients
  (the legal aid positions, private rates) is set up in the product.
- **Dan.** A version drop-down, recorded with the firm. Versions are tags, starting at
  v1.0; customers choose to upgrade.
- **Claude.** Nothing deletes automatically. A firm cannot move back to an older
  version. The customer number is carried on the sign-in and not shown to the browser.
  Each request uses credentials limited to one customer's table.

## 24 November 2026: a sign-up for each kind of account

- **Dan.** Each kind of organisation has its own sign-up, chosen from an account type
  drop-down, with questions that belong to that kind. Seven kinds.
- **Dan.** The answers are stored in one usable shape for the Account Factory.
- **Dan.** Two portals to come: one for the five solicitor kinds, one for the two costs
  kinds.
- **Claude.** One `account` record for every kind. VAT is asked on Company information,
  not at sign-up. "Are you insured?" is recorded, not enforced. Partners, members and
  directors are one text box.
- Rests on `context/signup-practice-types.md` and
  `context/clsb-costs-lawyer-regulation.md`. The Costs Lawyer Standards Board regulates
  individuals, not businesses.

## 24 and 25 November 2026: building a customer's account

Agreed in outline; not built. Detail in `context/account-factory-hand-off.md`.

- **Dan.** A "Build portal" box on the home page, not clickable until details, company
  information and the agreement are all done.
- **Dan.** Costodian is run as a managed service: customers are not given access to
  their AWS account. The break-glass email is ours.
- **Dan.** Infrastructure is keyed by customer number, so a change of name or phone
  number renames nothing.
- **Dan.** One file per customer in the Account Factory's request repository.
- **Dan.** A shared front end, with each customer's data in its own account.
- **Claude, agreed by Dan.** The label is the truth and the request file a copy; a
  change to the label starts the workflow; approval is its own parameter that only an
  operator can write.
- **Claude.** No load balancer unless something needs a long-running server: the
  services in use already run across the London zones.

## 25 November 2026: where the notes live

- **Dan.** Everything about the sign-up portal (context, road map) is kept in this
  repository. References to the product's earlier name are replaced.
- **Dan.** The repository is renamed to follow the product's name. Done the same day:
  the name is now composed from the product's name and a suffix, not typed; the seed was
  re-run and the Bootstrap and Site workflows run, because the roles trust the
  repository by name.

## 25 November 2026: the UID, sign-in for the portal, and dormant customers

- **Dan.** The customer site's users are separate from the portal's. The customer site
  has one central pool. Each customer's portal has its own pool in their own AWS
  account, created at Build. The person who signed up is invited to it as overall
  administrator. One email address belongs to one customer for now.
- **Dan.** The portal's shared sign-in page asks for the customer number, email and
  password, and directs the sign-in to that customer's own pool.
- **Dan.** Every customer has a UID: six random digits, never duplicated, never changed,
  stored in the table and on the label and passed to the Account Factory; called `uid`
  in code. When a customer leaves, the UID and the customer number are retired.
- **Dan.** A registry table keeps track of UIDs.
- **Dan.** A `dormant` status for a customer who has stopped their subscription for a
  time without leaving.
- **Claude.** The registry is keyed on the UID, because uniqueness is only enforced on a
  key. It reuses the emptied shared table. The UID is six digits from 100000, so it never
  starts with a nought. Issued UIDs stay in the registry for ever. The UID names
  everything made at Build; the sequential number stays inside the sign-up system. The
  UID is shown to customers as "customer number". It is an address, not a secret: the
  lookup will be rate-limited and give one error for every kind of wrong sign-in.
- **Claude.** A dormant customer keeps everything and their retention clock does not
  run. Dormant and left are held: nothing the customer saves changes them.
