# One customer, one table, one key.
#
# A customer is a firm that has signed up, known by a sequential number written
# with a fixed number of digits: 0001, 0002. Each number has a DynamoDB table,
# a KMS key of its own and a small label kept as an SSM parameter. Nothing is
# created when a firm signs up: the tables are made in advance, as a pool, so
# signing up is a firm taking a number that is already there.
#
# The pool tops itself up. It is the numbers 1 to (highest claimed + spares),
# so every pipeline run leaves the same number of spares behind the highest
# customer. It cannot shrink: a number is only ever dropped by being named in
# var.removed_customer_numbers, and a label that cannot be read counts as
# claimed. The one way a customer's table is destroyed is deliberate, in two
# steps, and is written down in runbooks/deploy.md.
#
# Nothing here holds an identity document: a table holds the firm's own account
# record, and a label holds a number, a status and the firm's trading name.

module "customer_naming" {
  source = "../naming"

  platform  = var.platform
  component = var.customer_component

  # One table, one key and one alias per number in the pool, plus the same
  # three for the sentinel number, which is never in the pool and exists only
  # so that the templates below are composed by this module rather than typed
  # out with the prefix in them.
  types = merge(
    {
      "data-role"   = "role"
      "data-access" = "policy"

      (local.customer_sentinel)          = "dynamodb_table"
      "${local.customer_sentinel}-key"   = "kms_key"
      "${local.customer_sentinel}-alias" = "kms_alias"
    },
    { for number in local.customer_numbers : number => "dynamodb_table" },
    { for number in local.customer_numbers : "${number}-key" => "kms_key" },
    { for number in local.customer_numbers : "${number}-alias" => "kms_alias" },
  )
}

# ------------------------------------------------------------ the pool's size

# Every label under the path, read at plan time. The data source returns empty
# lists when there is nothing there, so the first apply makes numbers 1 to
# var.customer_spares.
data "aws_ssm_parameters_by_path" "customers" {
  provider = aws.parameters

  path = var.customer_parameter_path
}

locals {
  customer_tags = { Component = var.customer_component }

  customer_number_format  = "%0${var.customer_number_digits}d"
  customer_number_pattern = "^[0-9]{${var.customer_number_digits}}$"

  # Zero, which format() writes as 0000. The pool starts at 1, so the sentinel
  # is never a customer and never collides with one.
  customer_sentinel = format(local.customer_number_format, 0)

  # The last segment of each parameter's name is the customer number. The data
  # source returns names and values as two lists in the same order.
  #
  # The values are marked sensitive because a parameter can hold a secret;
  # these cannot. A label is a customer number, a status word and the firm's
  # own trading name, which the firm typed into a public sign-up form, and a
  # for_each key may not be sensitive, so they are unwrapped here.
  customer_parameter_numbers = [
    for name in data.aws_ssm_parameters_by_path.customers.names :
    element(split("/", name), length(split("/", name)) - 1)
  ]
  customer_parameter_values = nonsensitive(data.aws_ssm_parameters_by_path.customers.values)

  # Anything under the path that is not a customer number is not a customer, so
  # it is left out rather than counted.
  customer_labels = {
    for index, number in local.customer_parameter_numbers :
    number => local.customer_parameter_values[index]
    if length(regexall(local.customer_number_pattern, number)) > 0
  }

  # Claimed is the safe reading: a label that is not JSON, or that holds no
  # status, or that holds any status but the free one, counts as claimed. A
  # broken label can therefore never shrink the pool and take a live customer's
  # table with it.
  claimed_customer_numbers = [
    for number, label in local.customer_labels : number
    if try(jsondecode(label)[var.customer_parameter_fields.status], "") != var.customer_free_status
  ]

  highest_claimed_customer = length(local.claimed_customer_numbers) == 0 ? 0 : max([
    for number in local.claimed_customer_numbers : tonumber(number)
  ]...)

  # The whole of the pool's size, and the reason it is monotonic: it depends on
  # the highest claimed number, which only ever rises, and a fixed number of
  # spares.
  customer_pool_size = local.highest_claimed_customer + var.customer_spares

  customer_numbers = [
    for index in range(1, local.customer_pool_size + 1) :
    format(local.customer_number_format, index)
    if !contains(var.removed_customer_numbers, format(local.customer_number_format, index))
  ]

  # A number that has been claimed but is not in the pool would mean a live
  # customer's table was about to be destroyed. It cannot happen by the
  # arithmetic above; it is checked anyway, because the cost of being wrong is
  # a customer's data.
  dropped_customer_numbers = setsubtract(
    toset(local.claimed_customer_numbers),
    toset(concat(local.customer_numbers, var.removed_customer_numbers)),
  )

  customer_number_ceiling = pow(10, var.customer_number_digits) - 1

  # A claimed number cannot be destroyed in one apply: its table is protected
  # until an apply has turned that off for it.
  removed_while_protected = setsubtract(
    setintersection(toset(var.removed_customer_numbers), toset(local.claimed_customer_numbers)),
    toset(var.unprotected_customer_numbers),
  )
}

