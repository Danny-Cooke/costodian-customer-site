# What the pipeline needs before it can run: the Terraform state bucket and the
# roles the workflow assumes with no stored keys.
#
# It is applied by the Bootstrap workflow, as the seed's bootstrap role. The
# GitHub sign-in provider and that one role are the seed: a CloudFormation
# stack applied once by a person (infra/seed/seed.yaml, scripts/seed.sh). This
# stack only reads the provider, and never names, creates or deletes the role
# that applies it.
#
# There is no role here that can do everything. The workflow signs in to one of
# two entry roles, and neither of them can change an AWS resource:
#
#   plan    assumed from the dev-plan GitHub environment. Reads the site state
#           and holds every service's read actions and nothing else, so a pull
#           request can plan and can change nothing.
#   deploy  assumed from the dev GitHub environment. Reads and writes the site
#           state object and its lock, and may assume the service roles. That
#           is all it holds.
#
# Under deploy, one role per AWS service, trusted by deploy alone and reached by
# role chaining. The site stack's providers each assume the one for their
# service, so the identity that creates a bucket cannot write IAM and the
# identity that writes IAM cannot read the table.
#
# Applied by scripts/bootstrap.sh; see runbooks/bootstrap.md.

module "naming" {
  source = "../../../modules/naming"

  platform  = local.platform
  component = var.components.ci
  types = merge(
    {
      state         = "bucket"
      plan          = "role"
      deploy        = "role"
      plan-access   = "policy"
      deploy-access = "policy"
      boundary      = "policy"

      # The seed's three names. This stack composes them so that nothing is
      # named twice, and manages none of them: scripts/seed.sh reads them from
      # here to build the CloudFormation stack, and scripts/names.sh reads the
      # role to tell the workflow what to assume.
      github           = "openid_connect_provider"
      bootstrap        = "role"
      bootstrap-access = "policy"
      seed             = "cloudformation_stack"
    },
    # One role per service, its inline policy, and the read-only policy the
    # plan role carries for that same service.
    { for service in var.services : service => "role" },
    { for service in var.services : "${service}-access" => "policy" },
    { for service in var.services : "plan-${service}" => "policy" },
  )
  globally_unique = ["state"]
}

# Only the base of these components' names is needed here, to scope each role
# to the resources of the component it looks after.
module "web_naming" {
  source = "../../../modules/naming"

  platform  = local.platform
  component = var.components.web
  types     = {}
}

module "account_naming" {
  source = "../../../modules/naming"

  platform  = local.platform
  component = var.components.account
  types     = {}
}

module "customer_naming" {
  source = "../../../modules/naming"

  platform  = local.platform
  component = var.components.customer
  types     = {}
}

