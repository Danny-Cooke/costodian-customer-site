# The sign-up back end: a Cognito pool the firm signs itself up in and invites
# its members to, one DynamoDB table holding the account record, and one small
# function per job behind an HTTP API that only accepts a Cognito token.
# Everything is encrypted with one customer-managed key, and every function has
# its own role, built from the exact table, key and pool actions that function
# needs: the read function cannot write, and only the function that manages the
# firm's members may touch the pool.
#
# There is no bucket, queue or function here that could hold an identity
# document. The API is reached through the site's CloudFront distribution, so it
# is same-origin to the browser and needs no CORS.
#
# Every resource names the provider it is created with, so each one is created
# by the role for its own service and nothing silently inherits a broader
# identity:
#
#   aws.keys      the KMS key and its alias
#   aws.data      the DynamoDB table
#   aws.identity  the Cognito pool and client
#   aws.compute   the functions, the HTTP API and the log groups
#   aws.access    the functions' own roles and inline policies
#
# aws.access is the only identity that may write IAM, and it may only write
# roles under this component's name prefix, each of which must carry the
# permissions boundary passed in as var.function_permissions_boundary_arn.

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.keys, aws.data, aws.identity, aws.compute, aws.access]
    }
    archive = {
      source = "hashicorp/archive"
    }
  }
}

module "naming" {
  source = "../naming"

  platform  = var.platform
  component = var.component
  types = merge(
    {
      # The component's one table, so its logical key is the component itself.
      (var.component) = "dynamodb_table"
      key             = "kms_key"
      alias           = "kms_alias"
      pool            = "user_pool"
      client          = "user_pool_client"
      api             = "http_api"
      authz           = "authorizer"
      api-log         = "log_group"
    },
    # One function, one role, one inline policy and one log group per entry.
    { for name in keys(var.functions) : name => "function" },
    { for name in keys(var.functions) : "${name}-role" => "role" },
    { for name in keys(var.functions) : "${name}-access" => "policy" },
    { for name in keys(var.functions) : "${name}-log" => "log_group" },
  )
}

locals {
  tags = { Component = var.component }

  # Every log group this module creates shares the component's name prefix, so
  # one condition scopes the key to them.
  log_group_arn_prefix = "arn:${var.platform.partition}:logs:${var.platform.region}:${var.platform.account_id}:log-group:${module.naming.base}-"

  # One route is one (function, route key) pair. Route keys are unique across
  # functions, so the route key is the map key.
  routes = merge([
    for name, fn in var.functions : {
      for route in fn.routes : route => {
        function = name
        method   = split(" ", route)[0]
        path     = split(" ", route)[1]
        # A statement id takes letters, digits, hyphens and underscores only.
        statement_id = trim(replace(route, "/[^0-9A-Za-z]+/", "-"), "-")
      }
    }
  ]...)

  # What each placeholder in the message templates stands for. The key is the
  # placeholder's name and the token text is composed from it with
  # var.placeholder_format, so the token is written in tfvars and nowhere else.
  placeholders = {
    product  = var.product_name
    site_url = var.site_url
    days     = tostring(var.temporary_password_validity_days)
  }

  message_templates = {
    invite       = var.invite_message_template
    verification = var.verification_message_template
  }

  # Terraform has no fold over a map, so the substitutions are chained: one
  # pass per key of local.placeholders. Adding a placeholder is a key above and
  # a pass here. Cognito's own {username} and {####} match nothing and survive.
  messages = {
    for key, template in local.message_templates : key => {
      for field, text in template : field => replace(replace(replace(
        text,
        format(var.placeholder_format, "product"), local.placeholders["product"]),
        format(var.placeholder_format, "site_url"), local.placeholders["site_url"]),
      format(var.placeholder_format, "days"), local.placeholders["days"])
    }
  }

  missing_placeholders = flatten([
    for key, required in var.required_message_placeholders : [
      for token in required : "${key}.${token}"
      if !strcontains(local.messages[key].message, token)
    ]
  ])
}

