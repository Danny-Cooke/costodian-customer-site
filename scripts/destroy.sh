#!/usr/bin/env bash
#
# scripts/destroy.sh <environment> <site|bootstrap>
#
# The reverse of the Bootstrap and Site workflows, in two halves, because in
# GitHub each half runs as a different identity and the Destroy workflow runs
# them as two jobs:
#
#   site       the site, the sign-up API, the Cognito pool, the account table
#              and its key. Run as the deploy role, with each provider chaining
#              into its own service role, so the destroy is done by the same
#              identities that did the create.
#   bootstrap  the pipeline's roles and the state bucket. Run as the seed's
#              bootstrap role.
#
# Neither half touches the seed: GitHub's sign-in to the account and the
# bootstrap role itself are left in place, so the Bootstrap workflow can build
# it all again.
#
# It destroys customer-facing infrastructure, so it will not run unless it is
# told what it is destroying:
#
#   CONFIRM_PROJECT        must equal the project name. There is no prompt.
#   ASSUME_SERVICE_ROLES   true in the pipeline, where the job holds the deploy
#                          role; false when a run already holds credentials
#                          that can do the work themselves.
#   AWS_ACCOUNT_ID         optional; asked of AWS when it is not set.
#   GITHUB_SUBJECT_PREFIX  optional; only the trust policies read it, and they
#                          are being destroyed.

set -euo pipefail

SCRIPT_NAME=destroy

# shellcheck source=lib/stack.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/stack.sh"

trap remove_overrides EXIT

usage() {
  cat >&2 <<'EOF'
usage: scripts/destroy.sh <environment> <site|bootstrap>

  <environment>  the environment token, e.g. dev.
  site           destroys the site stack, as the deploy role.
  bootstrap      destroys the pipeline's roles and the state bucket, as the
                 bootstrap role. Run it after site.

Requires CONFIRM_PROJECT to equal the project name, and AWS credentials
already in the environment.
EOF
  exit 2
}

[ "$#" -eq 2 ] || usage
environment=$1
half=$2

case "$half" in
site | bootstrap) ;;
*) usage ;;
esac

require_tools terraform aws python3

bootstrap_stack=$(stack_dir "$environment" bootstrap)
site_stack=$(stack_dir "$environment" site)

# A versioned bucket cannot be deleted until every version and delete marker is
# gone. Terraform empties the site bucket itself, under the storage role, when
# web_bucket_force_destroy is set; the state bucket is emptied here, because by
# then it is out of Terraform's hands.
empty_bucket() {
  local bucket=$1
  aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1 || return 0
  python3 - "$bucket" <<'PY'
import json
import subprocess
import sys

bucket = sys.argv[1]
while True:
    listed = subprocess.check_output(
        ["aws", "s3api", "list-object-versions", "--bucket", bucket, "--max-items", "500", "--output", "json"]
    )
    found = json.loads(listed or b"{}")
    objects = [
        {"Key": entry["Key"], "VersionId": entry["VersionId"]}
        for kind in ("Versions", "DeleteMarkers")
        for entry in found.get(kind) or []
    ]
    if not objects:
        break
    subprocess.check_call(
        ["aws", "s3api", "delete-objects", "--bucket", bucket, "--delete", json.dumps({"Objects": objects, "Quiet": True})],
        stdout=subprocess.DEVNULL,
    )
    print(f"destroy:   removed {len(objects)} versions from {bucket}", file=sys.stderr)
PY
}

# ------------------------------------------------------------------- confirm

# The names come from the configuration, with a local backend, so that reading
# them needs no state and no credentials.
init_local "$bootstrap_stack"
read_script_names "$bootstrap_stack"
drop_override "$bootstrap_stack"

configured=$(named environment)
[ "$configured" = "$environment" ] ||
  die "asked for $environment but infra/envs/$environment/platform.tfvars.json says $configured."

project=$(named project)
[ "${CONFIRM_PROJECT:-}" = "$project" ] ||
  die "not confirmed: set CONFIRM_PROJECT to $project to destroy the $half half of $environment. Nothing done."

ACCOUNT_ID=$(account_id)
state_bucket=$(state_bucket_name)
region=$(named aws_region)
bootstrap_state_key=$(named bootstrap_state_key)
site_state_key=$(named site_state_key)