locals {
  tags = { Component = var.components.ci }

  state_bucket_name = module.naming.s3_names["state"]
  state_bucket_arn  = "arn:${local.platform.partition}:s3:::${local.state_bucket_name}"
  site_state_arn    = "${local.state_bucket_arn}/${var.site_state_key}"
  site_lock_arn     = "${local.site_state_arn}${var.state_lock_suffix}"

  oidc_host         = trimprefix(var.github_oidc_url, "https://")
  oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn
  repository_path   = "${var.github_owner}/${local.repository}"

  # How GitHub names this repository in the tokens it issues. A repository set
  # to immutable subjects is named by owner and repository id as well as by
  # name, so a rename cannot hand its roles to another repository. The
  # bootstrap script reads the prefix from GitHub and passes it in.
  subject_prefix = var.github_subject_prefix != "" ? var.github_subject_prefix : "repo:${local.repository_path}"

  # One entry role per subject. The bootstrap environment is deliberately not
  # here: its role is the seed's, trusted by the seed for that one environment,
  # so this stack cannot widen what applies it.
  subjects = {
    plan   = "${local.subject_prefix}:environment:${var.github_environments.plan}"
    deploy = "${local.subject_prefix}:environment:${var.github_environments.deploy}"
  }

  # The subject the seed trusts, composed here so that the shape of a subject
  # is written once.
  seed_subject = "${local.subject_prefix}:environment:${var.github_environments.bootstrap}"

  # Everything each component creates carries its own prefix.
  ci_prefix       = module.naming.base
  web_prefix      = module.web_naming.base
  account_prefix  = module.account_naming.base
  customer_prefix = module.customer_naming.base

  arn         = "arn:${local.platform.partition}"
  account_id  = local.platform.account_id
  region      = local.platform.region
  edge_region = local.platform.edge_region

  # A KMS key id is generated by KMS, so no key can be named before it exists.
  # Written once and named by the pattern below.
  any_kms_key = "${local.arn}:kms:${local.region}:${local.account_id}:key/*"

  # The resource patterns a statement in terraform.tfvars may name. Composed
  # here because they need the account id, the Region and the components' name
  # prefixes; scoped to this project's own names wherever the service allows
  # it. Where it does not, the comment says why.
  resource_arns = {
    # Calls that AWS accepts with no resource at all. Only ever used for
    # listing and for the create calls named below, never for a change to a
    # resource that could have been named.
    unscopable = ["*"]

    web_bucket         = ["${local.arn}:s3:::${local.web_prefix}-*"]
    web_bucket_objects = ["${local.arn}:s3:::${local.web_prefix}-*/*"]

    # A KMS key id is generated, so the key cannot be named before it exists.
    # One pattern therefore covers every key in this account and Region, the
    # sign-up component's and every customer's alike; each key's own policy
    # allows its use only through DynamoDB, and the sign-up key also through
    # CloudWatch Logs for its own log groups. The aliases can be named, so they
    # are, one pattern per component.
    any_key         = [local.any_kms_key]
    account_alias   = ["${local.arn}:kms:${local.region}:${local.account_id}:alias/${local.account_prefix}-*"]
    customer_alias  = ["${local.arn}:kms:${local.region}:${local.account_id}:alias/${local.customer_prefix}-*"]
    customer_table  = ["${local.arn}:dynamodb:${local.region}:${local.account_id}:table/${local.customer_prefix}-*"]
    customer_roles  = ["${local.arn}:iam::${local.account_id}:role/${local.customer_prefix}-*"]
    customer_labels = ["${local.arn}:ssm:${local.region}:${local.account_id}:parameter${local.customer_parameter_path}/*"]

    # Listing the labels is a call on the path itself, not on a parameter under
    # it, so the two are separate patterns.
    customer_label_path = ["${local.arn}:ssm:${local.region}:${local.account_id}:parameter${local.customer_parameter_path}"]

    # The version catalogue is one parameter, named in full.
    versions_parameter = ["${local.arn}:ssm:${local.region}:${local.account_id}:parameter${local.versions_parameter_name}"]

    # The rule that turns a version tag into a catalogue entry. A rule can be
    # named, so it is.
    account_event_rules = ["${local.arn}:events:${local.region}:${local.account_id}:rule/${local.account_prefix}-*"]

    # CloudFront names a function; it gives a distribution, an origin access
    # control and a policy an id of its own choosing, so those cannot be named.
    cloudfront_functions = ["${local.arn}:cloudfront::${local.account_id}:function/${local.web_prefix}-*"]
    cloudfront_unnamed = [
      "${local.arn}:cloudfront::${local.account_id}:distribution/*",
      "${local.arn}:cloudfront::${local.account_id}:origin-access-control/*",
      "${local.arn}:cloudfront::${local.account_id}:response-headers-policy/*",
      "${local.arn}:cloudfront::${local.account_id}:cache-policy/*",
      "${local.arn}:cloudfront::${local.account_id}:origin-request-policy/*",
    ]
    cloudfront_distributions = ["${local.arn}:cloudfront::${local.account_id}:distribution/*"]

    web_acl = ["${local.arn}:wafv2:${local.edge_region}:${local.account_id}:global/webacl/${local.web_prefix}-*/*"]
    # Referencing a managed rule group needs permission on the group itself,
    # which is AWS's resource, not ours.
    waf_managed_rule_groups = [
      "${local.arn}:wafv2:${local.edge_region}:${local.account_id}:global/managedruleset/*/*",
      "${local.arn}:wafv2:${local.edge_region}:aws:managedruleset/*/*",
    ]

    # A certificate's id is generated by ACM, so it cannot be named. CloudFront
    # only takes a certificate from the edge Region, so that is the only Region
    # granted.
    certificates = ["${local.arn}:acm:${local.edge_region}:${local.account_id}:certificate/*"]

    # The one hosted zone of the site's domain, named by its id, and nothing in
    # any other zone. A change's id is generated, so reading one cannot be
    # narrowed.
    dns_zone    = ["${local.arn}:route53:::hostedzone/${var.site_domain.zone_id}"]
    dns_changes = ["${local.arn}:route53:::change/*"]

    # The sending identity is the domain itself, so it is named in full. A
    # configuration set can be named, so it carries the sign-up component's
    # prefix.
    email_identity           = ["${local.arn}:ses:${local.region}:${local.account_id}:identity/${var.site_domain.name}"]
    email_configuration_sets = ["${local.arn}:ses:${local.region}:${local.account_id}:configuration-set/${local.account_prefix}-*"]

    # The role Cognito makes for itself the first time a pool is told to send
    # through SES. AWS fixes its name and path.
    cognito_email_service_role = ["${local.arn}:iam::${local.account_id}:role/aws-service-role/email.cognito-idp.amazonaws.com/AWSServiceRoleForAmazonCognitoIdpEmailService"]

    # A user pool id is generated by Cognito (eu-west-2_xxxxxxxxx) and carries
    # nothing of the pool's name, so it cannot be scoped by name.
    user_pools = ["${local.arn}:cognito-idp:${local.region}:${local.account_id}:userpool/*"]

    account_table = ["${local.arn}:dynamodb:${local.region}:${local.account_id}:table/${local.account_prefix}-*"]

    account_functions = ["${local.arn}:lambda:${local.region}:${local.account_id}:function:${local.account_prefix}-*"]
    account_log_groups = [
      "${local.arn}:logs:${local.region}:${local.account_id}:log-group:${local.account_prefix}-*",
      "${local.arn}:logs:${local.region}:${local.account_id}:log-group:${local.account_prefix}-*:*",
    ]
    account_function_roles = ["${local.arn}:iam::${local.account_id}:role/${local.account_prefix}-*"]

    # API Gateway authorises by path, not by API name: an HTTP API's id is
    # generated, so /apis/* is as narrow as the service allows.
    http_apis = [
      "${local.arn}:apigateway:${local.region}::/apis",
      "${local.arn}:apigateway:${local.region}::/apis/*",
      "${local.arn}:apigateway:${local.region}::/tags/*",
    ]

    # The pipeline's own roles, policies and ceiling. Named only to be denied.
    ci_principals = [
      "${local.arn}:iam::${local.account_id}:role/${local.ci_prefix}-*",
      "${local.arn}:iam::${local.account_id}:policy/${local.ci_prefix}-*",
    ]
  }

  # service -> statement key -> the statement with its ARNs resolved.
  service_statements = {
    for service, spec in var.service_roles : service => {
      for key, statement in spec.statements : key => merge(statement, {
        arns = flatten([for pattern in statement.resources : lookup(local.resource_arns, pattern, [])])
        sid  = "${title(service)}${replace(title(replace(key, "_", " ")), " ", "")}"
      })
    }
  }

  # A statement that names a pattern this stack does not compose would quietly
  # grant nothing, so it fails the plan instead.
  unknown_patterns = distinct(flatten([
    for service, spec in var.service_roles : [
      for key, statement in spec.statements : [
        for pattern in statement.resources : "${service}.${key}.${pattern}"
        if !contains(keys(local.resource_arns), pattern)
      ]
    ]
  ]))

  missing_services = setsubtract(toset(var.services), toset(keys(var.service_roles)))
  extra_services   = setsubtract(toset(keys(var.service_roles)), toset(var.services))

  # The seed grants its bootstrap role every IAM write under the ci prefix
  # except on its own ARN, so this stack must never manage a role of that name:
  # it could not change it, and the run would fail half way.
  seed_role_name     = module.naming.unvalidated_names["bootstrap"]
  managed_role_names = [for key in concat(keys(local.subjects), var.services) : module.naming.names[key]]
}