# Validation on a resource so that it is evaluated and fails at plan time: a
# message missing a placeholder Cognito requires is refused at apply.
resource "terraform_data" "messages" {
  input = local.messages

  lifecycle {
    precondition {
      condition     = length(local.missing_placeholders) == 0
      error_message = "account: message templates are missing placeholders Cognito requires ${jsonencode(local.missing_placeholders)}."
    }
  }
}

# ------------------------------------------------------------------- the key

data "aws_iam_policy_document" "key" {
  provider = aws.keys

  # A key policy's resource is always "*", meaning the key the policy is
  # attached to. It cannot name the key, which does not exist yet.
  statement {
    sid       = "AdministeredByThisAccount"
    effect    = "Allow"
    actions   = var.key_admin_actions
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${var.platform.partition}:iam::${var.platform.account_id}:root"]
    }
  }

  # Not "anyone": the two conditions together mean a principal of this account,
  # and only when DynamoDB is making the call on its behalf.
  statement {
    sid       = "UsedThroughDynamoDbByThisAccount"
    effect    = "Allow"
    actions   = var.key_dynamodb_actions
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [format(var.dynamodb_via_service, var.platform.region)]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [var.platform.account_id]
    }
  }

  statement {
    sid       = "UsedByCloudWatchLogsForThisComponentsGroups"
    effect    = "Allow"
    actions   = var.key_logs_actions
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = [format(var.logs_service_principal, var.platform.region)]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["${local.log_group_arn_prefix}*"]
    }
  }
}

resource "aws_kms_key" "this" {
  provider = aws.keys

  description             = "Sign-up data and logs for ${module.naming.base}"
  enable_key_rotation     = var.key_rotation_enabled
  deletion_window_in_days = var.key_deletion_window_days
  policy                  = data.aws_iam_policy_document.key.json

  tags = merge(local.tags, { Name = module.naming.names["key"] })
}

resource "aws_kms_alias" "this" {
  provider = aws.keys

  name          = "${var.key_alias_prefix}${module.naming.names["alias"]}"
  target_key_id = aws_kms_key.this.key_id
}

# ----------------------------------------------------------------- the table

resource "aws_dynamodb_table" "this" {
  provider = aws.data

  name         = module.naming.names[var.component]
  billing_mode = var.table_billing_mode
  hash_key     = var.table_hash_key
  range_key    = var.table_range_key

  deletion_protection_enabled = var.table_deletion_protection

  attribute {
    name = var.table_hash_key
    type = var.table_key_type
  }

  attribute {
    name = var.table_range_key
    type = var.table_key_type
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.this.arn
  }

  point_in_time_recovery {
    enabled = var.table_point_in_time_recovery
  }

  tags = merge(local.tags, { Name = module.naming.names[var.component] })
}

# ---------------------------------------------------------------- the sign-in

resource "aws_cognito_user_pool" "this" {
  provider = aws.identity

  name                     = module.naming.names["pool"]
  username_attributes      = var.username_attributes
  auto_verified_attributes = var.auto_verified_attributes
  mfa_configuration        = var.mfa_configuration
  deletion_protection      = var.user_pool_deletion_protection

  username_configuration {
    case_sensitive = var.username_case_sensitive
  }

  # Self sign-up stays open: a firm signs itself up, and an owner invites the
  # rest of the firm. The invitation is the email an invited member receives.
  admin_create_user_config {
    allow_admin_create_user_only = var.allow_admin_create_user_only

    invite_message_template {
      email_subject = local.messages["invite"]["subject"]
      email_message = local.messages["invite"]["message"]
      sms_message   = local.messages["invite"]["sms"]
    }
  }

  # The code a person who signs the firm up themselves confirms the address
  # with.
  verification_message_template {
    default_email_option = var.verification_default_email_option
    email_subject        = local.messages["verification"]["subject"]
    email_message        = local.messages["verification"]["message"]
  }

  password_policy {
    minimum_length                   = var.password_minimum_length
    require_uppercase                = var.password_require_uppercase
    require_lowercase                = var.password_require_lowercase
    require_numbers                  = var.password_require_numbers
    require_symbols                  = var.password_require_symbols
    temporary_password_validity_days = var.temporary_password_validity_days
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = var.account_recovery_mechanism
      priority = var.account_recovery_priority
    }
  }

  # Cognito's own sender, with its low daily limit. Moving to SES is a change
  # of email_sending_account and a verified identity.
  email_configuration {
    email_sending_account = var.email_sending_account
  }

  tags = merge(local.tags, { Name = module.naming.names["pool"] })
}

