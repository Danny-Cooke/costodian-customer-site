output "aws_region" {
  description = "The Region this stack is in. The pipeline checks its own AWS_REGION against this."
  value       = var.platform.region
}

output "bucket_name" {
  description = "Bucket the pipeline syncs the built site into."
  value       = module.web.bucket_name
}

output "distribution_id" {
  description = "Distribution to invalidate after a sync."
  value       = module.web.distribution_id
}

output "site_url" {
  description = "Where the site is."
  value       = module.web.site_url
}

output "user_pool_id" {
  description = "The Cognito pool the sign-up page signs in against."
  value       = module.account.user_pool_id
}

output "user_pool_client_id" {
  description = "The app client the sign-up page uses. Public by design: the client has no secret."
  value       = module.account.user_pool_client_id
}

output "cognito_endpoint" {
  description = "The regional Cognito endpoint the browser calls, which is also what connect-src allows."
  value       = "${local.cognito_origin}/"
}

output "password_minimum_length" {
  description = "The pool's minimum password length, so the page states the same number the pool enforces."
  value       = var.password_minimum_length
}

output "invite_expiry_days" {
  description = "How long an invited member's temporary password lasts, so the portal states the number the pool enforces."
  value       = var.temporary_password_validity_days
}

output "api_base_path" {
  description = "The path the sign-up API is reached on, on the site's own origin."
  value       = trimsuffix(var.api_path_pattern, "/*")
}

output "account_table_name" {
  description = "The one table every firm shared before each customer had its own."
  value       = module.account.table_name
}

output "customer_parameter_path" {
  description = "The SSM path holding one label per customer number."
  value       = module.account.customer_parameter_path
}

output "versions_parameter_name" {
  description = "The SSM parameter holding the product's version catalogue as a JSON list."
  value       = module.account.versions_parameter_name
}

output "customer_table_name_template" {
  description = "A customer's table name, with the placeholder where the customer number goes."
  value       = module.account.customer_table_name_template
}

output "customer_table_arn_template" {
  description = "A customer's table ARN, with the placeholder where the customer number goes."
  value       = module.account.customer_table_arn_template
}

output "customer_key_alias_template" {
  description = "A customer's key alias, with the placeholder where the customer number goes."
  value       = module.account.customer_key_alias_template
}

output "customer_numbers" {
  description = "Every customer number in the pool, claimed and free, lowest first."
  value       = module.account.customer_numbers
}

output "customer_free_status" {
  description = "The status word in a label that means nobody has taken that number."
  value       = module.account.customer_free_status
}

output "customer_attribute" {
  description = "The token claim holding a person's customer number."
  value       = module.account.customer_attribute
}

output "customer_data_role_arn" {
  description = "The role a function assumes, with a session policy for one customer, to reach that customer's table."
  value       = module.account.customer_data_role_arn
}

output "krystal_redirect_line" {
  description = "The line to add to the .htaccess of the main website so the short address forwards here."
  value       = "Redirect 302 ${var.redirect_path} ${module.web.site_url}/"
}
