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

  platform = merge(var.platform, {
    project    = local.project
    account_id = data.aws_caller_identity.current.account_id
    # S3 bucket names are globally unique, so they carry the account id after
    # the postfix slot. This is not a further naming slot.
    unique_suffix = data.aws_caller_identity.current.account_id
    tags          = local.default_tags
  })
}