resource "aws_cognito_user_pool_client" "this" {
  provider = aws.identity

  name         = module.naming.names["client"]
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret               = var.client_generate_secret
  explicit_auth_flows           = var.client_auth_flows
  prevent_user_existence_errors = var.prevent_user_existence_errors
  enable_token_revocation       = var.enable_token_revocation

  id_token_validity      = var.token_validity.id
  access_token_validity  = var.token_validity.access
  refresh_token_validity = var.token_validity.refresh

  token_validity_units {
    id_token      = var.token_validity_units.id
    access_token  = var.token_validity_units.access
    refresh_token = var.token_validity_units.refresh
  }
}

# ------------------------------------------------------------- the functions

# One package, built outside Terraform, shared by every function. They differ
# only by handler, so there is one artefact to build and one to promote.
data "archive_file" "package" {
  type        = "zip"
  source_dir  = var.package_dir
  output_path = "${var.package_dir}.zip"
}

resource "aws_cloudwatch_log_group" "function" {
  provider = aws.compute

  for_each = var.functions

  name              = module.naming.names["${each.key}-log"]
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.this.arn

  tags = merge(local.tags, { Name = module.naming.names["${each.key}-log"] })
}

data "aws_iam_policy_document" "assume" {
  provider = aws.access

  statement {
    sid     = "AssumedByLambdaOnly"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = [var.lambda_service_principal]
    }
  }
}

resource "aws_iam_role" "function" {
  provider = aws.access

  for_each = var.functions

  name               = module.naming.names["${each.key}-role"]
  description        = "Execution role for the ${each.key} function of ${module.naming.base}"
  assume_role_policy = data.aws_iam_policy_document.assume.json

  # The ceiling on what this role can ever hold, whatever is attached to it
  # later. The role that creates these roles cannot create one without it.
  permissions_boundary = var.function_permissions_boundary_arn

  tags = merge(local.tags, { Name = module.naming.names["${each.key}-role"] })
}

# The whole of least privilege for this component: each function's role carries
# its own log group, its own table actions and its own key actions, and nothing
# else. A function needing another's actions is two functions.
data "aws_iam_policy_document" "function" {
  provider = aws.access

  for_each = var.functions

  statement {
    sid       = "WriteItsOwnLog"
    effect    = "Allow"
    actions   = var.log_write_actions
    resources = ["${aws_cloudwatch_log_group.function[each.key].arn}:*"]
  }

  statement {
    sid       = "UseTheAccountTable"
    effect    = "Allow"
    actions   = each.value.table_actions
    resources = [aws_dynamodb_table.this.arn]
  }

  # The table's encryption is done by DynamoDB under its own grant, so these
  # are what the function would need if it ever called KMS itself. The key
  # policy allows the key's use through DynamoDB only, so this grant is the
  # narrower of the two and the function cannot decrypt anything out of band.
  statement {
    sid       = "UseTheAccountKey"
    effect    = "Allow"
    actions   = each.value.key_actions
    resources = [aws_kms_key.this.arn]
  }

  # Only a function that manages the firm's members gets this, and only on this
  # one pool. The statement is left out entirely when the list is empty, so no
  # other function's role mentions Cognito at all.
  dynamic "statement" {
    for_each = length(each.value.pool_actions) > 0 ? [each.value.pool_actions] : []

    content {
      sid       = "AdministerPeopleInThisPoolOnly"
      effect    = "Allow"
      actions   = statement.value
      resources = [aws_cognito_user_pool.this.arn]
    }
  }
}

resource "aws_iam_role_policy" "function" {
  provider = aws.access

  for_each = var.functions

  name   = module.naming.names["${each.key}-access"]
  role   = aws_iam_role.function[each.key].id
  policy = data.aws_iam_policy_document.function[each.key].json
}

