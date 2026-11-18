# The pipeline's footing in dev: non-secret configuration, committed. The
# shared naming values, and the list of services, are in
# ../platform.tfvars.json.
#
# Every action the pipeline may take is written here, in full, once. A service
# role gets its own read_actions and write_actions; the plan role gets every
# service's read_actions and no write action at all, so the two can never drift
# apart. There is no wildcard action anywhere; where a resource cannot be
# scoped, the pattern it names says so in main.tf.
#
# The read sets are deliberately complete rather than minimal: the AWS provider
# reads the whole of a resource on every refresh, and a missing read action
# costs a failed pipeline run.

github_owner      = "Danny-Cooke"
github_repository = "draftsman-customer-site"

# Two GitHub environments: a pull request can only reach the read-only plan
# role, and only a deploy from main can reach the role that may assume the
# service roles.
github_environments = {
  plan   = "dev-plan"
  deploy = "dev"
}

# This account had no GitHub sign-in provider when this was written.
create_oidc_provider = true

site_state_key      = "site/terraform.tfstate"
bootstrap_state_key = "bootstrap/terraform.tfstate"

# Role chaining, and the session tag the provider sends with it.
deploy_assume_actions = ["sts:AssumeRole", "sts:TagSession"]

iam_service     = "access"
publish_service = "publish"