# Everything the scripts need, in one expression they read with
# `terraform console`. Console evaluates the configuration without reading a
# data source, so nothing here may depend on one: there is no account id and no
# ARN in it, and scripts/lib/stack.sh composes those from the partition, the
# names below and the account id it is given. That is the only place an ARN is
# put together outside Terraform.
locals {
  script_names = {
    project         = local.project
    repository_path = local.repository_path
    environment     = var.platform.environment

    # The effective prefix: what scripts/seed.sh was told by GitHub, or the
    # plain form when GitHub has nothing to say. It becomes the
    # OIDC_SUBJECT_PREFIX repository variable, which the Bootstrap workflow
    # passes back in so that every role trusts the same subject.
    subject_prefix = local.subject_prefix

    aws_region = var.platform.region
    partition  = var.platform.partition

    # Without the account id, which S3's global namespace adds and which only
    # the caller knows: the scripts append it.
    state_bucket_base   = module.naming.unvalidated_names["state"]
    bootstrap_state_key = var.bootstrap_state_key
    site_state_key      = var.site_state_key

    role_names = {
      bootstrap = local.seed_role_name
      plan      = module.naming.unvalidated_names["plan"]
      deploy    = module.naming.unvalidated_names["deploy"]
      publish   = module.naming.unvalidated_names[var.publish_service]
    }

    environments = var.github_environments

    # What scripts/seed.sh gives the CloudFormation template. Nothing
    # project-specific is written in that template; all of this arrives as a
    # parameter.
    seed = {
      stack_name               = module.naming.unvalidated_names["seed"]
      role_name                = local.seed_role_name
      policy_name              = module.naming.unvalidated_names["bootstrap-access"]
      role_max_session_seconds = var.role_max_session_seconds
      ci_name_prefix           = "${module.naming.base}-"
      subject                  = local.seed_subject
      # A string, because it reaches CloudFormation as a parameter whose
      # allowed values are "true" and "false".
      create_oidc_provider = tostring(var.create_oidc_provider)
      oidc_name            = module.naming.unvalidated_names["github"]
      oidc_url             = var.github_oidc_url
      oidc_host            = local.oidc_host
      oidc_audience        = var.github_oidc_audience
      oidc_thumbprints     = join(",", var.github_oidc_thumbprints)
      state_lock_suffix    = var.state_lock_suffix
      tags = merge(local.default_tags, local.tags, {
        ManagedBy = var.seed_managed_by
      })
    }
  }
}

