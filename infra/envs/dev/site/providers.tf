# One provider per AWS service, each assuming the role for that service alone,
# so no single identity in this stack can build the whole site. The role ARNs
# are composed in service_roles.tf from the same naming inputs the bootstrap
# stack used; none of them is written here.
#
# On a pull request the plan job runs with assume_service_roles = false and
# every provider uses the job's own credentials, which are the read-only plan
# role. On a deploy it is true and each provider chains from the deploy role
# into its own service role.
#
# The default provider never assumes anything: it exists for the caller
# identity and partition lookups in shared_locals.tf.

locals {
  # One list per service: the role to assume, or nothing at all.
  assumed = {
    for service, arn in local.service_role_arns :
    service => var.assume_service_roles ? [arn] : []
  }
}

provider "aws" {
  region = var.platform.region

  default_tags {
    tags = local.default_tags
  }
}

provider "aws" {
  alias  = "storage"
  region = var.platform.region

  dynamic "assume_role" {
    for_each = local.assumed["storage"]

    content {
      role_arn     = assume_role.value
      session_name = local.assume_session_name
    }
  }

  default_tags {
    tags = local.default_tags
  }
}

provider "aws" {
  alias  = "keys"
  region = var.platform.region

  dynamic "assume_role" {
    for_each = local.assumed["keys"]

    content {
      role_arn     = assume_role.value
      session_name = local.assume_session_name
    }
  }

  default_tags {
    tags = local.default_tags
  }
}

# CloudFront is global but its API is called in the stack's own Region.
provider "aws" {
  alias  = "cdn"
  region = var.platform.region

  dynamic "assume_role" {
    for_each = local.assumed["edge"]

    content {
      role_arn     = assume_role.value
      session_name = local.assume_session_name
    }
  }

  default_tags {
    tags = local.default_tags
  }
}

# us-east-1 only for what CloudFront requires to live there (the WAF web ACL).
# The same role as the distribution: they are one change.
provider "aws" {
  alias  = "edge"
  region = var.platform.edge_region

  dynamic "assume_role" {
    for_each = local.assumed["edge"]

    content {
      role_arn     = assume_role.value
      session_name = local.assume_session_name
    }
  }

  default_tags {
    tags = local.default_tags
  }
}

provider "aws" {
  alias  = "identity"
  region = var.platform.region

  dynamic "assume_role" {
    for_each = local.assumed["identity"]

    content {
      role_arn     = assume_role.value
      session_name = local.assume_session_name
    }
  }

  default_tags {
    tags = local.default_tags
  }
}

provider "aws" {
  alias  = "data"
  region = var.platform.region

  dynamic "assume_role" {
    for_each = local.assumed["data"]

    content {
      role_arn     = assume_role.value
      session_name = local.assume_session_name
    }
  }

  default_tags {
    tags = local.default_tags
  }
}

provider "aws" {
  alias  = "parameters"
  region = var.platform.region

  dynamic "assume_role" {
    for_each = local.assumed["parameters"]

    content {
      role_arn     = assume_role.value
      session_name = local.assume_session_name
    }
  }

  default_tags {
    tags = local.default_tags
  }
}

provider "aws" {
  alias  = "compute"
  region = var.platform.region

  dynamic "assume_role" {
    for_each = local.assumed["compute"]

    content {
      role_arn     = assume_role.value
      session_name = local.assume_session_name
    }
  }

  default_tags {
    tags = local.default_tags
  }
}

provider "aws" {
  alias  = "access"
  region = var.platform.region

  dynamic "assume_role" {
    for_each = local.assumed["access"]

    content {
      role_arn     = assume_role.value
      session_name = local.assume_session_name
    }
  }

  default_tags {
    tags = local.default_tags
  }
}
