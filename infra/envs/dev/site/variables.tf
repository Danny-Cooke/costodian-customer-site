variable "assume_service_roles" {
  description = "Whether each provider assumes the role for its own service. False on a pull request, where the job already holds the read-only plan role and has nothing to assume; true on a deploy, where the job holds the deploy role, which can do nothing but chain into the service roles. It is a property of the run, not of the environment, so it has a default and the workflow states it on both jobs."
  type        = bool
  default     = false
}

variable "web_bucket_force_destroy" {
  description = "Whether Terraform may empty the site bucket to delete it. A property of the run, not of the environment, so it has a default: only scripts/destroy.sh sets it, and the storage role may delete the bucket's objects and nothing else."
  type        = bool
  default     = false
}

variable "index_document" {
  description = "The file served for a page path, and for the root. Must match the build tool's index file name."
  type        = string
  default     = "index.html"
}

variable "not_found_document" {
  description = "Path of the not-found page. Must match routes.not_found in site/config/site.json."
  type        = string
}

variable "not_found_error_codes" {
  description = "Origin error codes answered with the not-found page."
  type        = list(number)
  default     = [403, 404]
}

variable "not_found_response_code" {
  description = "Status code returned with the not-found page."
  type        = number
  default     = 404
}

variable "cloudfront_price_class" {
  description = "CloudFront price class."
  type        = string
}

variable "cloudfront_cache_policy_name" {
  description = "Name of the AWS managed cache policy."
  type        = string
  default     = "Managed-CachingOptimized"
}

variable "cloudfront_allowed_methods" {
  description = "Methods CloudFront forwards. The site is static, so reads only."
  type        = list(string)
  default     = ["GET", "HEAD", "OPTIONS"]
}

variable "cloudfront_cached_methods" {
  description = "Methods CloudFront caches."
  type        = list(string)
  default     = ["GET", "HEAD"]
}

variable "content_security_policy" {
  description = "Content-Security-Policy as directive => sources."
  type        = map(list(string))
}

variable "permissions_policy_denied" {
  description = "Browser features the site switches off."
  type        = list(string)
}

variable "waf_managed_rule_groups" {
  description = "AWS managed rule groups to apply, with their priorities."
  type = list(object({
    name     = string
    priority = number
  }))
}

variable "waf_rate_limit" {
  description = "Requests per five minutes from one IP before the rate rule blocks it."
  type        = number
}

variable "waf_rate_rule_priority" {
  description = "Priority of the rate rule relative to the managed groups."
  type        = number
}

variable "redirect_path" {
  description = "The path on the main website that forwards to this site."
  type        = string
}

variable "csp_connect_directive" {
  description = "The Content-Security-Policy directive the Cognito origin is added to."
  type        = string
  default     = "connect-src"
}

variable "cognito_endpoint_template" {
  description = "Cognito's regional endpoint. %s is the Region, so the host is never written down."
  type        = string
  default     = "https://cognito-idp.%s.amazonaws.com"
}

# ------------------------------------------------------- the sign-up back end

variable "api_path_pattern" {
  description = "The path prefix CloudFront sends to the API. The route keys carry the same prefix, so the path reaches the API unchanged."
  type        = string
}

variable "key_admin_actions" {
  description = "What the account root may do to the sign-up key."
  type        = list(string)
}

variable "key_dynamodb_actions" {
  description = "What a principal of this account may do with the sign-up key when DynamoDB is calling."
  type        = list(string)
}

variable "key_logs_actions" {
  description = "What CloudWatch Logs may do with the sign-up key."
  type        = list(string)
}

variable "table_deletion_protection" {
  description = "Whether the one table every firm shared before each had its own refuses to be deleted."
  type        = bool
}

# ------------------------------------------------------- the customer pool

variable "customer_number_digits" {
  description = "How many digits a customer number is written with, zero padded. It is in every customer table and key name, so changing it replaces them."
  type        = number
}

variable "customer_spares" {
  description = "How many unclaimed tables the pool keeps beyond the highest claimed number, so a sign-up creates nothing."
  type        = number
}

variable "customer_free_status" {
  description = "The status word in a customer's label that means nobody has taken that number."
  type        = string
}

variable "customer_parameter_fields" {
  description = "The two field names in a customer's label: the number and the status."
  type = object({
    number = string
    status = string
  })
}

variable "customer_parameter_path_actions" {
  description = "Which label actions are taken on the parameter path itself rather than on one parameter under it."
  type        = list(string)
}

variable "customer_table_deletion_protection" {
  description = "Whether a customer's table refuses to be deleted. Only scripts/destroy.sh turns it off, for all of them at once."
  type        = bool
}

variable "removed_customer_numbers" {
  description = "Customer numbers to leave out of the pool, which destroys that number's table, key and label. The only way a customer's table is ever destroyed."
  type        = list(string)
}

variable "unprotected_customer_numbers" {
  description = "Customer numbers whose table may be deleted: the first of the two applies that remove a customer."
  type        = list(string)
}

variable "customer_data_table_actions" {
  description = "What the customer data role may do on a customer's table. The ceiling; a session policy narrows each request to one customer."
  type        = list(string)
}

variable "customer_data_key_actions" {
  description = "What the customer data role may do with a customer's key, through DynamoDB only."
  type        = list(string)
}

