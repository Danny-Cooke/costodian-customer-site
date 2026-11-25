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
| Versions | A list in Parameter Store, starting at v1.0, added to when a tag is made in the repository holding each customer account's set-up. |
| Delivery | Seed by script once; Bootstrap, Site and Destroy as GitHub workflows with OIDC; one role per service. Destroyed and rebuilt from nothing by the workflows on 22 November 2026. |

## Next, in order

### 1. "Build portal"

The button on the My account page, and the hand-off behind it. Design agreed in
outline: [context/account-factory-hand-off.md](context/account-factory-hand-off.md).

1. The box on My account: disabled, saying "Complete all information and agreement
   before building your portal", until details, company information and the agreement
   are all done; then "Build portal", for owners only; then "Your portal is being
   built"; then "Open portal".
2. An approvals parameter per customer, which only an operator can write.
3. The workflow that starts when a customer's label changes, and commits that
   customer's file to the Account Factory's request repository.
4. The first commit to that repository, which is still empty: the fixed Terraform that
   reads one file per customer.
5. The function that records the Account Factory's outcome on the label.
6. A daily run of the same workflow for every customer, as the safety net.

To read first, in the Account Factory's documentation: which notifications it
publishes and what they contain; how customisations are re-run for one existing
account; whether the request module can be used once per file.

Before any real customer: the organisation's account quota (ten by default), the
organisational unit customer accounts go in, and a tested root email scheme.

### 2. Two portals

After sign-up everyone lands in one portal. Dan wants one for the five solicitor types
and one for the two costs types, and will say how they differ. The `portal` value
(`practice` or `costs`) is already recorded for each customer.

### 3. An agreement for costs practitioners

A Costs Lawyer or draftsman holds an instructing firm's client's file. The present
agreement is written for a firm holding its own clients' files and does not fit them.

### 4. A way for a customer to leave

The label has the status `left` and the dates; nothing sets them. Leaving locks the
account and starts the retention clock: records may go seven years after the last case
was finished, or after leaving if no case was finished. Removal is always a reviewed
change naming the customer number.

### 5. Tidying

- Remove the old shared table, which is empty and no longer read, and the permissions
  that point at it.
- Topping the pool up without anyone running the Site workflow. An hourly schedule was
  refused by Claude Code's permission check on 23 November 2026 and is Dan's to add or
  to replace with a narrower job.
- Check registration numbers (SRA, CL, Companies House) against their registers.

## Later

- Payment at sign-up, the price and the refund period.
- A second factor at sign-in.
- The site on its own domain, not a redirect from the main website.
- Moving the whole portal out of the Account Factory management account into a
  platform account of its own.
- A shared product front end in that platform account, with each customer's data and
  processing in the customer's own account. That is a separate repository.
- Verification and invitation emails from our own sender.

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
