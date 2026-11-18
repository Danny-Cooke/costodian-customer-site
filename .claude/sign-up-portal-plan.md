---
name: sign-up-portal-plan
description: What the customer site and sign-up portal are for, the order of the sign-up journey, what part one covers, and the decisions taken on 17 November 2026
metadata:
  type: project
---

# Customer site and sign-up portal

Decided with Dan on 17 November 2026. Full record:
`../automation-portal/.claude/decisions/decision-log.md` (2026-11-17) and
`../automation-portal/.claude/roadmap/customer-site-plan.md`.

## The journey

1. **Sign up and pay** on the public site: about you, your firm, payment.
2. **Inside the portal**, signed in: company information, then the data
   processing agreement.
3. **Account created** once both are done: the firm's AWS account is vended and
   the owner invited to the Draftsman app.

Money first, legal and account set-up after. No case file can be uploaded before
the agreement is accepted, because the place to upload it does not exist until
then.

## Decisions

- **Self-service, not vetted.** Payment at sign-up covers the cost of creating an
  account, so there is no approval step. The firm's SRA number is asked for and
  not checked.
- **Part one is a click-through preview.** Static pages, working forms, nothing
  saved, payment a placeholder, agreement text marked draft.
- **Hosted in the AFT management account**, London, on the CloudFront address.
- **`cm-it.co.uk/draft_cs_site` is a redirect** made by hand in the main
  website's `.htaccess`. No certificate or DNS here.
- **Every value in tfvars or GitHub variables; names composed by the naming
  module; defaults only for generic values.**
- **Company information is asked after sign-up**, and includes the firm's
  positions on the legal aid rules that leave a choice.
- **Funding is a type, not a yes or no**: legal aid, private, and later a case
  that changes from one to the other. A firm fills in only the sections for the
  funding it uses.
- **Rates in three layers**: the firm, then the fee earner, then the case. A fee
  earner marked as managing their own rates and terms (a consultant) is not given
  a firm rate.

## Not decided

- The price, the refund period and the contact address. Each is unset and shows
  as "to be confirmed" or is left out.
- What happens when a firm pays and never finishes set-up.
- Whether a consultant's billing method, not only their rates, can differ from
  the firm's.

## Part two, not built

A backend for the portal (sign-in, storage), payment through Stripe's hosted
page, and the step that turns a completed set-up into an account request for the
Account Factory. Emails where the firm is only copied in are not yet a rule in
the register; the guidance needs reading before the page asks about them.

## How the site presents the product (later on 17 November 2026)

- For both legally aided and privately funded work.
- Features are stated; how they work inside is not explained.
- Security and compliance maps each feature to the SRA duty it answers, citing only
  paragraphs already read and recorded in
  `../automation-portal/.claude/standards/sra-compliance.md`.
- Files are stated as kept for seven years after a case is completed (Dan's figure; the
  sources read require six).
- Features stated but not built are listed in `README.md`. The preview banner stays up
  while that list has entries.
