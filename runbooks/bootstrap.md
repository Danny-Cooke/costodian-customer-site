# Bootstrap: one seed by hand, everything else in GitHub

Everything runs in GitHub Actions, signing in with GitHub's own identity token.
No AWS keys exist anywhere. The only thing a person ever applies from their own
machine is the seed, once per environment.

| Step | Run by | What it does |
|---|---|---|
| `scripts/seed.sh dev` | a person, once | GitHub's sign-in to the account, the bootstrap role, the GitHub environments and two repository variables |
| `Bootstrap` workflow | by hand, on demand | the Terraform state bucket and the pipeline's roles |
| `Site` workflow | every pull request and merge | plans and deploys the site |
| `Destroy` workflow | by hand, on demand | takes the site, the roles and the state bucket down again |

## 1. The seed

```bash
export AWS_PROFILE=<an administrator profile for the account>
gh auth status                      # signed in as whoever should approve a bootstrap run
scripts/seed.sh dev
```

It applies `infra/seed/seed.yaml` with CloudFormation, not Terraform, because
Terraform would need a state bucket and a role to create it with — the two
things the seed exists to make possible. It is idempotent: run it again after a
change to the template or to the values it reads.

What it creates:

- **GitHub's sign-in to the account**, the OpenID Connect provider for
  `token.actions.githubusercontent.com`. An account holds one per issuer, it is
  never destroyed, and nothing in the pipeline may change it.
- **The bootstrap role**, `<project>-dev-ci-bootstrap-role`. GitHub may assume
  it from the `dev-bootstrap` environment of this repository and nowhere else.
  It may create, read, change and delete the pipeline's roles and policies
  under the `<project>-dev-ci-` prefix and the Terraform state bucket, and
  nothing else at all. It is explicitly denied every write on its own role, on
  the sign-in provider and on any CloudFormation stack, so it cannot widen
  itself or remove the seed.

What it sets in GitHub:

- Repository variables `AWS_ACCOUNT_ID` and `OIDC_SUBJECT_PREFIX`. Those two
  values are the only things a workflow cannot work out for itself; every role
  ARN, bucket, state key and environment name comes from `scripts/names.sh`,
  which reads the tfvars at run time.
- The `dev-bootstrap` environment, with the signed-in GitHub user as a
  **required reviewer**, and the `dev-plan` and `dev` environments, unprotected.

A required reviewer needs a public repository or a paid plan. If GitHub refuses
one, the script says so, creates the environment without it and exits non-zero;
`SEED_ALLOW_NO_REVIEWER=1` accepts that knowingly. Without it, anyone who can
run a workflow can change the pipeline's permissions.

Every value the script uses comes from the Terraform configuration
(`infra/envs/dev/platform.tfvars.json` and
`infra/envs/dev/bootstrap/terraform.tfvars`), read with `terraform console`, so
no name is written down twice and nothing project-specific is typed into the
CloudFormation template.

### If the account already has a GitHub sign-in provider

An account can hold only one per issuer. Set `create_oidc_provider = false` in
`infra/envs/dev/bootstrap/terraform.tfvars` before the first seed; the role
trusts the provider either way.

## 2. The Bootstrap workflow

```bash
gh workflow run bootstrap.yml
```

It runs `scripts/bootstrap.sh dev` as the bootstrap role, behind the
`dev-bootstrap` environment's approval. The script applies
`infra/envs/dev/bootstrap`: the state bucket, the two entry roles and the
per-service roles they chain into. On the first run the state is kept locally
and then migrated into the bucket it has just made; after that it works against
the bucket. It writes nothing back to GitHub.

Run it again after any change to that stack — a new action for a service role,
a new service, a change to the ceiling the functions' roles carry. The pipeline
cannot widen its own permissions, which is why this is a separate stack behind
a separate approval.

## What the pipeline's roles are

None of them can do everything:

