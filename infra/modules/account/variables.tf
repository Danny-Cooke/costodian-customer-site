variable "platform" {
  description = "The platform object: the slots and values every module shares."
  type = object({
    prefix        = string
    project       = string
    environment   = string
    postfix       = string
    region        = string
    edge_region   = string
    account_id    = string
    partition     = string
    unique_suffix = string
    tags          = map(string)
  })
}

variable "component" {
  description = "The bounded context for these names."
  type        = string
}

variable "product_name" {
  description = "The product's name as a person reads it, put in place of the product placeholder in the messages the pool sends. Declared once in platform.tfvars.json and passed in."
  type        = string
}

variable "site_url" {
  description = "Where the site is, put in place of the site-address placeholder in the invitation message. Passed in by the caller: this module does not know how the site is served."
  type        = string
}

# ------------------------------------------------------------------- the key

variable "key_rotation_enabled" {
  description = "Whether the key material is rotated on AWS's schedule."
  type        = bool
  default     = true
}

variable "key_deletion_window_days" {
  description = "Days between asking for the key's deletion and it happening."
  type        = number
  default     = 30
}

variable "key_alias_prefix" {
  description = "KMS requires every alias to begin with this."
  type        = string
  default     = "alias/"
}

variable "key_admin_actions" {
  description = "What the account root may do to the key. Listed in full so the policy holds no wildcard; the root statement keeps the key manageable."
  type        = list(string)
}

variable "key_dynamodb_actions" {
  description = "What a principal of this account may do with the key when DynamoDB is the one calling."
  type        = list(string)
}

variable "key_logs_actions" {
  description = "What CloudWatch Logs may do with the key for this component's log groups."
  type        = list(string)
}

variable "dynamodb_via_service" {
  description = "The kms:ViaService value for DynamoDB. %s is the Region."
  type        = string
  default     = "dynamodb.%s.amazonaws.com"
}

variable "logs_service_principal" {
  description = "The CloudWatch Logs service principal. %s is the Region."
  type        = string
  default     = "logs.%s.amazonaws.com"
}

# ----------------------------------------------------------------- the table

variable "table_hash_key" {
  description = "Name of the table's partition key attribute. Changing it replaces the table."
  type        = string
  default     = "pk"
}

variable "table_range_key" {
  description = "Name of the table's sort key attribute. Changing it replaces the table."
  type        = string
  default     = "sk"
}

variable "table_billing_mode" {
  description = "DynamoDB billing mode. On demand, so there is nothing to size."
  type        = string
  default     = "PAY_PER_REQUEST"
}

variable "table_key_type" {
  description = "Attribute type of both key attributes: S for string."
  type        = string
  default     = "S"
}

variable "table_point_in_time_recovery" {
  description = "Whether the table can be restored to any second in the backup window."
  type        = bool
  default     = true
}

variable "table_deletion_protection" {
  description = "Whether the table refuses to be deleted. The sign-up data is the account record, so this is on outside throwaway environments."
  type        = bool
}

# ---------------------------------------------------------------- the sign-in

variable "username_attributes" {
  description = "What a person signs in with. Email only: there is no separate user name."
  type        = list(string)
}

variable "auto_verified_attributes" {
  description = "Attributes Cognito verifies itself by sending a code."
  type        = list(string)
}

variable "username_case_sensitive" {
  description = "Whether Example@firm.test and example@firm.test are two accounts. Changing it replaces the pool."
  type        = bool
  default     = false
}

variable "allow_admin_create_user_only" {
  description = "True closes self sign-up. False is how a firm signs itself up."
  type        = bool
}

variable "password_minimum_length" {
  description = "Shortest password the pool accepts. Also shown to the person as they type."
  type        = number
  default     = 12
}

variable "password_require_uppercase" {
  description = "Whether a password must hold an upper-case letter."
  type        = bool
  default     = true
}

variable "password_require_lowercase" {
  description = "Whether a password must hold a lower-case letter."
  type        = bool
  default     = true
}

variable "password_require_numbers" {
  description = "Whether a password must hold a digit."
  type        = bool
  default     = true
}

variable "password_require_symbols" {
  description = "Whether a password must hold a symbol."
  type        = bool
  default     = true
}

variable "temporary_password_validity_days" {
  description = "Days an administrator-set password stays usable."
  type        = number
  default     = 7
}

variable "invite_message_template" {
  description = "The email a person invited to an existing firm is sent. Written in tfvars with placeholders: this module puts the product's name, the site's address and the temporary password's lifetime in, and leaves Cognito's own user name and one-time code placeholders alone."
  type = object({
    subject = string
    message = string
  })
}

variable "verification_message_template" {
  description = "The email a person who signs the firm up themselves is sent to confirm the address. Same placeholders as the invitation."
  type = object({
    subject = string
    message = string
  })
}

variable "verification_default_email_option" {
  description = "CONFIRM_WITH_CODE sends a code the person types in; CONFIRM_WITH_LINK sends a link. The sign-up page asks for a code."
  type        = string
  default     = "CONFIRM_WITH_CODE"
}

variable "placeholder_format" {
  description = "How a placeholder is written in the message templates. %s is the placeholder's name, so the token text is composed from the name and never written twice."
  type        = string
  default     = "{%s}"
}

variable "required_message_placeholders" {
  description = "The placeholders Cognito itself requires in each message, by template key. Checked at plan, because a template missing one is refused at apply."
  type        = map(list(string))
}

variable "account_recovery_mechanism" {
  description = "How a forgotten password is recovered. Verified email only: no SMS, so no phone number is held."
  type        = string
  default     = "verified_email"
}

