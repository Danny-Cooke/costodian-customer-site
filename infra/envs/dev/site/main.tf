# The customer site, one environment, one account.

module "web" {
  source = "../../../modules/web"

  providers = {
    aws.storage = aws.storage
    aws.cdn     = aws.cdn
    aws.edge    = aws.edge
  }

  platform  = local.platform
  component = var.components.web

  index_document          = var.index_document
  not_found_document      = var.not_found_document
  not_found_error_codes   = var.not_found_error_codes
  not_found_response_code = var.not_found_response_code
  price_class             = var.cloudfront_price_class
  cache_policy_name       = var.cloudfront_cache_policy_name
  allowed_methods         = var.cloudfront_allowed_methods
  cached_methods          = var.cloudfront_cached_methods
  content_security_policy = local.content_security_policy
  permissions_policy      = local.permissions_policy
  waf_managed_rule_groups = var.waf_managed_rule_groups
  waf_rate_limit          = var.waf_rate_limit
  waf_rate_rule_priority  = var.waf_rate_rule_priority

  # The API is served on the site's own origin, so the browser needs no CORS
  # and the token never crosses an origin.
  api_origin = {
    domain_name  = module.account.api_domain_name
    path_pattern = var.api_path_pattern
  }
}

module "account" {
  source = "../../../modules/account"

  providers = {
    aws.keys     = aws.keys
    aws.data     = aws.data
    aws.identity = aws.identity
    aws.compute  = aws.compute
    aws.access   = aws.access
  }

  platform  = local.platform
  component = var.components.account

  # The invitation email tells a new member where to sign in, which is the
  # site's own address. The pool therefore waits on the distribution, which
  # waits on the API's address above; the pool is not an input to the API, so
  # the three order themselves and there is no cycle.
  product_name = var.product_name
  site_url     = module.web.site_url

  function_permissions_boundary_arn = local.function_permissions_boundary_arn

  key_admin_actions    = var.key_admin_actions
  key_dynamodb_actions = var.key_dynamodb_actions
  key_logs_actions     = var.key_logs_actions

  table_deletion_protection = var.table_deletion_protection

  username_attributes           = var.username_attributes
  auto_verified_attributes      = var.auto_verified_attributes
  allow_admin_create_user_only  = var.allow_admin_create_user_only
  password_minimum_length       = var.password_minimum_length
  password_require_uppercase    = var.password_require_uppercase
  password_require_lowercase    = var.password_require_lowercase
  password_require_numbers      = var.password_require_numbers
  password_require_symbols      = var.password_require_symbols
  mfa_configuration             = var.mfa_configuration
  user_pool_deletion_protection = var.user_pool_deletion_protection
  client_auth_flows             = var.client_auth_flows
  token_validity                = var.token_validity
  token_validity_units          = var.token_validity_units

  temporary_password_validity_days = var.temporary_password_validity_days
  invite_message_template          = var.invite_message_template
  verification_message_template    = var.verification_message_template
  required_message_placeholders    = var.required_message_placeholders

  functions              = var.functions
  package_dir            = var.package_dir
  lambda_runtime         = var.lambda_runtime
  lambda_memory_mb       = var.lambda_memory_mb
  lambda_timeout_seconds = var.lambda_timeout_seconds
  log_retention_days     = var.log_retention_days
  log_write_actions      = var.log_write_actions

  api_throttling              = var.api_throttling
  api_access_log_fields       = var.api_access_log_fields
  authorizer_identity_sources = var.authorizer_identity_sources
  integration_timeout_ms      = var.integration_timeout_ms
}

locals {
  # Each directive is a map entry in tfvars; the header is composed here.
  content_security_policy = join("; ", [
    for directive, sources in local.csp_directives : "${directive} ${join(" ", sources)}"
  ])

  # The browser signs in against Cognito directly, so that one origin is added
  # to connect-src. It is composed from the Region, not written in tfvars.
  cognito_origin = format(var.cognito_endpoint_template, var.platform.region)

  csp_directives = merge(var.content_security_policy, {
    (var.csp_connect_directive) = concat(
      lookup(var.content_security_policy, var.csp_connect_directive, []),
      [local.cognito_origin],
    )
  })

  permissions_policy = join(", ", [for feature in var.permissions_policy_denied : "${feature}=()"])
}
