# draftsman-customer-site

The public site and customer sign-up portal for the product, the legal aid bill
drafting product. The product itself, and the design and decision record for both,
live in the sibling repository `automation-portal` (`draftsman-poc/` and
`.claude/`). Read that knowledge base before designing anything here; this
repository's `.claude/` holds only what applies to this code.

> **Status:** preview. A static site with working forms that save nothing. No
> API, no database, no sign-in, no payment.

## Rules

1. **No value is hardcoded.** Site values live in `site/config/site.json`, form
   fields in `site/config/forms.json`, infrastructure values in tfvars,
   deployment values in GitHub environment variables. A literal appearing twice
   is a defect. Resource names come from `infra/modules/naming`, never from a
   literal. Defaults are given only to values that are generic (a cache period, a
   header); anything that identifies an environment or account has none.
2. **A form field is declared once** and both rendered and validated from that
   declaration.
3. **Everything is tested in the same change**, and the pipeline runs the tests,
   `terraform fmt`, `validate` and `plan` before anything deploys.
4. **No inline scripts or styles.** The content security policy forbids them and
   a test enforces it.
5. **The site describes the product as designed, and the gap is written down.**
   It states features without explaining how they work inside. Any feature stated
   on the site that is not built is listed in the README under "Stated on the
   site, not yet built", in the same change. No certifications or customers that
   do not exist. Prices and contact details are never invented; an unset value
   shows as "to be confirmed" or is left out. Every SRA or LAA reference on the
   site is one that has been read and is recorded in
   `../automation-portal/.claude/standards/sra-compliance.md`.
6. **No personal data in the repository, logs or commit messages.** Test data
   uses invented names and `example.test` addresses.
7. **No secrets in the repository.** The pipeline signs in to AWS with GitHub's
   identity token.
8. **Infrastructure changes go through Terraform.** London (`eu-west-2`) for
   everything regional; `us-east-1` only for what CloudFront requires there.

## Ways of working with Dan

- Short answers. Plan before build; build on an explicit go.
- Nothing is committed unless Dan says so, and Dan decides when to push.
- Run the tests and `terraform validate` before calling work done, and say
  plainly what was and was not verified.
- Decisions and design go in `automation-portal/.claude/`; a short copy of what
  applies here goes in this repository's `.claude/`.

## Where things go

| What | Where |
|---|---|
| What this is and how to run it | `README.md` |
| First-time AWS and GitHub set-up | `runbooks/bootstrap.md` |
| Deploying, and the redirect from the main website | `runbooks/deploy.md` |
| The plan and decisions that apply to this repository | `.claude/` |
| The full design and decision record | `../automation-portal/.claude/` |