variable "account_recovery_priority" {
  description = "Priority of the one recovery mechanism."
  type        = number
  default     = 1
}

variable "mfa_configuration" {
  description = "OFF, ON or OPTIONAL. Turning it on needs a second factor configured as well."
  type        = string
}

variable "user_pool_deletion_protection" {
  description = "ACTIVE or INACTIVE. Deleting the pool loses every sign-in."
  type        = string
}

variable "email_sending_account" {
  description = "COGNITO_DEFAULT uses Cognito's own sender and its low daily limit; DEVELOPER uses SES."
  type        = string
  default     = "COGNITO_DEFAULT"
}

variable "client_auth_flows" {
  description = "The authentication flows the browser client may use."
  type        = list(string)
}

variable "client_generate_secret" {
  description = "A browser client cannot keep a secret, so it has none."
  type        = bool
  default     = false
}

variable "prevent_user_existence_errors" {
  description = "ENABLED makes a wrong address and a wrong password answer alike, so the pool cannot be used to find out who has an account."
  type        = string
  default     = "ENABLED"
}

variable "enable_token_revocation" {
  description = "Whether a refresh token can be revoked before it expires."
  type        = bool
  default     = true
}

variable "token_validity" {
  description = "How long each token lasts, in the units below."
  type = object({
    id      = number
    access  = number
    refresh = number
  })
}

variable "token_validity_units" {
  description = "The unit each validity above is counted in: seconds, minutes, hours or days."
  type = object({
    id      = string
    access  = string
    refresh = string
  })
}

# ------------------------------------------------------------- the functions

variable "functions" {
  description = "One entry per function: its handler, the routes it answers, and the exact table, key and user pool actions it needs. One role is built per entry from those three lists, so a function can never do another's work. A function with no pool actions gets no pool statement and is not told the pool's id."
  type = map(object({
    handler       = string
    routes        = list(string)
    table_actions = list(string)
    key_actions   = list(string)
    pool_actions  = list(string)
  }))
}

variable "function_permissions_boundary_arn" {
  description = "The permissions boundary every function role must carry. Created in the bootstrap stack; composed by the caller from the naming module and the account id, never written as a literal. The role that creates these roles is denied CreateRole without it."
  type        = string
}

variable "package_dir" {
  description = "Directory holding the built function package, relative to the stack being planned. Every function runs the same package and differs only by handler."
  type        = string
}

variable "lambda_runtime" {
  description = "Runtime every function runs on."
  type        = string
}

variable "lambda_architectures" {
  description = "Instruction set the package is built for."
  type        = list(string)
  default     = ["arm64"]
}

variable "lambda_memory_mb" {
  description = "Memory each function is given. CPU scales with it."
  type        = number
}

variable "lambda_timeout_seconds" {
  description = "Longest a single invocation may run."
  type        = number
}

variable "lambda_log_format" {
  description = "Text or JSON."
  type        = string
  default     = "Text"
}

variable "lambda_service_principal" {
  description = "The service principal the function roles are assumed by."
  type        = string
  default     = "lambda.amazonaws.com"
}

variable "lambda_invoke_action" {
  description = "The action the API is granted on each function."
  type        = string
  default     = "lambda:InvokeFunction"
}

variable "log_retention_days" {
  description = "Days a log line is kept. The functions log no personal data, so this is an operational window, not a data retention period."
  type        = number
}

variable "log_write_actions" {
  description = "What a function may do to its own log group. Creating the group is not among them: Terraform creates it."
  type        = list(string)
}

# ------------------------------------------------------------------- the API

variable "api_protocol_type" {
  description = "HTTP for an HTTP API, WEBSOCKET for the other kind."
  type        = string
  default     = "HTTP"
}

variable "api_stage_name" {
  description = "$default is the stage that serves the API's own domain with no stage name in the path."
  type        = string
  default     = "$default"
}

variable "api_auto_deploy" {
  description = "Whether a route change is deployed to the stage as soon as it is made."
  type        = bool
  default     = true
}

variable "api_throttling" {
  description = "Requests per second, and the burst above it, the stage allows across all routes."
  type = object({
    rate  = number
    burst = number
  })
}

variable "api_detailed_metrics_enabled" {
  description = "Whether CloudWatch gets per-route metrics as well as per-stage."
  type        = bool
  default     = false
}

variable "api_access_log_fields" {
  description = "The access log line, as field name to $context expression. No request body, no Authorization header and no caller address or user agent: the log holds no personal data."
  type        = map(string)
}

variable "authorizer_type" {
  description = "JWT, so the API checks the Cognito token itself and no function sees an unauthenticated request."
  type        = string
  default     = "JWT"
}

variable "authorizer_identity_sources" {
  description = "Where the API looks for the token."
  type        = list(string)
}

variable "route_authorization_type" {
  description = "Authorisation applied to every route."
  type        = string
  default     = "JWT"
}

variable "integration_type" {
  description = "AWS_PROXY hands the whole request to the function."
  type        = string
  default     = "AWS_PROXY"
}

variable "integration_method" {
  description = "Method the API calls the function with. Always POST for a Lambda proxy."
  type        = string
  default     = "POST"
}

variable "payload_format_version" {
  description = "Shape of the event the function receives."
  type        = string
  default     = "2.0"
}

variable "integration_timeout_ms" {
  description = "Longest the API waits for a function. Must be at least the function timeout."
  type        = number
}

variable "apigateway_service_principal" {
  description = "The service principal allowed to invoke the functions."
  type        = string
  default     = "apigateway.amazonaws.com"
}
