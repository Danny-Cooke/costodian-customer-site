# Provider versions are the one thing that cannot be a variable:
# required_providers is evaluated before variables exist. They are pinned here
# and in the committed .terraform.lock.hcl.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.90"
    }
    # Zips the already-built function package; it does not build it.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}
