#!/usr/bin/env bash
#
# scripts/bootstrap.sh <environment>
#
# Applies the Terraform bootstrap stack: the state bucket, the two entry roles
# and the per-service roles they chain into. Everything the Site workflow
# stands on, and nothing else.
#
# It is run by the Bootstrap workflow, as the seed's bootstrap role, which is
# the only identity allowed to change these roles and which GitHub may only
# assume from the bootstrap environment, behind an approval. It holds no
# credentials and prints none; the workflow has signed in before it starts.
#
#   GITHUB_SUBJECT_PREFIX  how GitHub names this repository in its tokens, from
#                          the OIDC_SUBJECT_PREFIX repository variable
#   AWS_ACCOUNT_ID         optional; asked of AWS when it is not set
#
# Every name it uses comes from the Terraform configuration, so nothing is
# written down twice, and it writes nothing back to GitHub: scripts/names.sh
# works the names out again on every run.
#
# Safe to run again: it is the same apply. Run it after any change to
# infra/envs/<environment>/bootstrap.

set -euo pipefail

SCRIPT_NAME=bootstrap

# shellcheck source=lib/stack.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/stack.sh"

trap remove_overrides EXIT

usage() {
  cat >&2 <<'EOF'
usage: scripts/bootstrap.sh <environment>

  <environment>  the environment token, e.g. dev. Must match the environment
                 in infra/envs/<environment>/platform.tfvars.json.

Requires GITHUB_SUBJECT_PREFIX, and AWS credentials already in the
environment: in GitHub Actions the workflow signs in first, and from a machine
AWS_PROFILE does. The seed must have been applied; see runbooks/bootstrap.md.
EOF
  exit 2
}

[ "$#" -eq 1 ] || usage
environment=$1

require_tools terraform aws python3

[ -n "${GITHUB_SUBJECT_PREFIX:-}" ] ||
  die "GITHUB_SUBJECT_PREFIX is not set. It is the OIDC_SUBJECT_PREFIX repository variable, set by scripts/seed.sh."

stack=$(stack_dir "$environment" bootstrap)
local_state="$stack/terraform.tfstate"

# The state bucket may not exist yet, so the first read and the first apply
# keep state locally. backend_override.tf is git-ignored.
init_local "$stack"
read_script_names "$stack"

configured=$(named environment)
[ "$configured" = "$environment" ] ||
  die "asked for $environment but infra/envs/$environment/platform.tfvars.json says $configured."

ACCOUNT_ID=$(account_id)
bucket=$(state_bucket_name)
region=$(named aws_region)
state_key=$(named bootstrap_state_key)

note "$environment, state bucket $bucket in $region"
note "GitHub subject prefix $GITHUB_SUBJECT_PREFIX"

apply_vars=(
  -var-file="$PLATFORM_VARS"
  -var "github_subject_prefix=$GITHUB_SUBJECT_PREFIX"
)

backend_config=(
  -backend-config="bucket=$bucket"
  -backend-config="key=$state_key"
  -backend-config="region=$region"
)

# --------------------------------------------------------------- apply, once

# A local state file means an earlier first run stopped before its state was
# moved into the bucket: carry on from there.
if [ ! -s "$local_state" ] && aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
  note "state bucket exists; working against it"
  drop_override "$stack"
  terraform -chdir="$stack" init -input=false -no-color -reconfigure "${backend_config[@]}" >/dev/null
  terraform -chdir="$stack" apply -input=false -no-color -auto-approve "${apply_vars[@]}"
else
  note "first run; applying with local state, then moving it into the bucket"
  terraform -chdir="$stack" apply -input=false -no-color -auto-approve "${apply_vars[@]}"

  made=$(terraform -chdir="$stack" output -raw state_bucket)
  [ "$made" = "$bucket" ] ||
    die "expected the state bucket to be $bucket but Terraform made $made. The state is still in $local_state."

  drop_override "$stack"
  terraform -chdir="$stack" init -input=false -no-color -force-copy -migrate-state "${backend_config[@]}" >/dev/null
  rm -f "$local_state" "$local_state.backup"
fi

cat <<EOF

bootstrap: done.

  Bootstrap state  s3://$bucket/$state_key
  Site state       s3://$bucket/$(named site_state_key)

The Site workflow can run: open a pull request to see the plan, merge it to
deploy. Nothing here is applied by hand; this stack is applied by running the
Bootstrap workflow again.
EOF