# Validation on a resource so that it is evaluated and fails at plan time.
resource "terraform_data" "checked" {
  input = {
    services         = var.services
    state_bucket     = local.state_bucket_name
    unknown_patterns = local.unknown_patterns
  }

  lifecycle {
    precondition {
      condition     = length(local.missing_services) == 0 && length(local.extra_services) == 0
      error_message = "bootstrap: service_roles must hold exactly one entry per service in platform.tfvars.json; missing ${jsonencode(local.missing_services)}, unexpected ${jsonencode(local.extra_services)}."
    }
    precondition {
      condition     = length(local.unknown_patterns) == 0
      error_message = "bootstrap: statements name resource patterns that main.tf does not compose ${jsonencode(local.unknown_patterns)}."
    }
    precondition {
      condition     = contains(var.services, var.iam_service) && contains(var.services, var.publish_service)
      error_message = "bootstrap: iam_service and publish_service must each name one of var.services."
    }
    precondition {
      condition     = !contains(local.managed_role_names, local.seed_role_name)
      error_message = "bootstrap: ${local.seed_role_name} is the seed's role; no service or entry role may compose that name."
    }
  }
}

# ------------------------------------------------------------ GitHub sign-in

# Created by the seed, which an account holds one of per issuer and which
# nothing in the pipeline may change. Read here for the trust policies below.
data "aws_iam_openid_connect_provider" "github" {
  url = var.github_oidc_url
}

# ---------------------------------------------------- the two entry roles

data "aws_iam_policy_document" "entry_trust" {
  for_each = local.subjects

  statement {
    sid     = "GitHubActionsFromOneEnvironmentOfOneRepository"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = [var.github_oidc_audience]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = [each.value]
    }
  }
}

resource "aws_iam_role" "entry" {
  for_each = local.subjects

  name                 = module.naming.names[each.key]
  description          = "GitHub Actions ${each.key} role for ${local.repository_path}"
  assume_role_policy   = data.aws_iam_policy_document.entry_trust[each.key].json
  max_session_duration = var.role_max_session_seconds

  tags = merge(local.tags, { Name = module.naming.names[each.key] })
}

# ------------------------------------------------------- the service roles

# One trust policy, shared by every service role: the deploy role and nothing
# else. GitHub cannot reach these directly; it has to come through deploy.
data "aws_iam_policy_document" "service_trust" {
  statement {
    sid     = "AssumedByTheDeployRoleOnly"
    effect  = "Allow"
    actions = var.deploy_assume_actions

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.entry["deploy"].arn]
    }
  }
}

resource "aws_iam_role" "service" {
  for_each = var.service_roles

  name                 = module.naming.names[each.key]
  description          = each.value.description
  assume_role_policy   = data.aws_iam_policy_document.service_trust.json
  max_session_duration = var.role_max_session_seconds

  tags = merge(local.tags, { Name = module.naming.names[each.key] })
}

