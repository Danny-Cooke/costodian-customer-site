#!/usr/bin/env bash
#
# scripts/lib/stack.sh - sourced by seed.sh, names.sh, bootstrap.sh and
# destroy.sh. Never run on its own.
#
# Everything these scripts know about this project they read out of the
# Terraform configuration, so that no name, key, Region or ARN is written down
# twice. One expression holds all of it: local.script_names in the bootstrap
# stack. `terraform console` evaluates the configuration without reading a data
# source, so that expression carries no account id and no ARN, and needs no AWS
# credentials to read.
#
# The account id is the one thing a name cannot carry: it is either given to the
# script (AWS_ACCOUNT_ID) or asked of AWS when the script has credentials. The
# two composed values below - the state bucket's name and a role's ARN - are the
# only place in this repository where a name is put together outside Terraform.
#
# A caller sets SCRIPT_NAME, sets `set -euo pipefail`, and traps
# remove_overrides on EXIT.

# The repository this script lives in, so nothing depends on the caller's
# working directory.
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

# Relative to a stack directory, because that is how Terraform reads it.
PLATFORM_VARS="../platform.tfvars.json"

# Local-backend override files written so far, removed on exit.
OVERRIDES=()

die() {
  printf '%s: %s\n' "${SCRIPT_NAME:-stack}" "$*" >&2
  exit 1
}

# Progress goes to standard error: names.sh must put nothing but its key=value
# lines on standard output.
note() {
  printf '%s: %s\n' "${SCRIPT_NAME:-stack}" "$*" >&2
}

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH."
  done
}

env_dir() {
  local environment=$1
  local dir="$REPO_ROOT/infra/envs/$environment"
  [ -d "$dir" ] || die "no environment at infra/envs/$environment."
  printf '%s\n' "$dir"
}

stack_dir() {
  local environment=$1 stack=$2
  local dir
  dir="$(env_dir "$environment")/$stack"
  [ -d "$dir" ] || die "no $stack stack at infra/envs/$environment/$stack."
  printf '%s\n' "$dir"
}

# ------------------------------------------------------- reading the stack

# `terraform console` needs an initialised backend, and the state bucket may
# not exist yet or may be about to be deleted, so these scripts point the stack
# at a local backend first. The override file is git-ignored.
write_override() {
  local dir=$1
  local override="$dir/backend_override.tf"

  printf 'terraform {\n  backend "local" {}\n}\n' >"$override"
  OVERRIDES+=("$override")
}

init_local() {
  local dir=$1

  write_override "$dir"
  # -reconfigure: an earlier run leaves the folder pointed at the bucket.
  terraform -chdir="$dir" init -input=false -no-color -reconfigure >/dev/null
}

drop_override() {
  local dir=$1
  rm -f "$dir/backend_override.tf"
}

remove_overrides() {
  local override
  for override in ${OVERRIDES+"${OVERRIDES[@]}"}; do
    rm -f "$override"
  done
}

# One expression, evaluated against the configuration. Further arguments are
# passed to terraform console, which is how a -var reaches it.
console() {
  local dir=$1 expression=$2
  shift 2

  printf '%s\n' "$expression" |
    terraform -chdir="$dir" console -no-color -var-file="$PLATFORM_VARS" "$@"
}

# A single string value, without the quotes console puts round it.
console_value() {
  local dir=$1 expression=$2
  shift 2

  console "$dir" "$expression" "$@" | python3 -c 'import json, sys; print(json.loads(sys.stdin.read().strip()))'
}

# Reads local.script_names into SCRIPT_NAMES, as JSON. Further arguments reach
# terraform console.
read_script_names() {
  local dir=$1
  shift

  SCRIPT_NAMES=$(console_value "$dir" 'jsonencode(local.script_names)' "$@")
  [ -n "$SCRIPT_NAMES" ] || die "could not read the names out of $dir."
}

# One value out of SCRIPT_NAMES, by dotted key: `named role_names.deploy`.
named() {
  python3 -c '
import json
import sys

value = json.loads(sys.argv[1])
for part in sys.argv[2].split("."):
    value = value[part]
print(value)
' "$SCRIPT_NAMES" "$1"
}

# ------------------------------------------- the account id, and what it joins

# Given to the script. names.sh runs with no AWS credentials at all, so for it
# this is the only way.
account_from_environment() {
  [ -n "${AWS_ACCOUNT_ID:-}" ] || die "AWS_ACCOUNT_ID is not set. It is a repository variable, set by scripts/seed.sh; see runbooks/bootstrap.md."
  printf '%s\n' "$AWS_ACCOUNT_ID"
}

# Given to the script, or asked of AWS when it holds credentials.
account_id() {
  if [ -n "${AWS_ACCOUNT_ID:-}" ]; then
    printf '%s\n' "$AWS_ACCOUNT_ID"
    return
  fi
  aws sts get-caller-identity --query Account --output text 2>/dev/null ||
    die "no AWS credentials. In GitHub Actions the workflow signs in before running this; from a machine, export AWS_PROFILE."
}

# S3 bucket names are globally unique, so the composed name carries the account
# id. ACCOUNT_ID is set by the caller.
state_bucket_name() {
  printf '%s-%s\n' "$(named state_bucket_base)" "$ACCOUNT_ID"
}

role_arn() {
  printf 'arn:%s:iam::%s:role/%s\n' "$(named partition)" "$ACCOUNT_ID" "$(named "role_names.$1")"
}
