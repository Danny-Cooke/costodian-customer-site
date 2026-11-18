provider "aws" {
  region = var.platform.region

  default_tags {
    tags = local.default_tags
  }
}

