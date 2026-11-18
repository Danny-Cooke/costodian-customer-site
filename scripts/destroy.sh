#!/usr/bin/env bash
#
# scripts/destroy.sh <environment>
#
# The documented reverse of scripts/bootstrap.sh: takes the site down, then the
# pipeline's footing. Run by a person with an administrator profile exported,
# because the roles it is destroying are the ones the pipeline would use.
#
#   export AWS_PROFILE=<an administrator profile>
#   scripts/destroy.sh dev
#
# It destroys customer-facing infrastructure, including the account table and
# the sign-in pool, so it asks for the project's name to be typed before it
# does anything. Nothing about it is automatic and no workflow calls it.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: scripts/destroy.sh <environment>

  <environment>  the environment token, e.g. dev.

Destroys the site stack and then the bootstrap stack. Asks for the project
name to be typed first.
EOF
  exit 2
}

[ "$#" -eq 1 ] || usage
environment=$1

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
env_dir="$repo_root/infra/envs/$environment"
bootstrap_dir="$env_dir/bootstrap"
site_dir="$env_dir/site"
platform_vars="../platform.tfvars.json"
override_file="$bootstrap_dir/backend_override.tf"

for tool in terraform aws jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "destroy: $tool is not on PATH." >&2
    exit 1
  }
done

if [ ! -d "$bootstrap_dir" ] || [ ! -d "$site_dir" ]; then
  echo "destroy: no environment at $env_dir." >&2
  exit 1
fi

[ -n "${AWS_PROFILE:-}" ] || {
  echo "destroy: export AWS_PROFILE with an administrator profile for the account first." >&2
  exit 1
}

tf_bootstrap() {
  terraform -chdir="$bootstrap_dir" "$@"
}

tf_site() {
  terraform -chdir="$site_dir" "$@"
}

tf_console() {
  printf '%s\n' "$2" | terraform -chdir="$1" console -no-color -var-file="$platform_vars" | tr -d '"'
}

# A versioned bucket cannot be deleted until every version and delete marker
# is gone, and Terraform will not empty one it did not fill.
empty_bucket() {
  local bucket=$1 payload count
  aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1 || return 0

  while :; do
    payload=$(aws s3api list-object-versions --bucket "$bucket" --max-keys 500 --output json |
      jq -c '{Objects: [(.Versions // []), (.DeleteMarkers // [])] | add | map({Key, VersionId})}')
    count=$(jq '.Objects | length' <<<"$payload")
    if [ "$count" -eq 0 ]; then
      break
    fi
    aws s3api delete-objects --bucket "$bucket" --delete "$payload" >/dev/null
    echo "destroy:   removed $count versions from $bucket"
  done
}

# ------------------------------------------------------------------- confirm

project=$(tf_console "$bootstrap_dir" 'local.project')
state_bucket=$(tf_console "$bootstrap_dir" 'local.state_bucket_name')
region=$(tf_console "$bootstrap_dir" 'var.platform.region')
bootstrap_state_key=$(tf_console "$bootstrap_dir" 'var.bootstrap_state_key')
site_state_key=$(tf_console "$bootstrap_dir" 'var.site_state_key')

cat <<EOF
destroy: about to destroy $project in $environment ($region).

This removes the site, the sign-up API, the Cognito pool, the account table and
its key, then the pipeline's roles and the state bucket. It cannot be undone.

EOF
printf 'Type the project name (%s) to go on: ' "$project"
read -r typed
[ "$typed" = "$project" ] || {
  echo "destroy: not confirmed; nothing done." >&2
  exit 1
}

# ---------------------------------------------------------------- the site

echo "destroy: the site stack"
tf_site init -input=false -no-color -reconfigure \
  -backend-config="bucket=$state_bucket" \
  -backend-config="key=$site_state_key" \
  -backend-config="region=$region" >/dev/null

# Terraform reads the function package while planning the destroy, so it has to
# be there.
package_dir=$(tf_console "$site_dir" 'var.package_dir')
if [ ! -d "$site_dir/$package_dir" ]; then
  echo "destroy: build the function package first: python tools/build_api.py --out build/api" >&2
  exit 1
fi

web_bucket=$(tf_site output -raw bucket_name 2>/dev/null || true)
if [ -n "$web_bucket" ]; then
  empty_bucket "$web_bucket"
fi

# assume_service_roles stays false: this runs as an administrator, not as the
# pipeline, and the service roles are about to stop existing.
tf_site destroy -input=false -no-color -auto-approve \
  -var-file="$platform_vars" -var="assume_service_roles=false"

# ----------------------------------------------------------- the footing

echo "destroy: the bootstrap stack"

# Its state lives in the bucket it is about to delete, so bring the state back
# to a local file first.
printf 'terraform {\n  backend "local" {}\n}\n' >"$override_file"
tf_bootstrap init -input=false -no-color -force-copy -migrate-state >/dev/null

# The state bucket carries prevent_destroy, so it leaves Terraform's hands
# before the destroy and is deleted directly afterwards.
while IFS= read -r address; do
  tf_bootstrap state rm "$address" >/dev/null
done < <(tf_bootstrap state list | grep -E '^aws_s3_bucket[a-z_]*\.state$' || true)

tf_bootstrap destroy -input=false -no-color -auto-approve -var-file="$platform_vars"

empty_bucket "$state_bucket"
aws s3api delete-bucket --bucket "$state_bucket" --region "$region" >/dev/null 2>&1 || true

rm -f "$override_file" "$bootstrap_dir/terraform.tfstate" "$bootstrap_dir/terraform.tfstate.backup"

cat <<EOF

destroy: done. $state_bucket and $bootstrap_state_key are gone.

The GitHub environments and their variables are left alone: they hold no
secret, and the next scripts/bootstrap.sh $environment overwrites them.
EOF
