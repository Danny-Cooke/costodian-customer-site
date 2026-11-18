# Composes and validates every name in the stack from one template:
#
#   <prefix>-<project>-<env>-<component>-<key>-<type>-<postfix>
#
# `prefix` and `postfix` are reserved and currently empty, so they drop out of
# the join and the template does not have to change when they are decided.
# Globally unique names (S3) take the account suffix after `postfix`; that is an
# extension for S3's global namespace only, not a further slot.
#
# `key` is the logical key of the resource within its component - the token
# that tells two resources of one kind apart. Without it
# two roles in one component would compose to the same name. It is dropped when
# it would only repeat the component or the type, and the type code is dropped
# when the key already ends with it or the component already is it, so the
# common cases stay short:
#
#   { waf = "web_acl" }    in component web   -> <project>-<env>-web-waf
#   { apply = "role" }     in component ci    -> <project>-<env>-ci-apply-role
#   { state = "bucket" }   in component ci    -> <project>-<env>-ci-state-bkt
#
# Bad names fail `plan` here, not `apply`: the preconditions below check the
# type vocabulary, the 64-character IAM and Lambda ceiling and S3's lowercase
# 3-63 character rule.

locals {
  # The type vocabulary. The short code for every kind of resource we create,
  # declared once. A kind that is not in here fails the plan.
  type_codes = {
    authorizer              = "authz"
    bucket                  = "bkt"
    cloudformation_stack    = "stack"
    distribution            = "cdn"
    dynamodb_table          = "tbl"
    function                = "fn"
    http_api                = "api"
    kms_alias               = "alias"
    kms_key                 = "key"
    log_group               = "log"
    openid_connect_provider = "oidc"
    origin_access_control   = "oac"
    policy                  = "pol"
    response_headers_policy = "rhp"
    role                    = "role"
    user_pool               = "pool"
    user_pool_client        = "client"
    web_acl                 = "waf"
  }

  name_pattern   = "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"
  unknown_kinds  = [for key, kind in var.types : kind if !contains(keys(local.type_codes), kind)]
  unknown_unique = [for key in var.globally_unique : key if !contains(keys(var.types), key)]

  base = join("-", compact([
    var.platform.prefix,
    var.platform.project,
    var.platform.environment,
    var.component,
  ]))

  codes = { for key, kind in var.types : key => lookup(local.type_codes, kind, "unknown") }

  names = {
    for key, kind in var.types :
    key => join("-", compact([
      local.base,
      contains([var.component, kind, local.codes[key]], key) ? "" : key,
      local.codes[key] == var.component || endswith(key, "-${local.codes[key]}") ? "" : local.codes[key],
      var.platform.postfix,
    ]))
  }

  s3_names = {
    for key in var.globally_unique :
    key => lower(join("-", compact([
      local.names[key],
      var.platform.unique_suffix,
    ])))
  }

  too_long     = [for key, name in local.names : name if length(name) > var.max_name_length]
  malformed    = [for key, name in local.names : name if length(regexall(local.name_pattern, name)) == 0]
  bucket_long  = [for key, name in local.s3_names : name if length(name) > var.max_bucket_name_length]
  bucket_short = [for key, name in local.s3_names : name if length(name) < var.min_bucket_name_length]
  bucket_bad   = [for key, name in local.s3_names : name if length(regexall(local.name_pattern, name)) == 0]
}

# Validation lives on a resource so that it is evaluated and fails at plan time.
resource "terraform_data" "validated" {
  input = {
    names    = local.names
    s3_names = local.s3_names
  }

  lifecycle {
    precondition {
      condition     = length(local.unknown_kinds) == 0
      error_message = "naming: unknown resource kinds ${jsonencode(local.unknown_kinds)}; add the kind to the type vocabulary in modules/naming/main.tf."
    }
    precondition {
      condition     = length(local.unknown_unique) == 0
      error_message = "naming: globally_unique names ${jsonencode(local.unknown_unique)} that are not keys of var.types."
    }
    precondition {
      condition     = length(local.too_long) == 0
      error_message = "naming: names over ${var.max_name_length} characters ${jsonencode(local.too_long)}; shorten the project, environment or component slot."
    }
    precondition {
      condition     = length(local.malformed) == 0
      error_message = "naming: names that are not lowercase alphanumeric with inner hyphens ${jsonencode(local.malformed)}."
    }
    precondition {
      condition     = length(local.bucket_long) == 0
      error_message = "naming: bucket names over ${var.max_bucket_name_length} characters ${jsonencode(local.bucket_long)}."
    }
    precondition {
      condition     = length(local.bucket_short) == 0
      error_message = "naming: bucket names under ${var.min_bucket_name_length} characters ${jsonencode(local.bucket_short)}."
    }
    precondition {
      condition     = length(local.bucket_bad) == 0
      error_message = "naming: bucket names that break S3's lowercase rule ${jsonencode(local.bucket_bad)}."
    }
  }
}
