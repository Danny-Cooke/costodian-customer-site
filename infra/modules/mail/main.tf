# Mail for the site's own domain: sending as it, and receiving at it.
#
# Sending: the domain is an SES identity, signed with DKIM, with its own
# return path and a DMARC policy, so that mail from an address at the domain is
# accepted as genuine. Nothing here sends: the sign-in pool is told to use the
# identity by the account module.
#
# Receiving: mail to any address at the domain is accepted by SES in this
# Region, scanned, kept encrypted in a private bucket, and its content passed
# to a topic. Whoever is subscribed to the topic gets it in their own mailbox.
# That is what makes an address at the domain usable as the contact address of
# an AWS account: the mail has somewhere to arrive.
#
# Every resource names the provider it is created with:
#
#   aws.email          the identity and the rules for received mail
#   aws.dns            the records in the domain's hosted zone
#   aws.keys           the key received mail is encrypted with
#   aws.storage        the bucket it is kept in
#   aws.notifications  the topic that passes it on

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.email, aws.dns, aws.keys, aws.storage, aws.notifications]
    }
  }
}

module "naming" {
  source = "../naming"

  platform  = var.platform
  component = var.component
  types = {
    (var.component) = "bucket"
    key             = "kms_key"
    alias           = "kms_alias"
    received        = "sns_topic"
    rules           = "receipt_rule_set"
    keep            = "receipt_rule"
  }
  globally_unique = [var.component]
}

locals {
  tags = { Component = var.component }

  bucket_name      = module.naming.s3_names[var.component]
  bucket_arn       = "arn:${var.platform.partition}:s3:::${local.bucket_name}"
  mail_from_domain = "${var.mail_from_host}.${var.domain.name}"
  rule_set_arn     = "arn:${var.platform.partition}:ses:${var.platform.region}:${var.platform.account_id}:receipt-rule-set/${module.naming.names["rules"]}"
  rule_arn         = "${local.rule_set_arn}:receipt-rule/${module.naming.names["keep"]}"

  # Every plain record this module writes, in one map: name, type and values.
  # The signing records are separate because their names are not known until
  # the identity exists.
  records = {
    receiving = {
      name    = var.domain.name
      type    = "MX"
      records = ["${var.mx_priority} ${format(var.inbound_endpoint, var.platform.region)}"]
    }
    return_path_mx = {
      name    = local.mail_from_domain
      type    = "MX"
      records = ["${var.mx_priority} ${format(var.feedback_endpoint, var.platform.region)}"]
    }
    return_path_spf = {
      name    = local.mail_from_domain
      type    = "TXT"
      records = [var.spf_record]
    }
    dmarc = {
      name    = "${var.dmarc_host}.${var.domain.name}"
      type    = "TXT"
      records = [var.dmarc_record]
    }
  }
}

# ------------------------------------------------------------------ sending

resource "aws_sesv2_email_identity" "domain" {
  provider = aws.email

  email_identity = var.domain.name

  tags = merge(local.tags, { Name = var.domain.name })
}

resource "aws_sesv2_email_identity_mail_from_attributes" "domain" {
  provider = aws.email

  email_identity         = aws_sesv2_email_identity.domain.email_identity
  mail_from_domain       = local.mail_from_domain
  behavior_on_mx_failure = var.behavior_on_mx_failure

  depends_on = [aws_route53_record.plain]
}

# SES gives three signing names once the identity exists.
resource "aws_route53_record" "signing" {
  count    = var.dkim_token_count
  provider = aws.dns

  zone_id = var.domain.zone_id
  name    = "${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}.${var.dkim_host}.${var.domain.name}"
  type    = "CNAME"
  ttl     = var.record_ttl_seconds
  records = ["${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}.${var.dkim_target}"]
}

resource "aws_route53_record" "plain" {
  for_each = local.records
  provider = aws.dns

  zone_id = var.domain.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = var.record_ttl_seconds
  records = each.value.records
}

# ------------------------------------------------------------------ the key

data "aws_iam_policy_document" "key" {
  provider = aws.keys

  # A key policy's resource is always "*", meaning the key it is attached to.
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

  # SES encrypts what it stores and what it publishes, and SNS decrypts to
  # deliver. Only for this account's mail.
  statement {
    sid       = "UsedByMailServicesForThisAccount"
    effect    = "Allow"
    actions   = var.key_service_actions
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = var.key_service_principals
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.platform.account_id]
    }
  }
}

