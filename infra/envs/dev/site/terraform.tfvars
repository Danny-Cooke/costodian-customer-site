# The customer site in dev: non-secret configuration, committed. The shared
# naming values are in ../platform.tfvars.

not_found_document = "/404.html"

cloudfront_price_class = "PriceClass_100"

# The site's name and its hosted zone are in ../platform.tfvars.json. www is
# served only to be sent on to the bare name, and so is the address CloudFront
# gave the site before it had one.
site_alternate_hosts          = ["www"]
site_minimum_protocol_version = "TLSv1.2_2021"

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

# The one table every firm shared before each had its own. It holds the firms
# that signed up before then, so it is not deletable by accident.
table_deletion_protection = true

# ------------------------------------------------------- the customer pool
#
# One table, one key and one label parameter per customer number, made in
# advance so that signing up creates nothing. The pool is the numbers 1 to
# (highest claimed + customer_spares), so each pipeline run tops it back up.
# Four digits is ten thousand customers; widening it would rename, and so
# replace, every table.
customer_number_digits = 4
customer_spares        = 10

# A label whose status is this word is free to take. Anything else, including a
# label that cannot be read, counts as taken.
customer_free_status = "free"

# The two field names in a label. The API writes the same two.
customer_parameter_fields = {
  number = "customer"
  status = "status"
}

# Listing the pool is a call on the path; everything else is a call on one
# label under it.
customer_parameter_path_actions = ["ssm:GetParametersByPath"]

# A customer's table holds that firm's own account record.
customer_table_deletion_protection = true

# The two lists that take a customer out of service, in that order, one apply
# each. Empty: no customer has been removed.
unprotected_customer_numbers = []
removed_customer_numbers     = []

# What the customer data role may do: every item action any function needs, on
# every customer's table. Deliberately broad - the session policy a function
# passes when it assumes the role is what narrows a request to one customer's
# table, and a function's own data_actions below are what it asks for.
customer_data_table_actions = [
  "dynamodb:DeleteItem",
  "dynamodb:GetItem",
  "dynamodb:PutItem",
  "dynamodb:Query",
]

# Only through DynamoDB, and only on a key aliased as a customer key.
customer_data_key_actions = [
  "kms:Decrypt",
  "kms:GenerateDataKey",
]

# What the function that issues customer UIDs may do with the key the registry
# table is encrypted with. It reads and writes entries, so it does both.
registry_key_actions = ["kms:Decrypt", "kms:GenerateDataKey"]

# ---------------------------------------------------- the version catalogue
#
# One parameter holding a JSON list. The versions it starts with are in
# ../platform.tfvars.json, because the site build reads them from there too;
# how it grows is here.

# What counts as a version: v1.0 or v1.0.0, and nothing else. Both the function
# that appends to the catalogue and the ones that read it are given it.
version_tag_pattern = "^v[0-9]+\\.[0-9]+(\\.[0-9]+)?$"

# The repository whose tags are the product's versions, in this account and
# Region. The rule names it by ARN, so no other repository's tags match.
version_source_repository = "aft-global-customizations"

# A tag created or moved in that repository, and nothing else: not a branch,
# not a commit.
version_source_event = {
  source          = "aws.codecommit"
  detail_type     = "CodeCommit Repository State Change"
  events          = ["referenceCreated", "referenceUpdated"]
  reference_types = ["tag"]
}

# The function the rule invokes. It answers no route: the rule is its only
# caller.
version_catalogue_function = "catalogue"

# Which customer a person belongs to, carried in their token as
# custom:customer. Only the API may set it.
customer_attribute_name       = "customer"
customer_attribute_min_length = 1

# Stated rather than left to default to every attribute. The browser reads the
# customer number and cannot write it: a person who could write their own would
# be able to point themselves at another firm's table. The account module adds
# the custom attribute to the read list from customer_attribute_name, so the
# claim name is not written twice.
client_read_attributes  = ["email", "email_verified", "name"]
client_write_attributes = ["email", "name"]

# Email is the user name. No phone number is asked for or held, so recovery is
# by verified email only.
username_attributes      = ["email"]
auto_verified_attributes = ["email"]

# A firm signs itself up; nobody creates the account for it. It stays false now
# that an owner can invite the rest of the firm: closing it would also close
# self sign-up.
allow_admin_create_user_only = false

password_minimum_length    = 12
password_require_uppercase = true
password_require_lowercase = true
password_require_numbers   = true
password_require_symbols   = true

# How long an invited member has to use the temporary password. The invitation
# email states this same number.
temporary_password_validity_days = 7

# The two emails the pool sends. {product}, {site_url} and {days} are put in by
# the account module; {username} and {####} are Cognito's own and are required
# in these messages, so they are left as they are written here.
# No invitation is sent by text message: no phone number is held. The sign-in
# service still requires the wording to exist.
invite_message_template = {
  sms     = "{product}: sign in as {username} with the temporary password {####}"
  subject = "You have been invited to {product}"
  message = "You have been invited to help manage your firm's {product} account.<br><br>Sign in at {site_url}/signin/ with:<br><br>Email address: {username}<br>Temporary password: {####}<br><br>You will be asked to choose your own password the first time you sign in. The temporary password stops working after {days} days."
}

