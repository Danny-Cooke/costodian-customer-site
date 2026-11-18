# What scripts/bootstrap.sh needs: everything it writes into the GitHub
# environments, and the names it would otherwise have to be told twice.

output "state_bucket" {
  description = "TF_STATE_BUCKET for every GitHub environment, and the backend bucket this stack's own state is migrated into."
  value       = aws_s3_bucket.state.bucket
}

output "site_state_key" {
  description = "TF_STATE_KEY for every GitHub environment."
  value       = var.site_state_key
}

output "bootstrap_state_key" {
  description = "The key this stack's own state lives under in the same bucket."
  value       = var.bootstrap_state_key
}

output "aws_region" {
  description = "AWS_REGION for every GitHub environment."
  value       = var.platform.region
}

output "role_arns" {
  description = "AWS_ROLE_ARN for each GitHub environment, keyed by the environment's name: the plan environment gets the read-only role, the deploy environment gets the role that may only assume the service roles."
  value       = { for key, name in var.github_environments : name => aws_iam_role.entry[key].arn }
}

output "publish_role_arn" {
  description = "AWS_PUBLISH_ROLE_ARN for the deploy environment. The workflow's publish step assumes it from the deploy role; Terraform never does."
  value       = aws_iam_role.service[var.publish_service].arn
}

output "deploy_environment" {
  description = "Which GitHub environment holds the deploy role, so the script knows where the publish role ARN goes."
  value       = var.github_environments.deploy
}

output "service_role_arns" {
  description = "The role each of the site stack's providers assumes, keyed by service. The site stack composes the same ARNs from the naming module rather than reading them from here, so this is for an operator checking a chain."
  value       = { for service, role in aws_iam_role.service : service => role.arn }
}

output "function_permissions_boundary_arn" {
  description = "The ceiling every sign-up function role must carry. The site stack composes the same ARN from the naming module."
  value       = aws_iam_policy.boundary.arn
}

output "github_repository_path" {
  description = "owner/repository, so the script names the repository from the same place Terraform trusts it from."
  value       = local.repository_path
}
