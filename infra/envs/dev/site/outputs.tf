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

output "api_base_path" {
  description = "The path the sign-up API is reached on, on the site's own origin."
  value       = trimsuffix(var.api_path_pattern, "/*")
}

output "account_table_name" {
  description = "The table holding the account record."
  value       = module.account.table_name
}

output "krystal_redirect_line" {
  description = "The line to add to the .htaccess of the main website so the short address forwards here."
  value       = "Redirect 302 ${var.redirect_path} ${module.web.site_url}/"
}
