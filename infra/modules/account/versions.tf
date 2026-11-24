# The product's version catalogue.
#
# One SSM parameter holding a JSON list of the versions that exist. Terraform
# writes the list it starts with and then leaves the value alone: a git tag
# created in the source repository raises an EventBridge event, the rule below
# matches it, and the function it invokes appends the tag to the list. Nothing
# in the catalogue is a secret and nothing in it is personal.
#
# The rule matches one repository in this account and Region, one detail type,
# and only a tag being created or moved. A branch, a commit, or a tag in another
# repository does not match, so the only way into the catalogue is a tag on the
# product.

locals {
  versions_parameter_arn = "arn:${var.platform.partition}:ssm:${var.platform.region}:${var.platform.account_id}:parameter${var.versions_parameter_name}"

  version_source_repository_arn = "arn:${var.platform.partition}:codecommit:${var.platform.region}:${var.platform.account_id}:${var.version_source_repository}"
}

resource "aws_ssm_parameter" "versions" {
  provider = aws.parameters

  name        = var.versions_parameter_name
  description = "The versions of ${var.product_name} that exist, appended to as tags are created"
  type        = var.parameter_type
  value       = jsonencode(var.initial_versions)

  tags = merge(local.tags, { Name = var.versions_parameter_name })

  # The catalogue grows by itself, so Terraform sets it up and never writes it
  # again: an apply must not put the list back to the versions it started with.
  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_cloudwatch_event_rule" "versions" {
  provider = aws.compute

  name        = module.naming.names["versions"]
  description = "A version tag created in ${var.version_source_repository} adds that version to the catalogue"

  # The shape is EventBridge's; every value in it is declared in tfvars. A
  # repository is named by ARN under resources, so the rule cannot match
  # another repository's tags.
  event_pattern = jsonencode({
    source        = [var.version_source_event.source]
    "detail-type" = [var.version_source_event.detail_type]
    resources     = [local.version_source_repository_arn]
    detail = {
      event         = var.version_source_event.events
      referenceType = var.version_source_event.reference_types
    }
  })

  tags = merge(local.tags, { Name = module.naming.names["versions"] })
}

resource "aws_cloudwatch_event_target" "versions" {
  provider = aws.compute

  rule      = aws_cloudwatch_event_rule.versions.name
  target_id = module.naming.names[var.version_catalogue_function]
  arn       = aws_lambda_function.this[var.version_catalogue_function].arn

  lifecycle {
    precondition {
      condition     = contains(keys(var.functions), var.version_catalogue_function)
      error_message = "account: version_catalogue_function must name one of var.functions; ${var.version_catalogue_function} is not one of ${jsonencode(keys(var.functions))}."
    }
    precondition {
      condition     = length(try(var.functions[var.version_catalogue_function].versions_actions, [])) > 0
      error_message = "account: the function the version rule invokes must have versions_actions, or it cannot write the catalogue it is invoked to write."
    }
  }
}

# Only this rule may invoke it, not EventBridge in general.
resource "aws_lambda_permission" "versions" {
  provider = aws.compute

  statement_id  = module.naming.names["versions"]
  action        = var.lambda_invoke_action
  function_name = aws_lambda_function.this[var.version_catalogue_function].function_name
  principal     = var.events_service_principal
  source_arn    = aws_cloudwatch_event_rule.versions.arn
}
