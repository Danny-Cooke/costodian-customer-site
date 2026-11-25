# Customer site and sign-up portal

The public site and customer sign-up portal for the product: sign-up, sign-in, My
account, the customer record, and the hand-off that will create a customer's account.
The product's name is declared once, in `infra/envs/dev/platform.tfvars.json`, and is
not written anywhere else in the code.

Everything about this portal (road map, decisions, research) is in this repository's
`.claude/`; start at `.claude/README.md`. The sibling repository `automation-portal`
holds the wider product and the SRA and legal aid research, and is referred to from
here where needed.

> **Status:** live, built by the GitHub workflows. Sign-up is real and free. The
> preview banner stays up while the README lists features stated on the site and not
> yet built.

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
- Changes go through a pull request; a merge to `main` deploys. Dan decides what is
  built and when it goes live.
- Run the tests and `terraform validate` before calling work done, and say
  plainly what was and was not verified.
- Decisions, design and research for this portal go in this repository's `.claude/`,
  with frontmatter, linked from `.claude/README.md`.
- Infrastructure is applied by the workflows. The only thing run from a person's machine
  is `scripts/seed.sh`, once.

## Where things go

| What | Where |
|---|---|
| What this is and how to run it | `README.md` |
| First-time AWS and GitHub set-up | `runbooks/bootstrap.md` |
| Deploying, and the redirect from the main website | `runbooks/deploy.md` |
| Road map, decisions and research for this portal | `.claude/` |
| The wider product, and the SRA and legal aid research | `../automation-portal/.claude/` |