resource "aws_kms_key" "mail" {
  provider = aws.keys

  description             = "Mail received at ${var.domain.name}"
  enable_key_rotation     = var.key_rotation_enabled
  deletion_window_in_days = var.key_deletion_window_days
  policy                  = data.aws_iam_policy_document.key.json

  tags = merge(local.tags, { Name = module.naming.names["key"] })
}

resource "aws_kms_alias" "mail" {
  provider = aws.keys

  name          = "${var.key_alias_prefix}${module.naming.names["alias"]}"
  target_key_id = aws_kms_key.mail.key_id
}

# --------------------------------------------------------------- the bucket

resource "aws_s3_bucket" "mail" {
  provider = aws.storage

  bucket        = local.bucket_name
  force_destroy = var.force_destroy

  tags = merge(local.tags, { Name = local.bucket_name })
}

resource "aws_s3_bucket_ownership_controls" "mail" {
  provider = aws.storage

  bucket = aws_s3_bucket.mail.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "mail" {
  provider = aws.storage

  bucket                  = aws_s3_bucket.mail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "mail" {
  provider = aws.storage

  bucket = aws_s3_bucket.mail.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "mail" {
  provider = aws.storage

  bucket = aws_s3_bucket.mail.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.mail.arn
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "mail" {
  provider = aws.storage

  bucket = aws_s3_bucket.mail.id

  rule {
    id     = "expire"
    status = "Enabled"

    filter {}

    expiration {
      days = var.retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_upload_days
    }
  }
}

data "aws_iam_policy_document" "bucket" {
  provider = aws.storage

  # SES may put a message in, and only for this account's own rule.
  statement {
    sid       = "ReceivedMailIsPutBySes"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${local.bucket_arn}/${var.object_key_prefix}*"]

    principals {
      type        = "Service"
      identifiers = [var.ses_service_principal]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.platform.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.rule_arn]
    }
  }

  statement {
    sid       = "TlsOnly"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [local.bucket_arn, "${local.bucket_arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "mail" {
  provider = aws.storage

  bucket = aws_s3_bucket.mail.id
  policy = data.aws_iam_policy_document.bucket.json

  depends_on = [aws_s3_bucket_public_access_block.mail]
}

# ---------------------------------------------------------------- the topic

resource "aws_sns_topic" "received" {
  provider = aws.notifications

  name              = module.naming.names["received"]
  kms_master_key_id = aws_kms_key.mail.arn

  tags = merge(local.tags, { Name = module.naming.names["received"] })
}

data "aws_iam_policy_document" "topic" {
  provider = aws.notifications

  statement {
    sid       = "ReceivedMailIsPublishedBySes"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.received.arn]

    principals {
      type        = "Service"
      identifiers = [var.ses_service_principal]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.platform.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "received" {
  provider = aws.notifications

  arn    = aws_sns_topic.received.arn
  policy = data.aws_iam_policy_document.topic.json
}

# The mailbox received mail is passed on to. It is given to the pipeline, not
# written in the repository, and whoever owns it confirms it once by email.
resource "aws_sns_topic_subscription" "forward" {
  # Whether there is one is not a secret; who it is, is.
  count    = nonsensitive(var.forward_to == "") ? 0 : 1
  provider = aws.notifications

  topic_arn = aws_sns_topic.received.arn
  protocol  = "email"
  endpoint  = var.forward_to
}

# ---------------------------------------------------------------- receiving

resource "aws_ses_receipt_rule_set" "this" {
  provider = aws.email

  rule_set_name = module.naming.names["rules"]
}

# A Region has one active rule set, and this is it.
resource "aws_ses_active_receipt_rule_set" "this" {
  provider = aws.email

  rule_set_name = aws_ses_receipt_rule_set.this.rule_set_name
}

# Any address at the domain: scanned, refused without TLS, kept, passed on.
resource "aws_ses_receipt_rule" "keep" {
  provider = aws.email

  name          = module.naming.names["keep"]
  rule_set_name = aws_ses_receipt_rule_set.this.rule_set_name
  recipients    = [var.domain.name]
  enabled       = true
  scan_enabled  = true
  tls_policy    = var.receive_tls_policy

  s3_action {
    bucket_name       = aws_s3_bucket.mail.id
    object_key_prefix = var.object_key_prefix
    position          = 1
  }

  sns_action {
    topic_arn = aws_sns_topic.received.arn
    encoding  = var.topic_encoding
    position  = 2
  }

  # SES tests both destinations when the rule is made.
  depends_on = [
    aws_s3_bucket_policy.mail,
    aws_s3_bucket_server_side_encryption_configuration.mail,
    aws_sns_topic_policy.received,
  ]
}