# ------------------------------------------------------- names and templates

locals {
  customer_attribute = "${var.custom_attribute_prefix}${var.customer_attribute_name}"

  client_read_attributes = concat(var.client_read_attributes, [local.customer_attribute])

  # One name per kind, with the sentinel number swapped for the placeholder the
  # API replaces. Composed from the naming module, so the prefix, project,
  # environment and component are not written a second time here.
  customer_table_name_template = replace(
    module.customer_naming.names[local.customer_sentinel],
    local.customer_sentinel,
    var.customer_number_placeholder,
  )
  customer_key_alias_template = "${var.key_alias_prefix}${replace(
    module.customer_naming.names["${local.customer_sentinel}-alias"],
    local.customer_sentinel,
    var.customer_number_placeholder,
  )}"
  customer_table_arn_template = "arn:${var.platform.partition}:dynamodb:${var.platform.region}:${var.platform.account_id}:table/${local.customer_table_name_template}"

  # The same two with the number replaced by a wildcard: what a policy that
  # covers every customer names. A policy that covers one customer is the
  # session policy a function passes when it takes credentials, built from the
  # templates above by the API.
  customer_table_arn_pattern = replace(local.customer_table_arn_template, var.customer_number_placeholder, "*")
  customer_key_alias_pattern = replace(local.customer_key_alias_template, var.customer_number_placeholder, "*")

  # A KMS key id is generated, so a key cannot be named before it exists. What
  # narrows the statement is the alias condition and kms:ViaService, not the
  # resource.
  any_key_in_this_account = "arn:${var.platform.partition}:kms:${var.platform.region}:${var.platform.account_id}:key/*"

  customer_parameter_path_arn    = "arn:${var.platform.partition}:ssm:${var.platform.region}:${var.platform.account_id}:parameter${var.customer_parameter_path}"
  customer_parameter_arn_pattern = "${local.customer_parameter_path_arn}/*"

  # A function's label actions, split by what they are taken on: listing the
  # pool is a call on the path, everything else is a call on one parameter
  # under it.
  function_parameter_path_actions = {
    for name, fn in var.functions :
    name => sort(tolist(setintersection(toset(fn.parameter_actions), toset(var.customer_parameter_path_actions))))
  }
  function_parameter_actions = {
    for name, fn in var.functions :
    name => sort(tolist(setsubtract(toset(fn.parameter_actions), toset(var.customer_parameter_path_actions))))
  }
}

