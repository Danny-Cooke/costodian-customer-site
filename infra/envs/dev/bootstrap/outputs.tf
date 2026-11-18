# What scripts/bootstrap.sh checks after an apply, and what an operator reading
# a chain needs. The workflow is told nothing from here: scripts/names.sh works
# every name out of the configuration, so no job needs this stack's state.

output "state_bucket" {
  description = "The bucket this stack's own state is migrated into, checked by scripts/bootstrap.sh against the name it worked out before the apply."
  value       = aws_s3_bucket.state.bucket
}

output "site_state_key" {
  description = "The key the site stack's state lives under in the same bucket."
  value       = var.site_state_key
}

output "bootstrap_state_key" {
  description = "The key this stack's own state lives under in the same bucket."
  value       = var.bootstrap_state_key
}

output "aws_region" {
  description = "The Region every resource of this environment is in."
  value       = var.platform.region
}

output "role_arns" {
  description = "The entry role each GitHub environment may assume, keyed by the environment's name: the plan environment gets the read-only role, the deploy environment gets the role that may only assume the service roles. The bootstrap environment is not here; its role is the seed's."
  value       = { for key, role in aws_iam_role.entry : var.github_environments[key] => role.arn }
}

output "publish_role_arn" {
  description = "The role the workflow's publish step assumes from the deploy role. Terraform never does."
  value       = aws_iam_role.service[var.publish_service].arn
}

output "github_environments" {
  description = "The GitHub environment each role is tied to, including the seed's bootstrap environment."
  value       = var.github_environments
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
