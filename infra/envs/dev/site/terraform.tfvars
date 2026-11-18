# The customer site in dev: non-secret configuration, committed. The shared
# naming values are in ../platform.tfvars.

not_found_document = "/404.html"

cloudfront_price_class = "PriceClass_100"

# The site has no inline scripts or styles and loads nothing from elsewhere, so
# the policy allows its own origin only.
content_security_policy = {
  "default-src"     = ["'none'"]
  "script-src"      = ["'self'"]
  "style-src"       = ["'self'"]
  "img-src"         = ["'self'", "data:"]
  "font-src"        = ["'self'"]
  "connect-src"     = ["'self'"]
  "form-action"     = ["'self'"]
  "base-uri"        = ["'self'"]
  "frame-ancestors" = ["'none'"]
}

permissions_policy_denied = ["camera", "microphone", "geolocation", "payment", "usb"]

waf_managed_rule_groups = [
  {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1
  },
  {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2
  },
]
waf_rate_limit         = 2000
waf_rate_rule_priority = 10

# The short address on the main website. It is a redirect made there, by hand.
redirect_path = "/draft_cs_site"

# ------------------------------------------------------- the sign-up back end

# CloudFront sends this prefix to the API; the route keys below carry it too,
# so the path arrives unchanged and the API needs no stage or base path mapping.
api_path_pattern = "/api/*"

# The key policy holds no wildcard, so every action is listed. The root
# statement is what keeps the key administrable.
key_admin_actions = [
  "kms:CancelKeyDeletion",
  "kms:CreateAlias",
  "kms:DeleteAlias",
  "kms:DescribeKey",
  "kms:DisableKey",
  "kms:DisableKeyRotation",
  "kms:EnableKey",
  "kms:EnableKeyRotation",
  "kms:GetKeyPolicy",
  "kms:GetKeyRotationStatus",
  "kms:ListAliases",
  "kms:ListGrants",
  "kms:ListKeyPolicies",
  "kms:ListResourceTags",
  "kms:PutKeyPolicy",
  "kms:RevokeGrant",
  "kms:ScheduleKeyDeletion",
  "kms:TagResource",
  "kms:UntagResource",
  "kms:UpdateAlias",
  "kms:UpdateKeyDescription",
]

# DynamoDB asks for a grant when the table is created, then encrypts and
# decrypts items under it. Both are allowed only through DynamoDB.
key_dynamodb_actions = [
  "kms:CreateGrant",
  "kms:Decrypt",
  "kms:DescribeKey",
  "kms:Encrypt",
  "kms:GenerateDataKey",
  "kms:GenerateDataKeyWithoutPlaintext",
  "kms:ReEncryptFrom",
  "kms:ReEncryptTo",
]

key_logs_actions = [
  "kms:Decrypt",
  "kms:DescribeKey",
  "kms:Encrypt",
  "kms:GenerateDataKey",
  "kms:GenerateDataKeyWithoutPlaintext",
  "kms:ReEncryptFrom",
  "kms:ReEncryptTo",
]

# The table is the account record, so it is not deletable by accident.
table_deletion_protection = true

# Email is the user name. No phone number is asked for or held, so recovery is
# by verified email only.
username_attributes      = ["email"]
auto_verified_attributes = ["email"]

# A firm signs itself up; nobody creates the account for it.
allow_admin_create_user_only = false

password_minimum_length    = 12
password_require_uppercase = true
password_require_lowercase = true
password_require_numbers   = true
password_require_symbols   = true

# Off until the second factor is decided. A firm handling client money should
# have one; raising it is a change here and a change on the sign-in page.
mfa_configuration             = "OFF"
user_pool_deletion_protection = "ACTIVE"

# The browser signs in with an email and password and refreshes the session. No
# other flow is enabled.
client_auth_flows = [
  "ALLOW_USER_PASSWORD_AUTH",
  "ALLOW_REFRESH_TOKEN_AUTH",
]

token_validity = {
  id      = 60
  access  = 60
  refresh = 1
}
token_validity_units = {
  id      = "minutes"
  access  = "minutes"
  refresh = "days"
}

# One package, three handlers, three roles. The actions are the whole of each
# role: read cannot write, and write cannot read.
functions = {
  read = {
    handler       = "handler.read"
    routes        = ["GET /api/account"]
    table_actions = ["dynamodb:Query"]
    key_actions   = ["kms:Decrypt"]
  }
  write = {
    handler       = "handler.write"
    routes        = ["PUT /api/account/{section}"]
    table_actions = ["dynamodb:PutItem"]
    key_actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
  }
  accept = {
    handler       = "handler.accept"
    routes        = ["POST /api/account/agreement"]
    table_actions = ["dynamodb:PutItem"]
    key_actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
  }
}

# Built before plan, from this stack's directory. See runbooks/deploy.md.
package_dir = "../../../../build/api"

lambda_runtime         = "python3.12"
lambda_memory_mb       = 256
lambda_timeout_seconds = 10

# An operational window, not a retention period: the functions log no personal
# data.
log_retention_days = 30

# Terraform creates each log group, so a function may only write to it.
log_write_actions = [
  "logs:CreateLogStream",
  "logs:PutLogEvents",
]

# A sign-up is a handful of calls by one person. This is enough for a firm and
# small enough to be a ceiling.
api_throttling = {
  rate  = 20
  burst = 40
}

# What the access log holds. No request body, no Authorization header, no
# caller address and no user agent, so the log holds nothing personal.
api_access_log_fields = {
  requestId               = "$context.requestId"
  requestTime             = "$context.requestTime"
  httpMethod              = "$context.httpMethod"
  routeKey                = "$context.routeKey"
  status                  = "$context.status"
  protocol                = "$context.protocol"
  responseLength          = "$context.responseLength"
  responseLatency         = "$context.responseLatency"
  integrationStatus       = "$context.integration.status"
  integrationErrorMessage = "$context.integrationErrorMessage"
}

authorizer_identity_sources = ["$request.header.Authorization"]

# Above the function timeout, so a slow function times out as itself.
integration_timeout_ms = 15000
