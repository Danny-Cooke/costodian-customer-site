# The front door: the static site in a private bucket, CloudFront with origin
# access control in front of it, a viewer-request function that maps page paths
# to their index document, security headers on every response, and WAF in
# us-east-1. The site runs on the CloudFront domain; there is no certificate or
# DNS here.
#
# Every resource names the provider it is created with, so each one is created
# by the role for its own service and nothing silently inherits a broader
# identity:
#
#   aws.storage   the bucket and everything configuring it
#   aws.cdn       CloudFront, in the stack's own Region
#   aws.edge      WAF, which for CloudFront scope must be in us-east-1

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.storage, aws.cdn, aws.edge]
    }
  }
}

module "naming" {
  source = "../naming"

  platform  = var.platform
  component = var.component
  types = {
    (var.component) = "bucket"
    cdn             = "distribution"
    oac             = "origin_access_control"
    waf             = "web_acl"
    rewrite         = "function"
    headers         = "response_headers_policy"
  }
  globally_unique = [var.component]
}

locals {
  tags = { Component = var.component }

  bucket_name = module.naming.s3_names[var.component]
  origin_id   = local.bucket_name

  # The origin id only has to be unique within the distribution, and the host
  # already is, so it is not a name the naming module has to compose.
  api_origins = var.api_origin == null ? [] : [var.api_origin]

  rewrite_code = templatefile("${path.module}/functions/rewrite.js.tftpl", {
    index_document = var.index_document
  })
}

data "aws_cloudfront_cache_policy" "default" {
  provider = aws.cdn

  name = var.cache_policy_name
}

# Looked up only when there is an API behaviour to attach them to.
data "aws_cloudfront_cache_policy" "api" {
  provider = aws.cdn

  count = var.api_origin == null ? 0 : 1

  name = var.api_cache_policy_name
}

data "aws_cloudfront_origin_request_policy" "api" {
  provider = aws.cdn

  count = var.api_origin == null ? 0 : 1

  name = var.api_origin_request_policy_name
}

# ------------------------------------------------------------------- bucket

resource "aws_s3_bucket" "web" {
  provider = aws.storage

  bucket = local.bucket_name

  # Off everywhere but the destroy path: the bucket is versioned, so it cannot
  # be deleted until every version is gone and Terraform will not empty a
  # bucket it did not fill unless it is told to.
  force_destroy = var.force_destroy

  tags = merge(local.tags, { Name = local.bucket_name })
}

resource "aws_s3_bucket_versioning" "web" {
  provider = aws.storage

  bucket = aws_s3_bucket.web.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "web" {
  provider = aws.storage

  bucket = aws_s3_bucket.web.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_upload_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.web]
}

