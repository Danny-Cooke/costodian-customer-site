#!/usr/bin/env bash
#
# scripts/names.sh <environment>
#
# Prints every name a workflow needs, as key=value lines for $GITHUB_OUTPUT, so
# that no role ARN, bucket, state key or environment name is typed into a
# workflow or kept in a GitHub variable where it could drift from the tfvars:
#
#   scripts/names.sh dev >> "$GITHUB_OUTPUT"
#
# It needs no AWS credentials. Everything but the account id is worked out from
# the Terraform configuration, and the account id comes from AWS_ACCOUNT_ID, a
# repository variable set once by scripts/seed.sh.
#
# Nothing but those lines goes to standard output; progress and errors go to
# standard error.

set -euo pipefail

SCRIPT_NAME=names

# shellcheck source=lib/stack.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/stack.sh"

trap remove_overrides EXIT

usage() {
  cat >&2 <<'EOF'
usage: scripts/names.sh <environment>

  <environment>  the environment token, e.g. dev. Must match the environment
                 in infra/envs/<environment>/platform.tfvars.json.

Requires AWS_ACCOUNT_ID and no credentials. Prints key=value lines.
EOF
  exit 2
}

[ "$#" -eq 1 ] || usage
environment=$1

require_tools terraform python3

bootstrap_dir=$(stack_dir "$environment" bootstrap)
ACCOUNT_ID=$(account_from_environment)

init_local "$bootstrap_dir"
read_script_names "$bootstrap_dir"
drop_override "$bootstrap_dir"

configured=$(named environment)
[ "$configured" = "$environment" ] ||
  die "asked for $environment but infra/envs/$environment/platform.tfvars.json says $configured."

printf 'project=%s\n' "$(named project)"
printf 'aws_region=%s\n' "$(named aws_region)"
printf 'state_bucket=%s\n' "$(state_bucket_name)"
printf 'bootstrap_state_key=%s\n' "$(named bootstrap_state_key)"
printf 'site_state_key=%s\n' "$(named site_state_key)"
printf 'bootstrap_role_arn=%s\n' "$(role_arn bootstrap)"
printf 'plan_role_arn=%s\n' "$(role_arn plan)"
printf 'deploy_role_arn=%s\n' "$(role_arn deploy)"
printf 'publish_role_arn=%s\n' "$(role_arn publish)"
printf 'bootstrap_environment=%s\n' "$(named environments.bootstrap)"
printf 'plan_environment=%s\n' "$(named environments.plan)"
printf 'deploy_environment=%s\n' "$(named environments.deploy)"