service_roles = {
  # ------------------------------------------------------------------ storage
  storage = {
    description = "Creates and configures the site bucket. No object actions: publishing is a different role."
    statements = {
      web_bucket = {
        resources = ["web_bucket"]
        # The provider reads every one of these on each refresh of
        # aws_s3_bucket and its configuration resources, whether or not this
        # stack sets them.
        read_actions = [
          "s3:GetAccelerateConfiguration",
          "s3:GetBucketAcl",
          "s3:GetBucketCORS",
          "s3:GetBucketLocation",
          "s3:GetBucketLogging",
          "s3:GetBucketNotification",
          "s3:GetBucketObjectLockConfiguration",
          "s3:GetBucketOwnershipControls",
          "s3:GetBucketPolicy",
          "s3:GetBucketPolicyStatus",
          "s3:GetBucketPublicAccessBlock",
          "s3:GetBucketRequestPayment",
          "s3:GetBucketTagging",
          "s3:GetBucketVersioning",
          "s3:GetBucketWebsite",
          "s3:GetEncryptionConfiguration",
          "s3:GetLifecycleConfiguration",
          "s3:GetReplicationConfiguration",
          "s3:ListBucket",
          "s3:ListBucketVersions",
        ]
        write_actions = [
          "s3:CreateBucket",
          "s3:DeleteBucket",
          "s3:DeleteBucketPolicy",
          "s3:PutBucketOwnershipControls",
          "s3:PutBucketPolicy",
          "s3:PutBucketPublicAccessBlock",
          "s3:PutBucketTagging",
          "s3:PutBucketVersioning",
          "s3:PutEncryptionConfiguration",
          "s3:PutLifecycleConfiguration",
        ]
      }
    }
  }

  # --------------------------------------------------------------------- keys
  keys = {
    description = "Creates the sign-up component's KMS key and its alias."
    statements = {
      account_key = {
        resources = ["account_key"]
        read_actions = [
          "kms:DescribeKey",
          "kms:GetKeyPolicy",
          "kms:GetKeyRotationStatus",
          "kms:ListResourceTags",
        ]
        write_actions = [
          "kms:CancelKeyDeletion",
          "kms:CreateAlias",
          "kms:DeleteAlias",
          "kms:DisableKey",
          "kms:DisableKeyRotation",
          "kms:EnableKey",
          "kms:EnableKeyRotation",
          "kms:PutKeyPolicy",
          "kms:ScheduleKeyDeletion",
          "kms:TagResource",
          "kms:UntagResource",
          "kms:UpdateAlias",
          "kms:UpdateKeyDescription",
        ]
      }
      account_alias = {
        resources     = ["account_alias"]
        read_actions  = []
        write_actions = ["kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias"]
      }
      # CreateKey takes no resource, and the tags it is created with are
      # checked as kms:TagResource on a key that does not exist yet.
      # ListAliases takes no resource either.
      new_keys = {
        resources     = ["unscopable"]
        read_actions  = ["kms:ListAliases"]
        write_actions = ["kms:CreateKey", "kms:TagResource"]
      }
    }
  }

  # --------------------------------------------------------------------- edge
  edge = {
    description = "Creates the distribution, its function and policies, and the web ACL in the edge Region."
    statements = {
      cloudfront_functions = {
        resources = ["cloudfront_functions"]
        read_actions = [
          "cloudfront:DescribeFunction",
          "cloudfront:GetFunction",
        ]
        write_actions = [
          "cloudfront:CreateFunction",
          "cloudfront:DeleteFunction",
          "cloudfront:PublishFunction",
          "cloudfront:TestFunction",
          "cloudfront:UpdateFunction",
        ]
      }
      cloudfront_resources = {
        resources = ["cloudfront_unnamed"]
        read_actions = [
          "cloudfront:GetCachePolicy",
          "cloudfront:GetCachePolicyConfig",
          "cloudfront:GetDistribution",
          "cloudfront:GetDistributionConfig",
          "cloudfront:GetOriginAccessControl",
          "cloudfront:GetOriginAccessControlConfig",
          "cloudfront:GetOriginRequestPolicy",
          "cloudfront:GetOriginRequestPolicyConfig",
          "cloudfront:GetResponseHeadersPolicy",
          "cloudfront:GetResponseHeadersPolicyConfig",
          "cloudfront:ListTagsForResource",
        ]
        write_actions = [
          "cloudfront:CreateDistribution",
          "cloudfront:CreateDistributionWithTags",
          "cloudfront:CreateOriginAccessControl",
          "cloudfront:CreateResponseHeadersPolicy",
          "cloudfront:DeleteDistribution",
          "cloudfront:DeleteOriginAccessControl",
          "cloudfront:DeleteResponseHeadersPolicy",
          "cloudfront:TagResource",
          "cloudfront:UntagResource",
          "cloudfront:UpdateDistribution",
          "cloudfront:UpdateOriginAccessControl",
          "cloudfront:UpdateResponseHeadersPolicy",
        ]
      }
      # CloudFront's list calls and WAF's take no resource.
      cloudfront_listing = {
        resources = ["unscopable"]
        read_actions = [
          "cloudfront:ListCachePolicies",
          "cloudfront:ListDistributions",
          "cloudfront:ListFunctions",
          "cloudfront:ListOriginAccessControls",
          "cloudfront:ListOriginRequestPolicies",
          "cloudfront:ListResponseHeadersPolicies",
        ]
        write_actions = []
      }
      web_acl = {
        resources = ["web_acl"]
        read_actions = [
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:ListTagsForResource",
        ]
        write_actions = [
          "wafv2:AssociateWebACL",
          "wafv2:CreateWebACL",
          "wafv2:DeleteWebACL",
          "wafv2:DisassociateWebACL",
          "wafv2:TagResource",
          "wafv2:UntagResource",
          "wafv2:UpdateWebACL",
        ]
      }
      # Naming a managed rule group in a web ACL needs permission on the group,
      # which is AWS's resource and cannot be narrowed further.
      waf_managed_rule_groups = {
        resources     = ["waf_managed_rule_groups"]
        read_actions  = []
        write_actions = ["wafv2:CreateWebACL", "wafv2:UpdateWebACL"]
      }
      waf_listing = {
        resources = ["unscopable"]
        read_actions = [
          "wafv2:DescribeManagedRuleGroup",
          "wafv2:ListAvailableManagedRuleGroups",
          "wafv2:ListWebACLs",
        ]
        write_actions = []
      }
    }
  }

  # ----------------------------------------------------------------- identity
  identity = {
    description = "Creates the Cognito user pool and the browser's app client."
    statements = {
      user_pools = {
        resources = ["user_pools"]
        read_actions = [
          "cognito-idp:DescribeUserPool",
          "cognito-idp:DescribeUserPoolClient",
          "cognito-idp:GetUserPoolMfaConfig",
          "cognito-idp:ListTagsForResource",
          "cognito-idp:ListUserPoolClients",
        ]
        write_actions = [
          "cognito-idp:CreateUserPoolClient",
          "cognito-idp:DeleteUserPool",
          "cognito-idp:DeleteUserPoolClient",
          "cognito-idp:SetUserPoolMfaConfig",
          "cognito-idp:TagResource",
          "cognito-idp:UntagResource",
          "cognito-idp:UpdateUserPool",
          "cognito-idp:UpdateUserPoolClient",
        ]
      }
      # CreateUserPool takes no resource: the pool's id does not exist yet and
      # carries nothing of its name. The tags it is created with are checked as
      # TagResource on that same non-existent pool.
      new_user_pools = {
        resources     = ["unscopable"]
        read_actions  = ["cognito-idp:ListUserPools"]
        write_actions = ["cognito-idp:CreateUserPool", "cognito-idp:TagResource"]
      }
    }
  }

  # --------------------------------------------------------------------- data
  data = {
    description = "Creates the account table, its backups and its encryption."
    statements = {
      account_table = {
        resources = ["account_table"]
        read_actions = [
          "dynamodb:DescribeContinuousBackups",
          "dynamodb:DescribeKinesisStreamingDestination",
          "dynamodb:DescribeTable",
          "dynamodb:DescribeTableReplicaAutoScaling",
          "dynamodb:DescribeTimeToLive",
          "dynamodb:ListTagsOfResource",
        ]
        write_actions = [
          "dynamodb:CreateTable",
          "dynamodb:DeleteTable",
          "dynamodb:TagResource",
          "dynamodb:UntagResource",
          "dynamodb:UpdateContinuousBackups",
          "dynamodb:UpdateTable",
          "dynamodb:UpdateTimeToLive",
        ]
      }
      # DynamoDB takes a grant on the key in the caller's name when a table is
      # created with a customer-managed key. The key's own policy allows these
      # only when DynamoDB is the one calling, so this grant adds nothing out
      # of band.
      table_key = {
        resources     = ["account_key"]
        read_actions  = ["kms:DescribeKey"]
        write_actions = ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"]
      }
      table_listing = {
        resources     = ["unscopable"]
        read_actions  = ["dynamodb:ListTables"]
        write_actions = []
      }
    }
  }

  # ------------------------------------------------------------------ compute
  compute = {
    description = "Creates the functions, the HTTP API and the log groups, and may pass the function roles to Lambda and nothing else."
    statements = {
      account_functions = {
        resources = ["account_functions"]
        read_actions = [
          "lambda:GetFunction",
          "lambda:GetFunctionCodeSigningConfig",
          "lambda:GetFunctionConcurrency",
          "lambda:GetFunctionConfiguration",
          "lambda:GetFunctionEventInvokeConfig",
          "lambda:GetFunctionRecursionConfig",
          "lambda:GetFunctionUrlConfig",
          "lambda:GetPolicy",
          "lambda:GetRuntimeManagementConfig",
          "lambda:ListTags",
          "lambda:ListVersionsByFunction",
        ]
        write_actions = [
          "lambda:AddPermission",
          "lambda:CreateFunction",
          "lambda:DeleteFunction",
          "lambda:RemovePermission",
          "lambda:TagResource",
          "lambda:UntagResource",
          "lambda:UpdateFunctionCode",
          "lambda:UpdateFunctionConfiguration",
        ]
      }
      account_log_groups = {
        resources = ["account_log_groups"]
        read_actions = [
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:ListTagsForResource",
          "logs:ListTagsLogGroup",
        ]
        write_actions = [
          "logs:AssociateKmsKey",
          "logs:CreateLogGroup",
          "logs:DeleteLogGroup",
          "logs:DisassociateKmsKey",
          "logs:PutRetentionPolicy",
          "logs:TagLogGroup",
          "logs:TagResource",
          "logs:UntagLogGroup",
          "logs:UntagResource",
        ]
      }
      # CloudWatch Logs checks that whoever creates an encrypted log group can
      # see the key it names.
      account_key_for_log_groups = {
        resources    = ["account_key"]
        read_actions = []
        write_actions = [
          "kms:DescribeKey",
        ]
      }
      # API Gateway authorises by request path and method, not by API name, and
      # tags are written as a call on /tags. An HTTP API's id is generated, so
      # /apis/* is as narrow as the service allows. GET is the whole read set.
      http_apis = {
        resources     = ["http_apis"]
        read_actions  = ["apigateway:GET"]
        write_actions = ["apigateway:DELETE", "apigateway:PATCH", "apigateway:POST", "apigateway:PUT"]
      }
      # Giving the API stage a CloudWatch destination makes a log delivery and
      # a resource policy on the log group. Neither call accepts a resource.
      log_delivery = {
        resources = ["unscopable"]
        read_actions = [
          "logs:DescribeResourcePolicies",
          "logs:GetLogDelivery",
          "logs:ListLogDeliveries",
        ]
        write_actions = [
          "logs:CreateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:PutResourcePolicy",
          "logs:UpdateLogDelivery",
        ]
      }
      function_listing = {
        resources     = ["unscopable"]
        read_actions  = ["lambda:ListFunctions"]
        write_actions = []
      }
      # It may hand a function role to Lambda and to nothing else, and only a
      # role of the sign-up component.
      pass_function_roles = {
        resources     = ["account_function_roles"]
        read_actions  = []
        write_actions = ["iam:PassRole"]
        conditions = [
          {
            test     = "StringEquals"
            variable = "iam:PassedToService"
            values   = ["lambda.amazonaws.com"]
          },
        ]
      }
    }
  }

  # ------------------------------------------------------------------- access
  access = {
    description = "Creates the sign-up functions' own roles and inline policies, and only with the permissions boundary."
    statements = {
      account_function_roles = {
        resources = ["account_function_roles"]
        read_actions = [
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole",
          "iam:ListRolePolicies",
          "iam:ListRoleTags",
        ]
        write_actions = [
          "iam:AttachRolePolicy",
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:DeleteRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PutRolePermissionsBoundary",
          "iam:PutRolePolicy",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:UpdateRole",
          "iam:UpdateRoleDescription",
        ]
      }
      role_listing = {
        resources     = ["unscopable"]
        read_actions  = ["iam:ListRoles"]
        write_actions = []
      }
    }
  }

  # ------------------------------------------------------------------ publish
  publish = {
    description = "Puts the built site in the bucket and clears the cache. Assumed by the workflow's publish step, never by Terraform."
    statements = {
      web_bucket = {
        resources     = ["web_bucket"]
        read_actions  = ["s3:GetBucketLocation", "s3:ListBucket"]
        write_actions = []
      }
      web_bucket_objects = {
        resources     = ["web_bucket_objects"]
        read_actions  = ["s3:GetObject"]
        write_actions = ["s3:DeleteObject", "s3:PutObject"]
      }
      invalidations = {
        resources     = ["cloudfront_distributions"]
        read_actions  = ["cloudfront:GetInvalidation"]
        write_actions = ["cloudfront:CreateInvalidation"]
      }
    }
  }
}