resource "aws_lambda_function" "this" {
  provider = aws.compute

  for_each = var.functions

  function_name    = module.naming.names[each.key]
  description      = "${each.key} of the sign-up account record"
  role             = aws_iam_role.function[each.key].arn
  handler          = each.value.handler
  runtime          = var.lambda_runtime
  architectures    = var.lambda_architectures
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout_seconds
  filename         = data.archive_file.package.output_path
  source_code_hash = data.archive_file.package.output_base64sha256

  logging_config {
    log_format = var.lambda_log_format
    log_group  = aws_cloudwatch_log_group.function[each.key].name
  }

  # The table's name and key attribute names, so the code holds no literal
  # either. Nothing here is a secret. The pool's id is given only to a function
  # whose role may act on the pool, so a function that is not allowed to cannot
  # even name it.
  environment {
    variables = merge(
      {
        TABLE_NAME      = aws_dynamodb_table.this.name
        TABLE_HASH_KEY  = var.table_hash_key
        TABLE_RANGE_KEY = var.table_range_key
      },
      length(each.value.pool_actions) > 0 ? { USER_POOL_ID = aws_cognito_user_pool.this.id } : {},
    )
  }

  tags = merge(local.tags, { Name = module.naming.names[each.key] })

  depends_on = [aws_iam_role_policy.function]
}

# ------------------------------------------------------------------- the API

resource "aws_apigatewayv2_api" "this" {
  provider = aws.compute

  name          = module.naming.names["api"]
  description   = "Sign-up API for ${module.naming.base}"
  protocol_type = var.api_protocol_type

  tags = merge(local.tags, { Name = module.naming.names["api"] })
}

resource "aws_cloudwatch_log_group" "api" {
  provider = aws.compute

  name              = module.naming.names["api-log"]
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.this.arn

  tags = merge(local.tags, { Name = module.naming.names["api-log"] })
}

resource "aws_apigatewayv2_stage" "default" {
  provider = aws.compute

  api_id      = aws_apigatewayv2_api.this.id
  name        = var.api_stage_name
  auto_deploy = var.api_auto_deploy

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format          = jsonencode(var.api_access_log_fields)
  }

  default_route_settings {
    throttling_rate_limit    = var.api_throttling.rate
    throttling_burst_limit   = var.api_throttling.burst
    detailed_metrics_enabled = var.api_detailed_metrics_enabled
  }

  tags = merge(local.tags, { Name = module.naming.names["api"] })
}

# Every route carries this, so no function is ever reached without a valid
# token from this pool and this client.
resource "aws_apigatewayv2_authorizer" "jwt" {
  provider = aws.compute

  api_id           = aws_apigatewayv2_api.this.id
  name             = module.naming.names["authz"]
  authorizer_type  = var.authorizer_type
  identity_sources = var.authorizer_identity_sources

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.this.id]
    issuer   = "https://${aws_cognito_user_pool.this.endpoint}"
  }
}

resource "aws_apigatewayv2_integration" "this" {
  provider = aws.compute

  for_each = local.routes

  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = var.integration_type
  integration_method     = var.integration_method
  integration_uri        = aws_lambda_function.this[each.value.function].invoke_arn
  payload_format_version = var.payload_format_version
  timeout_milliseconds   = var.integration_timeout_ms
}

resource "aws_apigatewayv2_route" "this" {
  provider = aws.compute

  for_each = local.routes

  api_id             = aws_apigatewayv2_api.this.id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.this[each.key].id}"
  authorization_type = var.route_authorization_type
  authorizer_id      = aws_apigatewayv2_authorizer.jwt.id
}

# One permission per route, naming that route's method and path, rather than
# one permission that lets the API call the function for anything.
resource "aws_lambda_permission" "api" {
  provider = aws.compute

  for_each = local.routes

  statement_id  = each.value.statement_id
  action        = var.lambda_invoke_action
  function_name = aws_lambda_function.this[each.value.function].function_name
  principal     = var.apigateway_service_principal
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/${var.api_stage_name}/${each.value.method}${each.value.path}"
}
