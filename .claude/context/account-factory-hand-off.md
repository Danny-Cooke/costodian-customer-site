---
name: account-factory-hand-off
description: The design agreed in outline on 24 and 25 November 2026 for "Build portal" — how a customer's record reaches the Account Factory, what the request holds, how changes are kept in step and tracked. Planned, not built; three points still to confirm in the Account Factory's documentation.
metadata:
  type: design
---

# From a customer's record to their account

Agreed in outline with Dan on 24 and 25 November 2026. **Nothing here is built.**

## The principle

The infrastructure behind a customer only ever knows the **customer number**. A firm can
change its name, its phone number or its people and nothing is renamed or rebuilt.

| Kind of data | Examples | Where it lives | What a change triggers |
|---|---|---|---|
| Identity | customer number | everywhere, as the key | never changes |
| Decides the build | version, which portal | the Account Factory request | a pipeline run for that one account |
| Describes the customer | name, phone, address, people, VAT number | the customer's table and label | nothing in infrastructure |

## The request

The Account Factory's request repository holds one fixed Terraform file and one small
data file per customer. Adding a customer adds a file. Nothing generates Terraform from
what a customer typed.

```
aft-account-request/terraform/
  main.tf            written once; reads every file in customers/
  customers/
    0001.json        { "customer": "0001", "portal": "practice", "version": "v1.0" }
```

Per customer, the fixed file asks for:

- **Account name** `<product>-<environment>-<number>`. No firm name: firms rename, and a
  firm's name should not sit in an account name.
- **Root email** one per account, ours, never reused. Scheme not decided: plus
  addressing on one mailbox (our notes say AWS's own examples use it and nothing says it
  is supported; whether the mail host delivers it is untested), or an alias per account.
- **The Identity Center user** on the request: one break-glass identity of ours, the
  same on every account. Never the customer. Costodian is run as a managed service.
- **Customisations** chosen by the portal: one set for the solicitor types, one for the
  costs types.
- **Tags and custom fields** customer number, portal, version. Not the slug: if a name
  ever reached a resource name, a rename would mean replacing the resource.

Removing a file does not close an account. Closing is a separate, deliberate step.

## Keeping the two in step

The customer's **label** is the truth. The request file is a copy that can always be
rebuilt from it.

```
Label for a customer changes                 (already happens on every save)
   -> AWS raises a "parameter changed" event
   -> EventBridge rule on the customer label path
   -> Step Functions: sync one customer
        1. read the label and the approval
        2. build requested and approved?   no -> stop
        3. work out what the file should say
        4. read the file in the request repository
        5. the same?                       yes -> stop
        6. commit the new file
        7. write "committed" and the commit id to the label

Account Factory finishes or fails for the account
   -> it publishes a notification
   -> a function writes the outcome to the label: live and the version running,
      or failed and why
```

- **The trigger is the label changing**, so no code path can update the truth and
  forget to pass it on.
- **Safe to run twice**: the same label always gives the same file, written whole.
- **Wanted and running are kept apart** on the label (`version_wanted`,
  `version_running`), so a failed upgrade shows as a difference, not as silence.
- **Each execution is named after the customer and the label's version number**, so one
  change cannot be processed twice.
- **Commits go through a queue**, one at a time, so two customers cannot collide.
- **The same workflow runs for every customer once a day** as the safety net for a
  missed event or a file edited by hand.
- **The request repository checks each file's shape**, so a bad file fails the plan.

## Approval

Not in the request file (its existence is the result of approval) and not in the label
(the sign-up API can write the label, and a build creates an AWS account). Its own
parameter, on a path the customer-facing functions have no permission to write:

| Parameter | Written by | Holds |
|---|---|---|
| `<customer path>/<number>` | the sign-up API | what the customer has told us and asked for |
| `<approvals path>/<number>` | an operator only | approved by whom and when |

## Versions

Dan's intent: versions are tags; a customer chooses when to move to a newer one. As
Claude understands the Account Factory, global customisations run from one branch for
every account and cannot be pinned per account. The route proposed: each account's
customisation reads its `version` custom field and takes the product's Terraform module
at that tag. **To confirm in the documentation.**

## To confirm before building

1. Which notifications the Account Factory publishes on success and failure, and what
   they contain.
2. How customisations are re-run for one existing account when its request changes.
3. That the request module can be used with one instance per data file, and the exact
   field names for the version deployed.

## Where it should run

The shared product front end and this hand-off belong in a platform account of their
own, not in the Account Factory management account, where the portal sits for now.