# The site is public content and holds no customer data: SSE-S3 keeps
# CloudFront's origin access control working without granting the CloudFront
# service principal use of a customer-managed key.
resource "aws_s3_bucket_server_side_encryption_configuration" "web" {
  provider = aws.storage

  bucket = aws_s3_bucket.web.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "web" {
  provider = aws.storage

  bucket = aws_s3_bucket.web.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "web" {
  provider = aws.storage

  bucket = aws_s3_bucket.web.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "web" {
  provider = aws.storage

  statement {
    sid       = "ReadByThisDistributionOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.web.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }

  statement {
    sid     = "DenyUnencryptedTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.web.arn,
      "${aws_s3_bucket.web.arn}/*",
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

resource "aws_s3_bucket_policy" "web" {
  provider = aws.storage

  bucket = aws_s3_bucket.web.id
  policy = data.aws_iam_policy_document.web.json

  depends_on = [aws_s3_bucket_public_access_block.web]
}

# ---------------------------------------------------------------------- WAF

resource "aws_wafv2_web_acl" "this" {
  provider = aws.edge

  name  = module.naming.names["waf"]
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = { for group in var.waf_managed_rule_groups : group.name => group }

    content {
      name     = rule.value.name
      priority = rule.value.priority

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = var.waf_managed_rule_vendor
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${module.naming.base}-${rule.value.name}"
        sampled_requests_enabled   = var.waf_sampled_requests_enabled
      }
    }
  }

  rule {
    name     = "${module.naming.names["waf"]}-rate"
    priority = var.waf_rate_rule_priority

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${module.naming.base}-rate"
      sampled_requests_enabled   = var.waf_sampled_requests_enabled
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = module.naming.names["waf"]
    sampled_requests_enabled   = var.waf_sampled_requests_enabled
  }

  tags = merge(local.tags, { Name = module.naming.names["waf"] })
}

# -------------------------------------------------------------- CloudFront

resource "aws_cloudfront_origin_access_control" "web" {
  provider = aws.cdn

  name                              = module.naming.names["oac"]
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_function" "rewrite" {
  provider = aws.cdn

  name    = module.naming.names["rewrite"]
  runtime = var.function_runtime
  comment = "Maps a page path to its index document"
  publish = true
  code    = local.rewrite_code
}

resource "aws_cloudfront_response_headers_policy" "security" {
  provider = aws.cdn

  name    = module.naming.names["headers"]
  comment = "Security headers for every response"

  security_headers_config {
    content_security_policy {
      content_security_policy = var.content_security_policy
      override                = true
    }

    content_type_options {
      override = true
    }

    frame_options {
      frame_option = var.frame_option
      override     = true
    }

    referrer_policy {
      referrer_policy = var.referrer_policy
      override        = true
    }

    strict_transport_security {
      access_control_max_age_sec = var.hsts_max_age_seconds
      include_subdomains         = var.hsts_include_subdomains
      preload                    = var.hsts_preload
      override                   = true
    }
  }

  custom_headers_config {
    items {
      header   = "Permissions-Policy"
      value    = var.permissions_policy
      override = true
    }
  }
}

resource "aws_cloudfront_distribution" "this" {
  provider = aws.cdn

  enabled             = true
  is_ipv6_enabled     = true
  comment             = module.naming.names["cdn"]
  default_root_object = var.index_document
  price_class         = var.price_class
  web_acl_id          = aws_wafv2_web_acl.this.arn

  origin {
    domain_name              = aws_s3_bucket.web.bucket_regional_domain_name
    origin_id                = local.origin_id
    origin_access_control_id = aws_cloudfront_origin_access_control.web.id
  }

  dynamic "origin" {
    for_each = local.api_origins
    iterator = api

    content {
      domain_name = api.value.domain_name
      origin_id   = api.value.domain_name

      custom_origin_config {
        http_port              = var.api_origin_http_port
        https_port             = var.api_origin_https_port
        origin_protocol_policy = var.api_origin_protocol_policy
        origin_ssl_protocols   = var.api_origin_ssl_protocols
      }
    }
  }

  default_cache_behavior {
    target_origin_id           = local.origin_id
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = var.allowed_methods
    cached_methods             = var.cached_methods
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.default.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.rewrite.arn
    }
  }

  # API paths go to the API, unchanged and uncached, with no viewer-request
  # function: the route keys already carry the path prefix.
  dynamic "ordered_cache_behavior" {
    for_each = local.api_origins
    iterator = api

    content {
      path_pattern               = api.value.path_pattern
      target_origin_id           = api.value.domain_name
      viewer_protocol_policy     = var.api_viewer_protocol_policy
      allowed_methods            = var.api_allowed_methods
      cached_methods             = var.api_cached_methods
      compress                   = true
      cache_policy_id            = data.aws_cloudfront_cache_policy.api[0].id
      origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.api[0].id
      response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
    }
  }

  # The bucket answers 403 for a missing object, because the distribution may
  # not list it. Both become the site's own not-found page.
  #
  # This mapping is distribution-wide and so covers the API behaviour too. It
  # is left as it is because the API is not designed to answer either code: a
  # call with no or a bad token is answered 401 by the JWT authorizer, and the
  # browser only calls routes that exist. If that stops being true, the API
  # paths need their own error handling rather than the site's HTML page.
  dynamic "custom_error_response" {
    for_each = toset(var.not_found_error_codes)

    content {
      error_code            = custom_error_response.value
      response_code         = var.not_found_response_code
      response_page_path    = var.not_found_document
      error_caching_min_ttl = var.error_caching_min_ttl_seconds
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = var.geo_restriction_type
      locations        = var.geo_restriction_locations
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = merge(local.tags, { Name = module.naming.names["cdn"] })
}