# Validation on a resource so that it is evaluated and fails at plan time.
resource "terraform_data" "customers" {
  input = {
    numbers = local.customer_numbers
    claimed = sort(local.claimed_customer_numbers)
  }

  lifecycle {
    precondition {
      condition     = length(local.dropped_customer_numbers) == 0
      error_message = "account: customer numbers ${jsonencode(local.dropped_customer_numbers)} are claimed but are not in the pool. The pool must never drop a claimed number; name it in removed_customer_numbers if its table really is to be destroyed."
    }
    precondition {
      condition     = local.customer_pool_size <= local.customer_number_ceiling
      error_message = "account: a pool of ${local.customer_pool_size} does not fit in ${var.customer_number_digits} digits (${local.customer_number_ceiling} customers). Widening customer_number_digits renames every customer's table, which replaces it; plan that, do not change it here."
    }
    precondition {
      condition     = !contains(local.customer_numbers, local.customer_sentinel)
      error_message = "account: ${local.customer_sentinel} is the sentinel the name templates are composed from and cannot be a customer."
    }
    # A person who could write their own customer number could point themselves
    # at another firm's table.
    precondition {
      condition     = !contains(var.client_write_attributes, local.customer_attribute)
      error_message = "account: ${local.customer_attribute} must not be in client_write_attributes: only the API may set a person's customer number."
    }
    # Removing a customer is two applies: the first takes the protection off
    # that one table, the second destroys it. A number named in
    # removed_customer_numbers while its table is still protected would fail
    # half way through the apply, so it fails the plan instead.
    precondition {
      condition     = length(local.removed_while_protected) == 0
      error_message = "account: customer numbers ${jsonencode(local.removed_while_protected)} are named in removed_customer_numbers but are still protected. Name them in unprotected_customer_numbers and apply, then apply again with them removed."
    }
  }
}

# ------------------------------------------------------- one key per customer

# The same policy for every customer's key: the account root may administer it,
# and a principal of this account may use it when, and only when, DynamoDB is
# the one calling. The key policy does not name a table, so one document serves
# the whole pool.
data "aws_iam_policy_document" "customer_key" {
  provider = aws.keys

  # A key policy's resource is always "*", meaning the key the policy is
  # attached to. It cannot name the key, which does not exist yet.
  statement {
    sid       = "AdministeredByThisAccount"
    effect    = "Allow"
    actions   = var.key_admin_actions
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${var.platform.partition}:iam::${var.platform.account_id}:root"]
    }
  }

  # Not "anyone": the two conditions together mean a principal of this account,
  # and only when DynamoDB is making the call on its behalf.
  statement {
    sid       = "UsedThroughDynamoDbByThisAccount"
    effect    = "Allow"
    actions   = var.key_dynamodb_actions
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [format(var.dynamodb_via_service, var.platform.region)]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [var.platform.account_id]
    }
  }
}

resource "aws_kms_key" "customer" {
  provider = aws.keys

  for_each = toset(local.customer_numbers)

  description             = "Customer ${each.key} of ${module.customer_naming.base}"
  enable_key_rotation     = var.key_rotation_enabled
  deletion_window_in_days = var.key_deletion_window_days
  policy                  = data.aws_iam_policy_document.customer_key.json

  tags = merge(local.customer_tags, { Name = module.customer_naming.names["${each.key}-key"] })
}

# The alias is what a policy can name, and what the session policy a function
# passes matches on: a key id is generated, an alias is composed.
resource "aws_kms_alias" "customer" {
  provider = aws.keys

  for_each = toset(local.customer_numbers)

  name          = "${var.key_alias_prefix}${module.customer_naming.names["${each.key}-alias"]}"
  target_key_id = aws_kms_key.customer[each.key].key_id
}

# ----------------------------------------------------- one table per customer

resource "aws_dynamodb_table" "customer" {
  provider = aws.data

  for_each = toset(local.customer_numbers)

  name         = module.customer_naming.names[each.key]
  billing_mode = var.table_billing_mode
  hash_key     = var.table_hash_key
  range_key    = var.table_range_key

  # On for every number but the ones being taken out of service, which is the
  # first of the two applies that remove a customer.
  deletion_protection_enabled = (contains(var.unprotected_customer_numbers, each.key)
    ? false
    : var.customer_table_deletion_protection
  )

  attribute {
    name = var.table_hash_key
    type = var.table_key_type
  }

  attribute {
    name = var.table_range_key
    type = var.table_key_type
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.customer[each.key].arn
  }

  point_in_time_recovery {
    enabled = var.table_point_in_time_recovery
  }

  tags = merge(local.customer_tags, { Name = module.customer_naming.names[each.key] })
}

