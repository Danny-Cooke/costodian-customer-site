data "aws_caller_identity" "current" {}

locals {
  # The project naming slot, derived from the one declaration of the product's
  # name: lower-cased, anything outside a-z0-9 folded to a hyphen, then what
  # this repository builds: a product named "Example Co" with the suffix
  # "site" gives the project slot "example-co-site".
  project = trim(join("-", [
    replace(lower(var.product_name), "/[^a-z0-9]+/", "-"),
    var.project_suffix,
  ]), "-")

  # Declared once here and applied by every provider's default_tags.
  default_tags = {
    Product     = var.product_name
    Project     = local.project
    Environment = var.platform.environment
    Repository  = var.repository
    ManagedBy   = var.managed_by
    Owner       = var.owner
  }

  # An SSM parameter name is a path, so it cannot come from the naming module,
  # which composes and validates hyphenated names. It is composed here instead,
  # from the same slots in the same order, and this is the one place it is
  # written: the site stack creates the parameters under it and passes it to the
  # account module, and the bootstrap stack scopes the roles that may read and
  # write them. The postfix slot is not in it: the customer number is the last
  # segment, and a slot after it would read as part of the number.
  customer_parameter_path = "/${join("/", compact([
    var.platform.prefix,
    local.project,
    var.platform.environment,
    var.customer_parameter_segment,
  ]))}"

  # The product's version catalogue, beside the customer labels and composed the
  # same way. One parameter, not a path of them: the catalogue is one JSON list.
  versions_parameter_name = "/${join("/", compact([
    var.platform.prefix,
    local.project,
    var.platform.environment,
    var.versions_parameter_segment,
  ]))}"

  platform = merge(var.platform, {
    project    = local.project
    account_id = data.aws_caller_identity.current.account_id
    # S3 bucket names are globally unique, so they carry the account id after
    # the postfix slot. This is not a further naming slot.
    unique_suffix = data.aws_caller_identity.current.account_id
    tags          = local.default_tags
  })
}
