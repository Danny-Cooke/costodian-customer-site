#!/usr/bin/env bash
#
# scripts/seed.sh <environment>
#
# The one thing a person applies by hand, once per environment, and the only
# thing not applied by a GitHub workflow:
#
#   export AWS_PROFILE=<an administrator profile for the account>
#   scripts/seed.sh dev
#
# It applies infra/seed/seed.yaml - CloudFormation, so that it needs no state
# bucket and no role, which are the two things it exists to create the footing
# for. That stack holds GitHub's sign-in to the account and one role, the
# bootstrap role, which GitHub may assume from one environment of this
# repository and which may do nothing but apply and destroy the Terraform
# bootstrap stack.
#
# Then it tells GitHub the two things a workflow cannot work out for itself:
# the account id, and how GitHub names this repository in its tokens. Every
# other name comes from scripts/names.sh at run time.
#
# Everything it uses comes from the Terraform configuration, so no name is
# written down twice. Safe to run again: the stack is updated in place, the
# variables are set to the same values, and an environment that exists is left
# as it is.
#
# After this, nothing else is applied by hand: run the Bootstrap workflow, then
# the Site workflow. See runbooks/bootstrap.md.

set -euo pipefail

SCRIPT_NAME=seed

# shellcheck source=lib/stack.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/stack.sh"

trap remove_overrides EXIT

usage() {
  cat >&2 <<'EOF'
usage: scripts/seed.sh <environment>

  <environment>  the environment token, e.g. dev. Must match the environment
                 in infra/envs/<environment>/platform.tfvars.json.

Requires AWS_PROFILE to name an administrator profile for the account, and the
gh command line to be signed in to GitHub as the person who should approve a
bootstrap run.

  SEED_ALLOW_NO_REVIEWER=1  carry on when GitHub refuses a required reviewer
                            on the bootstrap environment (it needs a public
                            repository or a paid plan).
EOF
  exit 2
}

[ "$#" -eq 1 ] || usage
environment=$1

require_tools terraform aws gh python3

template="$REPO_ROOT/infra/seed/seed.yaml"
[ -f "$template" ] || die "no template at infra/seed/seed.yaml."

[ -n "${AWS_PROFILE:-}" ] ||
  die "export AWS_PROFILE with an administrator profile for the account first."

bootstrap_dir=$(stack_dir "$environment" bootstrap)

# ------------------------------------------------- what GitHub calls this repo

init_local "$bootstrap_dir"
read_script_names "$bootstrap_dir"

configured=$(named environment)
[ "$configured" = "$environment" ] ||
  die "asked for $environment but infra/envs/$environment/platform.tfvars.json says $configured."

repository=$(named repository_path)

# GitHub decides how a repository is named in the tokens it issues, and the
# role has to trust exactly that, so it is asked rather than assumed. A
# repository set to immutable subjects is named by owner and repository id as
# well as by name, so a rename cannot hand its roles to another repository.
# Empty means GitHub uses the plain form, which the configuration falls back to.
from_github=$(gh api "repos/$repository/actions/oidc/customization/sub" --jq '.sub_claim_prefix // ""' 2>/dev/null || true)

# Read again, now that the prefix is known, so that the subject the role trusts
# is composed by Terraform and not here.
read_script_names "$bootstrap_dir" -var "github_subject_prefix=$from_github"
drop_override "$bootstrap_dir"

subject_prefix=$(named subject_prefix)
subject=$(named seed.subject)

ACCOUNT_ID=$(account_id)
region=$(named aws_region)
stack_name=$(named seed.stack_name)

note "$environment in account $ACCOUNT_ID ($region)"
note "GitHub subject $subject"

# --------------------------------------------------------- the seed itself

