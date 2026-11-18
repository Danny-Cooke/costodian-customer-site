# Bootstrap: once per environment

```bash
export AWS_PROFILE=<an administrator profile for the account>
scripts/bootstrap.sh dev
```

That is the whole of it, and it is the only thing anyone applies by hand.
Everything else is built by the GitHub pipeline, signing in with GitHub's own
identity token. No AWS keys exist anywhere.

## What the script does

1. Initialises `infra/envs/dev/bootstrap` with a local backend, because the
   state bucket may not exist yet. The override file it writes is git-ignored.
2. Checks the environment you asked for against
   `infra/envs/dev/platform.tfvars.json`, and reads the state bucket's name out
   of the configuration — before there is any state to read it from.
3. Applies the stack. If the bucket already exists it initialises against it
   first; if not, it applies locally and then migrates the state into the
   bucket and removes the local files.
4. Creates the GitHub environments named in the `role_arns` output and sets on
   each: `AWS_ROLE_ARN`, `AWS_REGION`, `TF_STATE_BUCKET`, `TF_STATE_KEY`, plus
   `AWS_PUBLISH_ROLE_ARN` on the deploy environment. The repository comes from
   the Terraform outputs, not from anything typed twice.

Run it again whenever the bootstrap stack changes; it is the same apply.

## What it creates

The state bucket, the GitHub sign-in provider, and ten roles. None of them can
do everything:

| Role | Reached by | Holds |
|---|---|---|
| `plan` | OIDC from the `dev-plan` environment | the read actions of every service, and read of the site state. It can change nothing. |
| `deploy` | OIDC from the `dev` environment | read and write of the site state object and its lock, and `sts:AssumeRole` on the service roles. Nothing else at all. |
| `storage` | chained from `deploy` | the site bucket |
| `keys` | chained from `deploy` | the sign-up KMS key and alias |
| `edge` | chained from `deploy` | CloudFront and the web ACL |
| `identity` | chained from `deploy` | the Cognito pool and client |
| `data` | chained from `deploy` | the account table |
| `compute` | chained from `deploy` | the functions, the HTTP API, the log groups |
| `access` | chained from `deploy` | the functions' IAM roles, and only with the permissions boundary |
| `publish` | chained from `deploy`, by the workflow's publish step | put and delete objects in the site bucket, and invalidate the cache |

Each service role is trusted by the `deploy` role alone, so GitHub cannot reach
one directly. The site stack's providers each assume the role for their own
service, which is why the identity that creates a bucket cannot write IAM.

The `access` role is additionally denied `iam:CreateRole`, `iam:PutRolePolicy`
and `iam:AttachRolePolicy` unless the role carries the permissions boundary
created here, and is denied every IAM write on that boundary and on the
pipeline's own roles. It cannot widen its own ceiling.

## Changing what a role may do

Every action is in `service_roles` in
`infra/envs/dev/bootstrap/terraform.tfvars`, one entry per service, split into
`read_actions` and `write_actions`. The service role gets both; the plan role
gets every service's `read_actions` and no write action, so the two cannot
drift apart. Add the action and run `scripts/bootstrap.sh dev` again.

If a deploy fails with an access denied error, the message names the action and
the service; that is where it goes.

## If the account already has a GitHub sign-in provider

An account can hold only one per issuer. Set `create_oidc_provider = false` in
`infra/envs/dev/bootstrap/terraform.tfvars` before the first run.

## Taking it down

`scripts/destroy.sh dev` is the reverse: it empties the versioned buckets,
destroys the site stack and then the bootstrap stack, and asks for the
project's name to be typed first. It destroys the account table and the
sign-in pool, so it is not something to run to tidy up.