| Role | Reached by | Holds |
|---|---|---|
| `bootstrap` | OIDC from `dev-bootstrap`, with approval. Created by the seed | the pipeline's own roles and policies, and the state bucket |
| `plan` | OIDC from `dev-plan` | the read actions of every service, and read of the site state. It can change nothing |
| `deploy` | OIDC from `dev` | read and write of the site state object and its lock, and `sts:AssumeRole` on the service roles. Nothing else |
| `storage` | chained from `deploy` | the site bucket, and its objects' deletes so a destroy can empty it |
| `keys` | chained from `deploy` | the sign-up KMS key and alias |
| `edge` | chained from `deploy` | CloudFront and the web ACL, and sight of the certificate |
| `certificates` | chained from `deploy` | the site's certificate, in the edge Region |
| `dns` | chained from `deploy` | records in the site's own hosted zone, and no other zone |
| `email` | chained from `deploy` | the domain's sending identity in SES and its configuration set. It cannot send |
| `identity` | chained from `deploy` | the Cognito pool and client, and telling the pool to send through the domain's identity |
| `data` | chained from `deploy` | the account table |
| `compute` | chained from `deploy` | the functions, the HTTP API, the log groups |
| `access` | chained from `deploy` | the functions' IAM roles, and only with the permissions boundary |
| `publish` | chained from `deploy`, by the workflow's publish step | put and delete objects in the site bucket, and invalidate the cache |

Each service role is trusted by the `deploy` role alone, so GitHub cannot reach
one directly. The site stack's providers each assume the role for their own
service, which is why the identity that creates a bucket cannot write IAM.

The `access` role is additionally denied `iam:CreateRole`, `iam:PutRolePolicy`
and `iam:AttachRolePolicy` unless the role carries the permissions boundary, and
is denied every IAM write on that boundary and on the pipeline's own roles. It
cannot widen its own ceiling.

## Changing what a role may do

Every action is in `service_roles` in
`infra/envs/dev/bootstrap/terraform.tfvars`, one entry per service, split into
`read_actions` and `write_actions`. The service role gets both; the plan role
gets every service's `read_actions` and no write action, so the two cannot drift
apart. The Destroy workflow runs as these same roles, so each needs the deletes
for what it creates.

Add the action, then run the Bootstrap workflow. If a deploy fails with an
access denied error, the message names the action and the service; that is where
it goes.

What the **bootstrap role** may do is in `infra/seed/seed.yaml` instead, and a
change there needs `scripts/seed.sh dev` run by a person again.

## Taking it down

```bash
gh workflow run destroy.yml -f confirm=<the project name>
```

Two jobs, because the halves run as different identities: the site, the sign-up
API, the Cognito pool, the account table and its key as the deploy role and its
service roles; then the pipeline's roles and the state bucket as the bootstrap
role, behind the same approval as a bootstrap run. The typed project name has
to match, and the second job runs `scripts/destroy.sh dev bootstrap`, which
brings the bootstrap state back to a local file before deleting the bucket it
lives in.

The seed survives a destroy: the sign-in provider, the bootstrap role, the
GitHub environments and the two repository variables are all left in place, so
the Bootstrap and Site workflows build the whole environment again with no
further work by hand.

## The scripts

Each one is run by exactly one identity, and none of them needs a value typed
in:

| Script | Run as | Needs |
|---|---|---|
| `scripts/seed.sh <env>` | a person, administrator profile | `AWS_PROFILE`, `gh` signed in |
| `scripts/names.sh <env>` | nobody; no credentials at all | `AWS_ACCOUNT_ID` |
| `scripts/bootstrap.sh <env>` | the bootstrap role | `GITHUB_SUBJECT_PREFIX` |
| `scripts/destroy.sh <env> site` | the deploy role | `CONFIRM_PROJECT`, `ASSUME_SERVICE_ROLES=true` |
| `scripts/destroy.sh <env> bootstrap` | the bootstrap role | `CONFIRM_PROJECT` |

`scripts/names.sh` prints `key=value` lines for `$GITHUB_OUTPUT` and reads the
tfvars with a local Terraform backend, so it needs no state, no bucket and no
credentials. `scripts/lib/stack.sh` is shared by all four.
