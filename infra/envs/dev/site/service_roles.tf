# The roles this stack's providers assume, and the ceiling the function roles
# carry. Both are composed from the naming module with the same inputs the
# bootstrap stack composed them from, so neither ARN is written down twice and
# a rename cannot leave the two stacks disagreeing.

module "ci_naming" {
  source = "../../../modules/naming"

  platform  = local.platform
  component = var.components.ci
  types = merge(
    { boundary = "policy" },
    { for service in var.services : service => "role" },
  )
}

locals {
  iam_arn = "arn:${local.platform.partition}:iam::${local.platform.account_id}"

  # unvalidated_names, not names: a provider's assume_role is evaluated before
  # the plan walk and so cannot depend on a resource attribute. The names are
  # validated by this module instance all the same.
  service_role_arns = {
    for service in var.services :
    service => "${local.iam_arn}:role/${module.ci_naming.unvalidated_names[service]}"
  }

  function_permissions_boundary_arn = "${local.iam_arn}:policy/${module.ci_naming.unvalidated_names["boundary"]}"

  # Who to blame in CloudTrail for a chained session.
  assume_session_name = module.ci_naming.base
}