# The IAM role may only create or change a function role while that role
# carries the boundary. iam:PermissionsBoundary is the request's boundary on a
# create, and the target role's boundary on a change.
access_boundary_guarded_actions = [
  "iam:AttachRolePolicy",
  "iam:CreateRole",
  "iam:PutRolePermissionsBoundary",
  "iam:PutRolePolicy",
]

access_never_allowed_actions = ["iam:DeleteRolePermissionsBoundary"]

# Denied on the boundary policy itself and on every pipeline role and policy,
# so the role that writes IAM cannot widen its own ceiling or anyone else's.
access_protected_write_actions = [
  "iam:AttachRolePolicy",
  "iam:CreatePolicy",
  "iam:CreatePolicyVersion",
  "iam:CreateRole",
  "iam:DeletePolicy",
  "iam:DeletePolicyVersion",
  "iam:DeleteRole",
  "iam:DeleteRolePermissionsBoundary",
  "iam:DeleteRolePolicy",
  "iam:DetachRolePolicy",
  "iam:PutRolePermissionsBoundary",
  "iam:PutRolePolicy",
  "iam:SetDefaultPolicyVersion",
  "iam:TagPolicy",
  "iam:TagRole",
  "iam:UntagPolicy",
  "iam:UntagRole",
  "iam:UpdateAssumeRolePolicy",
  "iam:UpdateRole",
  "iam:UpdateRoleDescription",
]

# The ceiling on a sign-up function: the account table, the account key through
# DynamoDB, and its own log stream. Nothing a function is given can exceed it.
function_boundary = {
  dynamodb_actions = [
    "dynamodb:BatchGetItem",
    "dynamodb:BatchWriteItem",
    "dynamodb:DeleteItem",
    "dynamodb:DescribeTable",
    "dynamodb:GetItem",
    "dynamodb:PutItem",
    "dynamodb:Query",
    "dynamodb:UpdateItem",
  ]
  kms_actions = [
    "kms:Decrypt",
    "kms:DescribeKey",
    "kms:GenerateDataKey",
  ]
  logs_actions = [
    "logs:CreateLogStream",
    "logs:PutLogEvents",
  ]
}
