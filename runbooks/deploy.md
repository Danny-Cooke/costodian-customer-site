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

The sign-up API is six Lambda functions sharing one package, one per job:
`read` reads the account record, `enrol` joins a person to a firm, `write`
saves a section of company information, `accept` records the agreement,
`people` invites, changes and removes the firm's members, and `catalogue`
answers no request at all — it keeps the product's version catalogue, and a
version tag is its only caller. Each has its own role
built from the exact actions listed against it in `functions` in
`infra/envs/dev/site/terraform.tfvars`: only `enrol` can list the pool of
customer numbers or read the old shared table, and only `enrol` and `people` may
act on the sign-in pool. `data_actions` are the exception: no role may reach a
customer's table, so those are what the function asks for in the session policy
it passes when it takes credentials for one customer. Changing what a
function may do, or adding a function, is an edit to that map, deployed by the
pipeline like any other commit. Changing the ceiling those roles carry
(`function_boundary`) or what the pipeline's own roles may do (`service_roles`)
is an edit to `infra/envs/dev/bootstrap/terraform.tfvars` and needs the
`Bootstrap` workflow run, with an approval, before the Site workflow runs: the
deploy role cannot widen its own ceiling, which is the point of keeping it in a
separate stack reached by a separate role. See `runbooks/bootstrap.md`.

The customer pool and the version catalogue are such a change: they add a ninth
service role (`parameters`), widen the `keys`, `data` and `access` roles to the
customer component, give the `compute` role the EventBridge actions, and widen
the boundary. **Run the `Bootstrap` workflow and let it finish before the next
Site deploy.** Without it the deploy fails on the first SSM call, because the
role the parameters provider assumes does not exist yet.

## Product versions

The versions of the product that exist are one SSM parameter, a JSON list, at
the `versions_parameter_name` output. Terraform writes the list it starts with —
`initial_versions` in `infra/envs/dev/platform.tfvars.json`, which the site
build reads from the same file — and never writes the value again.

After that the catalogue grows by itself. Creating or moving a git tag in the
`aft-global-customizations` repository in this account raises a CodeCommit
event; an EventBridge rule matches it and invokes the `catalogue` function,
which appends the tag to the list if it looks like a version
(`version_tag_pattern`, today `v1.0` or `v1.0.1`, not `v1` and not
`v1.0-rc1`). The rule names that one repository by ARN and matches tags only,
so a branch, a commit, or a tag in any other repository does nothing.

To change which repository, which events, or what counts as a version, edit
`version_source_repository`, `version_source_event` or `version_tag_pattern` in
`infra/envs/dev/site/terraform.tfvars` and deploy. To add a version by hand,
write the parameter; Terraform will leave it alone.

## Customer tables

Every customer — a firm that has signed up — has a DynamoDB table and a KMS key
of its own, named by a four-digit number: `0001`, `0002`. Nothing is created
when a firm signs up. The tables are made in advance, as a pool, so signing up
is a firm taking a number that is already there.

The pool tops itself up on every pipeline run. Terraform reads the customers'
labels, finds the highest number anyone has taken, and makes sure there are
`customer_spares` numbers beyond it (ten). So a run after the fourth customer
signs up leaves numbers `0001` to `0014` in place: four taken, ten waiting.

Each number also has a small label, an SSM parameter at
`<customer path>/<number>` (the `customer_parameter_path` output), holding which number it is and how far
that customer has got. Terraform creates it free; the API rewrites it as the
firm signs up and works through its set-up, and Terraform leaves the value alone
after that. A label that cannot be read counts as taken, so a broken label can
never shrink the pool and take a live customer's table with it.

The pool never shrinks by itself. A number only leaves it by being named, and
that takes two runs:

1. Add the number to `unprotected_customer_numbers` in
   `infra/envs/dev/site/terraform.tfvars` and deploy. That one table's deletion
   protection comes off; nothing else changes.
2. Move the number to `removed_customer_numbers` and deploy. The table, the key
   and the label are destroyed.

Leave the number in `removed_customer_numbers` afterwards: taking it out would
put the table back. The plan refuses the second step if the first has not been
done, and refuses any plan that would drop a number somebody has taken.

No function can reach a customer's table. Each one takes short-lived credentials
from the customer data role for each request, with a session policy that narrows
them to the one customer the signed-in person belongs to; which customer that is
is in their sign-in as `custom:customer`, which only the API can set. The browser
can read it and cannot write it.

The table every firm shared before this stays, with its deletion protection, and
only the `enrol` function can still read it: a firm that signed up before the
change is moved into a table of its own the next time its owner signs in. It can
be taken out of `infra/modules/account` once there is nothing left in it.

Terraform zips that package but does not build it, so the directory named by
`package_dir` in `infra/envs/dev/site/terraform.tfvars` must exist before
`terraform plan` or `apply` runs. From the repository root that is `build/api`,
holding `handler.py`, `validation.py` and `config.json`. A missing directory fails the
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
`deploy` role into the `publish` role for the bucket sync and the cache
invalidation, and that role can touch nothing else. Its ARN, like every other,
comes from `scripts/names.sh` in the workflow's `Names` job, not from a GitHub
variable.

The roles themselves are in `runbooks/bootstrap.md`.

The site stack gains these outputs, which the browser code needs:

| Output | What it is |
|---|---|
| `user_pool_id` | the Cognito pool to sign in against |
| `user_pool_client_id` | the app client; public by design, it has no secret |
| `cognito_endpoint` | the regional Cognito address the browser calls |
| `password_minimum_length` | the length the pool enforces, so the page can state it |
| `invite_expiry_days` | how long an invited member's temporary password lasts |
| `api_base_path` | the path the API is reached on, on the site's own address |
| `account_table_name` | the one table every firm shared before each had its own |
| `customer_parameter_path` | the SSM path holding one label per customer number |
| `customer_table_name_template` | a customer's table name, with `{number}` where the number goes |
| `customer_table_arn_template` | the same as an ARN, which is what a session policy names |
| `customer_key_alias_template` | a customer's key alias, in the form the `kms:ResourceAliases` condition takes |
| `customer_numbers` | every number in the pool, taken and free |
| `customer_free_status` | the status word in a label that means nobody has taken that number |
| `customer_attribute` | the token claim holding a person's customer number |
| `customer_data_role_arn` | the role a function assumes to reach one customer's table |
| `versions_parameter_name` | the parameter holding the product's version catalogue |

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