note "$half half of $project in $environment ($region)"

# ---------------------------------------------------------------- the site

if [ "$half" = site ]; then
  # Terraform reads the function package while planning the destroy, so it has
  # to be there. Read with a local backend: no state, no lock, no credentials.
  init_local "$site_stack"
  package_dir=$(console_value "$site_stack" 'var.package_dir')
  drop_override "$site_stack"

  [ -d "$site_stack/$package_dir" ] ||
    die "build the function package first: python tools/build_api.py --out build/api"

  terraform -chdir="$site_stack" init -input=false -no-color -reconfigure \
    -backend-config="bucket=$state_bucket" \
    -backend-config="key=$site_state_key" \
    -backend-config="region=$region" >/dev/null

  # The account table and the sign-in pool are protected against deletion, and
  # the site bucket is versioned, so the protection comes off and the bucket is
  # made emptiable first, by Terraform. The destroy runs with the same values
  # so that it does not try to put them back.
  site_vars=(
    -var-file="$PLATFORM_VARS"
    -var="assume_service_roles=${ASSUME_SERVICE_ROLES:-false}"
    -var="table_deletion_protection=false"
    -var="user_pool_deletion_protection=INACTIVE"
    -var="web_bucket_force_destroy=true"
  )

  if terraform -chdir="$site_stack" state list 2>/dev/null | grep -q .; then
    note "taking the deletion protection off the table and the pool"
    terraform -chdir="$site_stack" apply -input=false -no-color -auto-approve "${site_vars[@]}" \
      -target=module.account.aws_dynamodb_table.this \
      -target=module.account.aws_cognito_user_pool.this
  fi

  note "destroying the site stack"
  terraform -chdir="$site_stack" destroy -input=false -no-color -auto-approve "${site_vars[@]}"

  cat <<EOF

destroy: the site is gone. The state bucket and the pipeline's roles are not:
run this again with "bootstrap" to take those down.
EOF
  exit 0
fi

# ----------------------------------------------------------- the footing

# Its own state lives in the bucket it is about to delete, so the state comes
# back to a local file first.
note "bringing the bootstrap state back to a local file"
terraform -chdir="$bootstrap_stack" init -input=false -no-color -reconfigure \
  -backend-config="bucket=$state_bucket" \
  -backend-config="key=$bootstrap_state_key" \
  -backend-config="region=$region" >/dev/null

write_override "$bootstrap_stack"
terraform -chdir="$bootstrap_stack" init -input=false -no-color -force-copy -migrate-state >/dev/null

# The state bucket carries prevent_destroy, which takes no variable, so it
# leaves Terraform's hands before the destroy and is emptied and deleted
# afterwards. Everything else - the roles, their policies and the ceiling - is
# destroyed by Terraform. The GitHub sign-in provider is the seed's and is only
# read by this stack, so a destroy does not touch it.
while IFS= read -r address; do
  note "taking $address out of state"
  terraform -chdir="$bootstrap_stack" state rm "$address" >/dev/null
done < <(terraform -chdir="$bootstrap_stack" state list | grep -E '^aws_s3_bucket[a-z_]*\.state$' || true)

destroy_vars=(-var-file="$PLATFORM_VARS")
if [ -n "${GITHUB_SUBJECT_PREFIX:-}" ]; then
  destroy_vars+=(-var "github_subject_prefix=$GITHUB_SUBJECT_PREFIX")
fi

note "destroying the pipeline's roles"
terraform -chdir="$bootstrap_stack" destroy -input=false -no-color -auto-approve "${destroy_vars[@]}"

note "emptying and deleting $state_bucket"
empty_bucket "$state_bucket"
aws s3api delete-bucket --bucket "$state_bucket" --region "$region" >/dev/null

drop_override "$bootstrap_stack"
rm -f "$bootstrap_stack/terraform.tfstate" "$bootstrap_stack/terraform.tfstate.backup"

cat <<EOF

destroy: done. $state_bucket and the pipeline's roles are gone.

The seed is untouched: GitHub's sign-in to the account, the bootstrap role, and
the GitHub environments and their two repository variables. Run the Bootstrap
workflow to build it all again.
EOF
