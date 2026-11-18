output "names" {
  description = "Logical key to composed, validated name."
  # Read through the validating resource so that every consumer depends on the
  # preconditions. `input` (not `output`) so the names are known at plan time.
  value = terraform_data.validated.input.names
}

output "s3_names" {
  description = "Logical key to composed, validated, globally unique S3 bucket name."
  value       = terraform_data.validated.input.s3_names
}

output "unvalidated_names" {
  description = <<-EOT
    The same composed names, read without the dependency on the validating
    resource. For the one place that cannot wait for a resource: a provider's
    assume_role, which Terraform evaluates before the plan walk and which
    therefore cannot depend on a resource attribute. The names are still
    validated by this module instance; only the read path differs. Use `names`
    everywhere else.
  EOT
  value       = local.names
}

output "base" {
  description = "The <prefix>-<project>-<env>-<component> part, for metric and alias prefixes."
  value       = local.base
}