# What each service role may do: its own read and write actions, on its own
# resources, generated from the one map in terraform.tfvars.
data "aws_iam_policy_document" "service" {
  for_each = var.service_roles

  dynamic "statement" {
    for_each = {
      for key, statement in local.service_statements[each.key] : key => statement
      if length(statement.read_actions) + length(statement.write_actions) > 0
    }

    content {
      sid       = statement.value.sid
      effect    = "Allow"
      actions   = concat(statement.value.read_actions, statement.value.write_actions)
      resources = statement.value.arns

      dynamic "condition" {
        for_each = statement.value.conditions

        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

# ------------------------------------------- the ceiling on a function's role

# The most any sign-up function may ever hold, whatever policy is attached to
# its role. Created here, by a person, so the pipeline's IAM role cannot widen
# it.
data "aws_iam_policy_document" "boundary" {
  # Every customer's table, and the one every firm shared before each had its
  # own. One statement, because the action set is the same and only the
  # resources differ.
  statement {
    sid     = "TheseTablesAndNothingElse"
    effect  = "Allow"
    actions = var.function_boundary.dynamodb_actions
    resources = concat(
      local.resource_arns.account_table,
      local.resource_arns.customer_table,
    )
  }

  statement {
    sid       = "TheseKeysAndNothingElse"
    effect    = "Allow"
    actions   = var.function_boundary.kms_actions
    resources = local.resource_arns.any_key
  }

  statement {
    sid       = "ItsOwnLogsAndNothingElse"
    effect    = "Allow"
    actions   = var.function_boundary.logs_actions
    resources = local.resource_arns.account_log_groups
  }

  # Managing the firm's members and which customer a person belongs to, and
  # nothing that changes the pool itself. A user pool id is generated by Cognito
  # and carries nothing of the pool's name, so the ceiling is every pool in this
  # account and Region; the function's own policy names the one pool it may
  # touch.
  statement {
    sid       = "MembersOfAPoolAndNothingElse"
    effect    = "Allow"
    actions   = var.function_boundary.cognito_actions
    resources = local.resource_arns.user_pools
  }

  # Taking credentials for one customer's table. The role this names is the
  # customer data role, which is itself under the customer component's prefix
  # and itself carries this boundary.
  statement {
    sid       = "CustomerDataCredentialsAndNothingElse"
    effect    = "Allow"
    actions   = var.function_boundary.sts_actions
    resources = local.resource_arns.customer_roles
  }

  # The customer labels: which number a customer is and how far it has got. The
  # path itself is a separate statement because listing is a call on the path.
  # The customer labels and the version catalogue: the same three calls on
  # either, so one statement with both sets of resources.
  statement {
    sid     = "TheseParametersAndNothingElse"
    effect  = "Allow"
    actions = var.function_boundary.ssm_actions
    resources = concat(
      local.resource_arns.customer_labels,
      local.resource_arns.versions_parameter,
    )
  }

  statement {
    sid       = "ListingTheCustomerLabelsAndNothingElse"
    effect    = "Allow"
    actions   = var.function_boundary.ssm_path_actions
    resources = local.resource_arns.customer_label_path
  }
}

resource "aws_iam_policy" "boundary" {
  name = module.naming.names["boundary"]
  # A managed policy's description cannot be changed once it is made: a new
  # wording replaces the policy, and a boundary that roles carry cannot be
  # deleted. So this text stays as first written, though the boundary now
  # covers the customer data role as well as the function roles.
  description = "Permissions boundary every ${local.account_prefix} function role must carry"
  policy      = data.aws_iam_policy_document.boundary.json

  tags = merge(local.tags, { Name = module.naming.names["boundary"] })
}

# The guard rails on the one role that may write IAM. They are denies, so they
# hold whatever its generated allow statements say.
data "aws_iam_policy_document" "access_guard_rails" {
  statement {
    sid    = "NoRoleWithoutThePermissionsBoundary"
    effect = "Deny"
    # Every role this pipeline may write: a function's, and the customer data
    # role the functions assume.
    actions = var.access_boundary_guarded_actions
    resources = concat(
      local.resource_arns.account_function_roles,
      local.resource_arns.customer_roles,
    )

    condition {
      test     = "StringNotEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.boundary.arn]
    }
  }

  # A deny on everything, which is the safe direction for a wildcard: there is
  # no resource on which taking the boundary off a role is acceptable.
  statement {
    sid       = "NeverTakeAPermissionsBoundaryOff"
    effect    = "Deny"
    actions   = var.access_never_allowed_actions
    resources = local.resource_arns.unscopable
  }

  statement {
    sid       = "NeverTouchTheCeilingOrThePipelinesOwnRoles"
    effect    = "Deny"
    actions   = var.access_protected_write_actions
    resources = concat([aws_iam_policy.boundary.arn], local.resource_arns.ci_principals)
  }
}

data "aws_iam_policy_document" "access" {
  source_policy_documents = [
    data.aws_iam_policy_document.service[var.iam_service].json,
    data.aws_iam_policy_document.access_guard_rails.json,
  ]
}

resource "aws_iam_role_policy" "service" {
  for_each = var.service_roles

  name = module.naming.names["${each.key}-access"]
  role = aws_iam_role.service[each.key].id
  policy = (each.key == var.iam_service
    ? data.aws_iam_policy_document.access.json
    : data.aws_iam_policy_document.service[each.key].json
  )
}

# --------------------------------------------------------------------- state

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket_name

  # Off everywhere but the destroy path. prevent_destroy takes no variable, so
  # it stays on and the destroy path takes the bucket out of state and deletes
  # it directly; this is here for an operator who has lifted prevent_destroy.
  force_destroy = var.state_bucket_force_destroy

  tags = merge(local.tags, { Name = local.state_bucket_name })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid     = "DenyUnencryptedTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# ---------------------------------------------------- what plan may do

# The site state, and the lock the S3 backend writes beside it while planning.
data "aws_iam_policy_document" "plan_state" {
  statement {
    sid       = "FindTheSiteState"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]
  }

  statement {
    sid       = "ReadTheSiteState"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = [local.site_state_arn]
  }

  statement {
    sid       = "HoldTheStateLockWhilePlanning"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [local.site_lock_arn]
  }
}

resource "aws_iam_role_policy" "plan_state" {
  name   = module.naming.names["plan-access"]
  role   = aws_iam_role.entry["plan"].id
  policy = data.aws_iam_policy_document.plan_state.json
}

# Every service's read actions, from the same lists the service roles are built
# from, so the plan role cannot drift from what apply does. One managed policy
# per service rather than more inline policy: all the read actions together are
# near IAM's 10,240-character ceiling on a role's inline policy, while a
# managed policy is counted on its own.
data "aws_iam_policy_document" "plan_service" {
  for_each = local.plan_statements

  dynamic "statement" {
    for_each = each.value

    content {
      sid       = statement.value.sid
      effect    = "Allow"
      actions   = statement.value.read_actions
      resources = statement.value.arns

      dynamic "condition" {
        for_each = statement.value.conditions

        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

locals {
  plan_statements = {
    for service, statements in local.service_statements :
    service => { for key, statement in statements : key => statement if length(statement.read_actions) > 0 }
    if length([for key, statement in statements : key if length(statement.read_actions) > 0]) > 0
  }
}

resource "aws_iam_policy" "plan_service" {
  for_each = local.plan_statements

  name        = module.naming.names["plan-${each.key}"]
  description = "What the plan role may read of the ${each.key} service"
  policy      = data.aws_iam_policy_document.plan_service[each.key].json

  tags = merge(local.tags, { Name = module.naming.names["plan-${each.key}"] })
}

resource "aws_iam_role_policy_attachment" "plan_service" {
  for_each = local.plan_statements

  role       = aws_iam_role.entry["plan"].name
  policy_arn = aws_iam_policy.plan_service[each.key].arn
}

# -------------------------------------------------- what deploy may do

# The whole of the deploy role: the state object, its lock, and the right to
# become one of the service roles. It can change nothing itself.
data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "FindTheSiteState"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]
  }

  statement {
    sid       = "ReadAndWriteTheSiteState"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = [local.site_state_arn]
  }

  statement {
    sid       = "HoldTheStateLockWhileApplying"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [local.site_lock_arn]
  }

  statement {
    sid       = "BecomeAServiceRole"
    effect    = "Allow"
    actions   = var.deploy_assume_actions
    resources = [for service in var.services : aws_iam_role.service[service].arn]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = module.naming.names["deploy-access"]
  role   = aws_iam_role.entry["deploy"].id
  policy = data.aws_iam_policy_document.deploy.json
}