# The email that carries a code says which site it is for, why it was sent and
# where it goes. It is short on purpose.
verification_message_template = {
  subject = "Your {product} customer site code"
  message = "Here is your code for the {product} customer site: <b>{####}</b><br><br>It was emailed to you because you are creating your account, resetting your password or confirming your email address. Type it into the box that asks for the code."
}

# What Cognito refuses a message without. Checked at plan.
required_message_placeholders = {
  invite       = ["{username}", "{####}"]
  verification = ["{####}"]
}

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

# One package, one handler and one role per job. The four action lists are the
# whole of each role, and an empty list is a statement that is never written:
# read cannot write, only enrol can list the pool of numbers or touch the old
# shared table, and only enrol and people may act on the sign-in pool.
#
# data_actions are the exception: no role here can reach a customer's table at
# all. They are what the function puts in the session policy it passes when it
# takes credentials for the one customer the signed-in person belongs to, so
# they are the narrowest of the two and the role is the wider.
functions = {
  read = {
    handler           = "handler.read"
    routes            = ["GET /api/account"]
    data_actions      = ["dynamodb:Query", "dynamodb:GetItem"]
    parameter_actions = []
    pool_actions      = []
    registry_actions  = []
    versions_actions  = ["ssm:GetParameter"]
  }
  # The only function that takes a customer number: it lists the labels, claims
  # the lowest free one, writes that label, and tells the sign-in service which
  # customer the person belongs to. It also moves a firm that signed up before
  # each customer had a table out of the old shared one.
  enrol = {
    handler           = "handler.enrol"
    routes            = ["POST /api/account/firm"]
    data_actions      = ["dynamodb:Query", "dynamodb:GetItem", "dynamodb:PutItem"]
    parameter_actions = ["ssm:GetParametersByPath", "ssm:GetParameter", "ssm:PutParameter"]
    pool_actions = [
      "cognito-idp:AdminGetUser",
      "cognito-idp:AdminUpdateUserAttributes",
    ]
    registry_actions = ["dynamodb:GetItem", "dynamodb:PutItem"]
    versions_actions = ["ssm:GetParameter"]
  }
  write = {
    handler           = "handler.write"
    routes            = ["PUT /api/account/{section}"]
    data_actions      = ["dynamodb:Query", "dynamodb:GetItem", "dynamodb:PutItem"]
    parameter_actions = ["ssm:GetParameter", "ssm:PutParameter"]
    pool_actions      = []
    registry_actions  = []
    versions_actions  = ["ssm:GetParameter"]
  }
  accept = {
    handler           = "handler.accept"
    routes            = ["POST /api/account/agreement"]
    data_actions      = ["dynamodb:Query", "dynamodb:GetItem", "dynamodb:PutItem"]
    parameter_actions = ["ssm:GetParameter", "ssm:PutParameter"]
    pool_actions      = []
    registry_actions  = []
    versions_actions  = []
  }
  # The only function that may create, remove or sign out a member. It cannot
  # change the pool itself, and it cannot read or write a customer's label.
  people = {
    handler = "handler.people"
    routes = [
      "POST /api/account/people",
      "PUT /api/account/people/{member}",
      "DELETE /api/account/people/{member}",
    ]
    data_actions      = ["dynamodb:Query", "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    parameter_actions = []
    pool_actions = [
      "cognito-idp:AdminCreateUser",
      "cognito-idp:AdminDeleteUser",
      "cognito-idp:AdminUserGlobalSignOut",
    ]
    registry_actions = []
    versions_actions = []
  }
  # The version catalogue. It answers no route: a version tag created in the
  # source repository is its only caller, and the catalogue is all it touches.
  # With no data_actions it is not trusted by the customer data role at all, so
  # no customer's table is reachable from it.
  catalogue = {
    handler           = "handler.catalogue"
    routes            = []
    data_actions      = []
    parameter_actions = []
    pool_actions      = []
    registry_actions  = []
    versions_actions  = ["ssm:GetParameter", "ssm:PutParameter"]
  }
}

# Built before plan, from this stack's directory. See runbooks/deploy.md.
package_dir = "../../../../build/api"

lambda_runtime = "python3.12"
# Memory is also processor: at 256 the first request after a quiet spell spent
# several seconds making its AWS clients, which is what a person saw as a page
# that took ten seconds to say what was done.
lambda_memory_mb = 1024

# A request is now a session from STS, then several calls to the customer's
# table, and for enrol a walk of the pool's labels and a UID claimed in the
# registry. Ten seconds was tight for that; twenty is still far
# short of anything a person would wait for.
lambda_timeout_seconds = 20

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

# Above the function timeout, so a slow function times out as itself. An HTTP
# API allows at most 30,000.
integration_timeout_ms = 25000