parameters=(
  "ProductTag=$(named seed.tags.Product)"
  "ProjectTag=$(named seed.tags.Project)"
  "EnvironmentTag=$(named seed.tags.Environment)"
  "RepositoryTag=$(named seed.tags.Repository)"
  "ManagedByTag=$(named seed.tags.ManagedBy)"
  "OwnerTag=$(named seed.tags.Owner)"
  "ComponentTag=$(named seed.tags.Component)"
  "BootstrapRoleName=$(named seed.role_name)"
  "BootstrapPolicyName=$(named seed.policy_name)"
  "BootstrapRoleMaxSessionSeconds=$(named seed.role_max_session_seconds)"
  "CiNamePrefix=$(named seed.ci_name_prefix)"
  "GitHubSubject=$subject"
  "CreateOidcProvider=$(named seed.create_oidc_provider)"
  "OidcProviderName=$(named seed.oidc_name)"
  "GitHubOidcUrl=$(named seed.oidc_url)"
  "GitHubOidcHost=$(named seed.oidc_host)"
  "GitHubOidcAudience=$(named seed.oidc_audience)"
  "GitHubOidcThumbprints=$(named seed.oidc_thumbprints)"
  "StateBucketName=$(state_bucket_name)"
  "BootstrapStateKey=$(named bootstrap_state_key)"
  "StateLockSuffix=$(named seed.state_lock_suffix)"
)

note "applying the CloudFormation stack $stack_name"
aws cloudformation deploy \
  --template-file "$template" \
  --stack-name "$stack_name" \
  --region "$region" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides "${parameters[@]}"

bootstrap_role_arn=$(role_arn bootstrap)

# ------------------------------------------------------------- the GitHub side

note "setting the repository variables of $repository"
gh variable set AWS_ACCOUNT_ID --repo "$repository" --body "$ACCOUNT_ID"
gh variable set OIDC_SUBJECT_PREFIX --repo "$repository" --body "$subject_prefix"

bootstrap_environment=$(named environments.bootstrap)
plan_environment=$(named environments.plan)
deploy_environment=$(named environments.deploy)

# The bootstrap environment is the gate on the one role that can change the
# pipeline's own permissions, so it asks a person first. The person is whoever
# is signed in to gh here, which is whoever is seeding the account.
reviewer=$(gh api user --jq '.login')
reviewer_id=$(gh api user --jq '.id')
reviewed=yes

note "creating the $bootstrap_environment environment, approved by $reviewer"
if ! python3 -c '
import json
import sys

print(json.dumps({
    "wait_timer": 0,
    "prevent_self_review": False,
    "reviewers": [{"type": "User", "id": int(sys.argv[1])}],
    "deployment_branch_policy": None,
}))
' "$reviewer_id" | gh api -X PUT "repos/$repository/environments/$bootstrap_environment" --input - >/dev/null; then
  reviewed=no
  note "GitHub would not set a required reviewer on $bootstrap_environment (a private repository needs a paid plan). Creating it without one."
  gh api -X PUT "repos/$repository/environments/$bootstrap_environment" >/dev/null
fi

# The plan and deploy environments are reached by the pipeline on every pull
# request and every merge, so they hold no gate.
for github_environment in "$plan_environment" "$deploy_environment"; do
  note "creating the $github_environment environment"
  gh api -X PUT "repos/$repository/environments/$github_environment" >/dev/null
done

# --------------------------------------------------------------------- done

cat <<EOF

seed: done.

  CloudFormation  $stack_name in $region
  Bootstrap role  $bootstrap_role_arn
  Trusted subject $subject

  Repository variables  AWS_ACCOUNT_ID=$ACCOUNT_ID
                        OIDC_SUBJECT_PREFIX=$subject_prefix

  Environments    $bootstrap_environment (reviewer required: $reviewed)
                  $plan_environment, $deploy_environment

Next, with nothing applied by hand again:

  gh workflow run bootstrap.yml   # the state bucket and the pipeline's roles
  gh workflow run site.yml        # or merge to main

EOF

if [ "$reviewed" = no ] && [ -z "${SEED_ALLOW_NO_REVIEWER:-}" ]; then
  die "$bootstrap_environment has no required reviewer, so a bootstrap or destroy run would need no approval. Add one in the repository's settings, or re-run with SEED_ALLOW_NO_REVIEWER=1 to accept it."
fi