# -------------------------------------------------- one label per customer

# What the API needs to know about a customer without reading its table: which
# number it is and how far it has got. Created free; the API rewrites the value
# as the firm signs up and works through its set-up, so the value is ignored
# here after the first apply and Terraform never puts a live label back to
# free.
resource "aws_ssm_parameter" "customer" {
  provider = aws.parameters

  for_each = toset(local.customer_numbers)

  name        = "${var.customer_parameter_path}/${each.key}"
  description = "Customer ${each.key} of ${module.customer_naming.base}: which number, and how far it has got"
  type        = var.parameter_type

  value = jsonencode({
    (var.customer_parameter_fields.number) = each.key
    (var.customer_parameter_fields.status) = var.customer_free_status
  })

  tags = merge(local.customer_tags, { Name = "${var.customer_parameter_path}/${each.key}" })

  lifecycle {
    ignore_changes = [value]
  }
}

# ------------------------------------------------------ the customer data role

# The one way to a customer's table. It is deliberately broad: it reaches every
# customer's table and every customer's key, because a role per customer would
# be a role per customer. What scopes a request is the session policy the
# function passes to sts:AssumeRole, which names one customer's table ARN and
# one customer's key alias, built from the templates the function is given. The
# role is the ceiling; the session policy is the grant.
#
# It is trusted by this component's function roles and by nothing else, and it
# carries the same permissions boundary they do, so it cannot hold more than a
# function may ever hold.
data "aws_iam_policy_document" "customer_data_trust" {
  provider = aws.access

  # Only the functions that reach a customer's table at all. A function with no
  # data_actions is not named here and is not allowed to assume this role, so
  # neither side of the trust mentions it.
  statement {
    sid     = "AssumedByTheseFunctionsOnly"
    effect  = "Allow"
    actions = var.data_role_assume_actions

    principals {
      type = "AWS"
      identifiers = [
        for name, fn in var.functions : aws_iam_role.function[name].arn
        if length(fn.data_actions) > 0
      ]
    }
  }
}

data "aws_iam_policy_document" "customer_data" {
  provider = aws.access

  statement {
    sid       = "EveryCustomerTable"
    effect    = "Allow"
    actions   = var.customer_data_table_actions
    resources = [local.customer_table_arn_pattern]
  }

  # A key id is generated, so the resource cannot be narrowed; the two
  # conditions are what narrow it. kms:ResourceAliases restricts the statement
  # to keys aliased as a customer key, and kms:ViaService to calls DynamoDB is
  # making, so these credentials cannot decrypt anything out of band.
  statement {
    sid       = "EveryCustomerKeyThroughDynamoDbOnly"
    effect    = "Allow"
    actions   = var.customer_data_key_actions
    resources = [local.any_key_in_this_account]

    condition {
      test     = "ForAnyValue:StringLike"
      variable = "kms:ResourceAliases"
      values   = [local.customer_key_alias_pattern]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [format(var.dynamodb_via_service, var.platform.region)]
    }
  }
}

resource "aws_iam_role" "customer_data" {
  provider = aws.access

  name               = module.customer_naming.names["data-role"]
  description        = "Reaches one customer's table of ${module.customer_naming.base}, narrowed per request by the session policy the function passes"
  assume_role_policy = data.aws_iam_policy_document.customer_data_trust.json

  permissions_boundary = var.function_permissions_boundary_arn

  tags = merge(local.customer_tags, { Name = module.customer_naming.names["data-role"] })
}

resource "aws_iam_role_policy" "customer_data" {
  provider = aws.access

  name   = module.customer_naming.names["data-access"]
  role   = aws_iam_role.customer_data.id
  policy = data.aws_iam_policy_document.customer_data.json
}
