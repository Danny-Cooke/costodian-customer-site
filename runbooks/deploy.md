# Deploy

A merge to `main` deploys. The `Deploy` job applies the Terraform, builds the
site, publishes it to the bucket, clears the CloudFront cache and runs the smoke
test against the live address. Its summary shows the site address.

To deploy without a change, run the workflow by hand from `main`
(`gh workflow run site.yml --ref main`).

## Changing a value on the live site without a commit

Set a variable on the `dev` GitHub environment and run the workflow:

| Variable | Sets |
|---|---|
| `SITE_PRICE_PER_BILL` | the price on the pricing page |
| `SITE_REFUND_DAYS` | the refund period on the pricing page |
| `SITE_CONTACT_EMAIL` | the contact address in the footer |
| `SITE_PREVIEW_ENABLED` | `false` takes the preview banner down |

```bash
gh variable set SITE_PRICE_PER_BILL --env dev --body 12
gh workflow run site.yml --ref main
```

## Sign-up backend

The sign-up API is three Lambda functions sharing one package. Terraform zips
that package but does not build it, so the directory named by `package_dir` in
`infra/envs/dev/site/terraform.tfvars` must exist before `terraform plan` or
`apply` runs. From the repository root that is `build/api`, holding
`handler.py`, `validation.py` and `config.json`. A missing directory fails the
plan, which is the intended behaviour: no plan should ever zip a stale package.
`build/` is not committed.

## One role per service

The deploy job signs in to the `deploy` role, which can read and write the
state object and assume the service roles, and do nothing else. Each provider
in the site stack then assumes the role for its own service, so the bucket, the
key, the table, the pool, the functions and their IAM roles are each created by
a different identity. Terraform is told to do that by
`-var="assume_service_roles=true"`; the plan job on a pull request runs with it
false and uses the read-only plan role's own credentials for everything.

Publishing the built site is not Terraform's work: the workflow chains from the
`deploy` role into the `publish` role (`AWS_PUBLISH_ROLE_ARN` on the `dev`
environment) for the bucket sync and the cache invalidation, and that role can
touch nothing else.

The roles themselves are in `runbooks/bootstrap.md`.

The site stack gains these outputs, which the browser code needs:

| Output | What it is |
|---|---|
| `user_pool_id` | the Cognito pool to sign in against |
| `user_pool_client_id` | the app client; public by design, it has no secret |
| `cognito_endpoint` | the regional Cognito address the browser calls |
| `password_minimum_length` | the length the pool enforces, so the page can state it |
| `api_base_path` | the path the API is reached on, on the site's own address |
| `account_table_name` | the table holding the account record |

The API has no address of its own that the browser uses: CloudFront forwards
`/api/*` to it, so it is same-origin and the token never crosses an origin.
Every route requires a Cognito token, checked by the API before any function
runs.

## The short address on the main website

The site is served on its CloudFront address. The short address on the main
website is a redirect made there, by hand, once:

1. Take the line from the deploy summary, or from
   `terraform output -raw krystal_redirect_line` in `infra/envs/dev/site`.
2. Add it to the `.htaccess` file in the main website's web root at the hosting
   provider.
3. Check the short address forwards to the site.

The visitor's address bar shows the CloudFront address after the redirect. To
keep the firm's own domain in the address bar, the site needs a subdomain, a
certificate and a DNS record; that is not built.

## If the smoke test fails

The job prints which page or header failed. The site has already been published
at that point. To go back, revert the commit on `main`; the next deploy publishes
the previous site.