variable "legacy_key_actions" {
  description = "What a function that still reads the old shared table may do with that table's key."
  type        = list(string)
}

# ---------------------------------------------------- the version catalogue

variable "version_tag_pattern" {
  description = "The pattern a git tag must match to be a product version. Given to every function, so the one that writes the catalogue and the ones that read it agree."
  type        = string
}

variable "version_source_repository" {
  description = "The CodeCommit repository in this account and Region whose tags are product versions."
  type        = string
}

variable "version_source_event" {
  description = "What the version rule matches: the event source, its detail type, which reference events count and which kind of reference."
  type = object({
    source          = string
    detail_type     = string
    events          = list(string)
    reference_types = list(string)
  })
}

variable "version_catalogue_function" {
  description = "Which key of the functions map the version rule invokes. That function answers no route."
  type        = string
}

variable "customer_attribute_name" {
  description = "The custom user pool attribute holding a person's customer number. Adding it is an in-place change to the pool; Cognito cannot change or remove one afterwards."
  type        = string
}

variable "customer_attribute_min_length" {
  description = "Shortest customer number the pool accepts in that attribute."
  type        = number
}

variable "client_read_attributes" {
  description = "The attributes the browser's app client may read, besides the customer number, which the account module adds."
  type        = list(string)
}

variable "client_write_attributes" {
  description = "The attributes the browser's app client may write. The customer number is deliberately not one of them."
  type        = list(string)
}

variable "username_attributes" {
  description = "What a person signs in with."
  type        = list(string)
}

variable "auto_verified_attributes" {
  description = "Attributes Cognito verifies by sending a code."
  type        = list(string)
}

variable "allow_admin_create_user_only" {
  description = "True closes self sign-up."
  type        = bool
}

variable "password_minimum_length" {
  description = "Shortest password the pool accepts. The sign-up page states the same number, from this stack's output."
  type        = number
}

variable "password_require_uppercase" {
  description = "Whether a password must hold an upper-case letter."
  type        = bool
}

variable "password_require_lowercase" {
  description = "Whether a password must hold a lower-case letter."
  type        = bool
}

variable "password_require_numbers" {
  description = "Whether a password must hold a digit."
  type        = bool
}

variable "password_require_symbols" {
  description = "Whether a password must hold a symbol."
  type        = bool
}

variable "temporary_password_validity_days" {
  description = "Days an invited member's temporary password stays usable. The invitation email states the same number, from this one value."
  type        = number
}

variable "invite_message_template" {
  description = "Subject and body of the email an invited member is sent, with placeholders. The product's name, the site's address and the temporary password's lifetime are put in by the account module; Cognito's own user name and one-time code placeholders are left alone."
  type = object({
    subject = string
    message = string
    sms     = string
  })
}

variable "verification_message_template" {
  description = "Subject and body of the email that confirms the address of a person who signs the firm up themselves."
  type = object({
    subject = string
    message = string
  })
}

variable "required_message_placeholders" {
  description = "The placeholders Cognito itself requires in each message, by template key."
  type        = map(list(string))
}

variable "mfa_configuration" {
  description = "OFF, ON or OPTIONAL for the user pool."
  type        = string
}

variable "user_pool_deletion_protection" {
  description = "ACTIVE or INACTIVE for the user pool."
  type        = string
}

variable "client_auth_flows" {
  description = "Authentication flows the browser client may use."
  type        = list(string)
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
  description = "The unit each token validity is counted in."
  type = object({
    id      = string
    access  = string
    refresh = string
  })
}

variable "functions" {
  description = "The sign-up functions: handler, the routes each answers, which may be none, and the exact actions each one's own role is built from. data_actions are the only ones not in the role: they are what the function asks for in the session policy it passes when it takes credentials for one customer's table, and a function with none of them cannot assume that role at all."
  type = map(object({
    handler              = string
    routes               = list(string)
    data_actions         = list(string)
    parameter_actions    = list(string)
    pool_actions         = list(string)
    legacy_table_actions = list(string)
    versions_actions     = optional(list(string), [])
  }))
}

variable "package_dir" {
  description = "Directory holding the built function package, relative to this stack. Built before plan; see runbooks/deploy.md."
  type        = string
}

variable "lambda_runtime" {
  description = "Runtime the sign-up functions run on."
  type        = string
}

variable "lambda_memory_mb" {
  description = "Memory each sign-up function is given."
  type        = number
}

variable "lambda_timeout_seconds" {
  description = "Longest a sign-up function may run."
  type        = number
}

variable "log_retention_days" {
  description = "Days a sign-up log line is kept."
  type        = number
}

variable "log_write_actions" {
  description = "What a function may do to its own log group."
  type        = list(string)
}

variable "api_throttling" {
  description = "Requests per second, and the burst above it, the API stage allows."
  type = object({
    rate  = number
    burst = number
  })
}

variable "api_access_log_fields" {
  description = "The API access log line, as field name to $context expression. No body, no Authorization header, no caller address."
  type        = map(string)
}

variable "authorizer_identity_sources" {
  description = "Where the API looks for the Cognito token."
  type        = list(string)
}

variable "integration_timeout_ms" {
  description = "Longest the API waits for a function."
  type        = number
}
