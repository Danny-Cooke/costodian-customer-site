#!/usr/bin/env bash
#
# scripts/bootstrap.sh <environment>
#
# The one thing a person applies by hand, once per environment. Everything else
# is built by the GitHub pipeline, which this gives its footing: the GitHub
# sign-in provider, the Terraform state bucket, the two entry roles and the
# per-service roles they chain into. Afterwards it writes the names of those
# things into the GitHub environments, so no ARN is ever typed into a workflow.
#
# Run it with an administrator profile for the target account already exported:
#
#   export AWS_PROFILE=<an administrator profile>
#   scripts/bootstrap.sh dev
#
# It holds no credentials and prints none. Every name it uses comes from
# Terraform - the state bucket from the configuration before any state exists,
# everything else from the outputs - so nothing is written down twice.
#
# Safe to run again: it is the same apply, and the GitHub variables are set to
# the same values.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: scripts/bootstrap.sh <environment>

  <environment>  the environment token, e.g. dev. Must match the environment
                 in infra/envs/<environment>/platform.tfvars.json.

Requires AWS_PROFILE to name an administrator profile for the account, and
the gh command line to be signed in to GitHub.
EOF
  exit 2
}

[ "$#" -eq 1 ] || usage
environment=$1

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
stack_dir="$repo_root/infra/envs/$environment/bootstrap"
platform_vars="../platform.tfvars.json"
override_file="$stack_dir/backend_override.tf"

for tool in terraform aws gh python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "bootstrap: $tool is not on PATH." >&2
    exit 1
  }
done

[ -d "$stack_dir" ] || {
  echo "bootstrap: no stack at $stack_dir." >&2
  exit 1
}

[ -n "${AWS_PROFILE:-}" ] || {
  echo "bootstrap: export AWS_PROFILE with an administrator profile for the account first." >&2
  exit 1
}

tf() {
  terraform -chdir="$stack_dir" "$@"
}

# Reads one expression out of the configuration. Used for the state bucket's
# name, which has to be known before there is any state to read it from.
tf_console() {
  printf '%s\n' "$1" | tf console -no-color -var-file="$platform_vars" | tr -d '"'
}

# The keys of a JSON object, one per line, and one of its values. Python is
# already needed to build the site, so nothing else has to be installed.
json_keys() {
  python3 -c 'import json, sys; print("\n".join(sorted(json.loads(sys.argv[1]))))' "$1"
}

json_value() {
  python3 -c 'import json, sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"
}

cleanup() {
  rm -f "$override_file"
}
trap cleanup EXIT

# ---------------------------------------------------------------- local state

# The state bucket may not exist yet, so the first init keeps state locally.
# backend_override.tf is git-ignored.
printf 'terraform {\n  backend "local" {}\n}\n' >"$override_file"
tf init -input=false -no-color >/dev/null

configured_environment=$(tf_console 'var.platform.environment')
if [ "$configured_environment" != "$environment" ]; then
  echo "bootstrap: asked for $environment but infra/envs/$environment/platform.tfvars.json says $configured_environment." >&2
  exit 1
fi

# The bucket's name ends with the account id, which Terraform only learns when
# it runs. Before there is any state, the name is worked out here from the same
# two parts; after the apply it is checked against what Terraform made.
account=$(aws sts get-caller-identity --query Account --output text)
bucket="$(tf_console 'module.naming.unvalidated_names["state"]')-$account"
local_state="$stack_dir/terraform.tfstate"
region=$(tf_console 'var.platform.region')
state_key=$(tf_console 'var.bootstrap_state_key')

echo "bootstrap: $environment, state bucket $bucket in $region"

backend_config=(
  -backend-config="bucket=$bucket"
  -backend-config="key=$state_key"
  -backend-config="region=$region"
)

# --------------------------------------------------------------- apply, once

# A local state file means an earlier first run stopped before its state was
# moved into the bucket: carry on from there.
if [ ! -s "$local_state" ] && aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
  echo "bootstrap: state bucket exists; working against it"
  rm -f "$override_file"
  tf init -input=false -no-color -reconfigure "${backend_config[@]}" >/dev/null
  tf apply -input=false -no-color -auto-approve -var-file="$platform_vars"
else
  echo "bootstrap: first run; applying with local state, then moving it into the bucket"
  tf apply -input=false -no-color -auto-approve -var-file="$platform_vars"
  made=$(tf output -raw state_bucket)
  if [ "$made" != "$bucket" ]; then
    echo "bootstrap: expected the state bucket to be $bucket but Terraform made $made. The state is still in $local_state." >&2
    exit 1
  fi
  rm -f "$override_file"
  tf init -input=false -no-color -force-copy -migrate-state "${backend_config[@]}" >/dev/null
  rm -f "$local_state" "$local_state.backup"
fi

# ------------------------------------------------------- the GitHub side

repository=$(tf output -raw github_repository_path)
state_bucket=$(tf output -raw state_bucket)
site_state_key=$(tf output -raw site_state_key)
aws_region=$(tf output -raw aws_region)
deploy_environment=$(tf output -raw deploy_environment)
publish_role_arn=$(tf output -raw publish_role_arn)
role_arns=$(tf output -json role_arns)

echo "bootstrap: setting the GitHub environments of $repository"

while IFS= read -r github_environment; do
  role_arn=$(json_value "$role_arns" "$github_environment")

  gh api -X PUT "repos/$repository/environments/$github_environment" >/dev/null

  gh variable set AWS_ROLE_ARN --repo "$repository" --env "$github_environment" --body "$role_arn"
  gh variable set AWS_REGION --repo "$repository" --env "$github_environment" --body "$aws_region"
  gh variable set TF_STATE_BUCKET --repo "$repository" --env "$github_environment" --body "$state_bucket"
  gh variable set TF_STATE_KEY --repo "$repository" --env "$github_environment" --body "$site_state_key"

  echo "bootstrap:   $github_environment -> $role_arn"
done < <(json_keys "$role_arns")

# Only the deploy environment publishes, and it reaches the publish role by
# chaining from its own role rather than from GitHub.
gh variable set AWS_PUBLISH_ROLE_ARN --repo "$repository" --env "$deploy_environment" --body "$publish_role_arn"
echo "bootstrap:   $deploy_environment -> $publish_role_arn (publish)"

cat <<EOF

bootstrap: done.

  State      s3://$state_bucket/$state_key
  Site state s3://$state_bucket/$site_state_key

Open a pull request to see the plan job run, and merge it to deploy. Nothing
else is applied by hand; changes to this stack are applied by running this
script again.
EOF
