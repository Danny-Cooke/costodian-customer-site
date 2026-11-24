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

variable "customer_component" {
  description = "The bounded context of the per-customer resources: one table, one key and one label parameter per customer number. A second component rather than a second module, because the customer data role is trusted by this component's function roles and the functions are told this component's names, and two modules would have to depend on each other."
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

# ------------------------------------------------------- the customer pool

variable "customer_parameter_path" {
  description = "The SSM parameter path holding one label per customer number, composed by the caller from the platform slots. An SSM parameter name is a path, so it cannot come from the naming module; the caller composes it once and the bootstrap stack scopes its roles to the same path."
  type        = string

  validation {
    condition     = startswith(var.customer_parameter_path, "/") && !endswith(var.customer_parameter_path, "/")
    error_message = "customer_parameter_path must begin with / and must not end with one: the customer number is joined to it."
  }
}

variable "customer_number_digits" {
  description = "How many digits a customer number is written with, zero padded: 4 gives 0001. It is the width of the number in every name, so changing it renames every customer's table and key, which replaces them. Fixed in the first version."
  type        = number

  validation {
    condition     = var.customer_number_digits >= 1 && var.customer_number_digits <= 12
    error_message = "customer_number_digits must be between 1 and 12: the API accepts a customer number of up to twelve digits."
  }
}

variable "customer_spares" {
  description = "How many unclaimed tables the pool keeps beyond the highest claimed number, so that a sign-up takes a table that already exists and creates nothing. Each pipeline run tops the pool back up."
  type        = number

  validation {
    condition     = var.customer_spares >= 1
    error_message = "customer_spares must be at least 1, or a sign-up has nothing to take."
  }
}

variable "customer_free_status" {
  description = "The status word in a label that means nobody has taken that number. Any other value, and a value that cannot be read, counts as claimed, so the pool never shrinks under a live customer."
  type        = string
}

variable "customer_parameter_fields" {
  description = "The two field names in a customer's label: the one holding the number and the one holding the status. The API writes the same two names, so they are declared here and read from the deployed values rather than written twice in two languages."
  type = object({
    number = string
    status = string
  })
}

variable "customer_parameter_path_actions" {
  description = "Which of a function's parameter_actions are taken on the path itself rather than on one parameter under it: listing the pool is a call on the path. Any other action is granted on the parameters under the path and not on the path."
  type        = list(string)
}

variable "parameter_type" {
  description = "SSM parameter type for the ones this module creates. String: neither a customer's label nor the version catalogue is a secret, and nothing in either is personal beyond the firm's own trading name."
  type        = string
  default     = "String"
}

variable "customer_number_placeholder" {
  description = "What stands in for the customer number in the name, ARN and alias templates the functions are given. The API replaces it with the number of the customer whose table it is reaching, so the two must agree."
  type        = string
  default     = "{number}"
}

variable "removed_customer_numbers" {
  description = "Customer numbers to leave out of the pool, which destroys that number's table, key and label. The only way a customer's table is ever destroyed: the pool itself never shrinks. Two steps, so that a destroy is deliberate - name the number in unprotected_customer_numbers and apply, then move it here and apply again."
  type        = list(string)
  default     = []
}

variable "unprotected_customer_numbers" {
  description = "Customer numbers whose table may be deleted, the first half of removing a customer. Everything else keeps customer_table_deletion_protection."
  type        = list(string)
  default     = []
}

variable "customer_table_deletion_protection" {
  description = "Whether a customer's table refuses to be deleted. It holds that firm's own account record, so this is on outside throwaway environments; scripts/destroy.sh is the one place it is turned off for all of them at once."
  type        = bool
}

variable "customer_data_table_actions" {
  description = "What the customer data role may do on a customer's table. Deliberately every action any function needs on any customer's table: the role is the ceiling and the session policy a function passes when it assumes it is what narrows a request to one customer."
  type        = list(string)
}

variable "customer_data_key_actions" {
  description = "What the customer data role may do with a customer's key, allowed only through DynamoDB and only on keys whose alias matches the customer alias pattern."
  type        = list(string)
}

variable "data_role_assume_actions" {
  description = "What a function role may do to the customer data role: take credentials, and nothing else."
  type        = list(string)
  default     = ["sts:AssumeRole"]
}

variable "legacy_key_actions" {
  description = "What a function with legacy_table_actions may do with the key the old shared table is encrypted with. Granted only to those functions, and only while that table exists."
  type        = list(string)
}

variable "action_list_separator" {
  description = "What separates the actions in the DATA_ACTIONS environment variable. The API splits on the same character."
  type        = string
  default     = ","
}

variable "customer_attribute_name" {
  description = "The custom user pool attribute holding a person's customer number. The token claim is the prefix and this name; only the API may write it."
  type        = string
}

variable "custom_attribute_prefix" {
  description = "What Cognito puts before a custom attribute's name in a token claim and in an attribute list."
  type        = string
  default     = "custom:"
}

variable "customer_attribute_data_type" {
  description = "Type of the customer number attribute. String: it is a zero-padded number, not an integer."
  type        = string
  default     = "String"
}

variable "customer_attribute_mutable" {
  description = "Whether the API may change a person's customer number after it is first set. Needed to move a person into a firm."
  type        = bool
  default     = true
}

variable "customer_attribute_min_length" {
  description = "Shortest customer number the pool accepts in the attribute. The longest is customer_number_digits."
  type        = number
}

variable "client_read_attributes" {
  description = "The attributes the browser's app client may read, besides the customer number, which this module adds. Every one of them reaches the browser in the token."
  type        = list(string)
}

variable "client_write_attributes" {
  description = "The attributes the browser's app client may write. The customer number is deliberately not among them: a person who could write their own number could point themselves at another firm's table. Checked at plan."
  type        = list(string)
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
    sms     = string
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
  description = <<-EOT
    One entry per function: its handler, the routes it answers, and the exact
    actions it needs, by what they are taken on. One role is built per entry
    from those lists, so a function can never do another's work.

    data_actions are the only ones that do not appear in the role: no function
    may reach a customer's table itself. They are given to the function as an
    environment variable, and the function puts them in the session policy it
    passes to sts:AssumeRole on the customer data role, which narrows that one
    request to one customer's table. The role's own ceiling is the data role's
    policy; this list is what the function asks for within it.

    parameter_actions are taken on the customer label parameters and nothing
    else; versions_actions on the one version catalogue parameter and nothing
    else; pool_actions on this user pool and nothing else; legacy_table_actions
    on the one table every firm shared before each had its own, which stays
    only until the firms signed up before then have been moved out of it. An
    empty list writes no statement at all, so a function that does not need a
    service never mentions it, and a function with no data_actions is not even
    allowed to take customer data credentials.

    routes may be empty: a function that answers no request is reached another
    way, and gets no integration, no route and no permission for the API.
  EOT
  type = map(object({
    handler              = string
    routes               = list(string)
    data_actions         = list(string)
    parameter_actions    = list(string)
    pool_actions         = list(string)
    legacy_table_actions = list(string)
    versions_actions     = optional(list(string), [])
  }))

  validation {
    condition     = length([for name, fn in var.functions : name if length(fn.data_actions) > 0]) > 0
    error_message = "functions: at least one function must have data_actions, or the customer data role would be trusted by nobody."
  }
}

# -------------------------------------------------- the version catalogue

variable "versions_parameter_name" {
  description = "The SSM parameter holding the product's version catalogue as a JSON list, composed by the caller from the platform slots beside the customer path. One parameter, not a path of them."
  type        = string

  validation {
    condition     = startswith(var.versions_parameter_name, "/") && !endswith(var.versions_parameter_name, "/")
    error_message = "versions_parameter_name must begin with / and must not end with one."
  }
}

variable "initial_versions" {
  description = "The versions the catalogue starts with. Written once; the value is ignored after that, because the catalogue function appends to it."
  type        = list(string)
}

variable "version_tag_pattern" {
  description = "The pattern a git tag must match to be a product version. Given to every function, so the one that appends to the catalogue and the ones that read it agree on what a version is."
  type        = string
}

variable "version_source_repository" {
  description = "The CodeCommit repository whose tags are product versions, in this account and Region. Its ARN is composed from the platform slots."
  type        = string
}

variable "version_source_event" {
  description = "What the rule matches: the event source, its detail type, which reference events count and which kind of reference. A tag created or moved in that one repository, and nothing else."
  type = object({
    source          = string
    detail_type     = string
    events          = list(string)
    reference_types = list(string)
  })
}

variable "version_catalogue_function" {
  description = "Which key of var.functions the version rule invokes. It answers no route: the rule is its only caller."
  type        = string
}

variable "events_service_principal" {
  description = "The service principal allowed to invoke the function the version rule targets."
  type        = string
  default     = "events.amazonaws.com"
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
