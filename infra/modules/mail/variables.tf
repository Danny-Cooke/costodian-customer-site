variable "platform" {
  description = "The platform object: the slots and values every module shares."
  type = object({
    prefix        = string
    project       = string
    environment   = string
    postfix       = string
    region        = string
    edge_region   = string
    account_id    = string
    partition     = string
    unique_suffix = string
    tags          = map(string)
  })
}

variable "component" {
  description = "The bounded context for these names."
  type        = string
}

variable "domain" {
  description = "The domain mail is sent as and received at, and the id of the Route 53 hosted zone that holds it."
  type = object({
    name    = string
    zone_id = string
  })
}

variable "forward_to" {
  description = "The mailbox received mail is passed on to. Empty passes it on to nobody: it is still kept in the bucket. Given to the pipeline, never written in the repository."
  type        = string
  sensitive   = true
  default     = ""
}

variable "dmarc_record" {
  description = "The domain's DMARC policy, as the record's value."
  type        = string
}

variable "spf_record" {
  description = "Who may send with the return path, as the record's value."
  type        = string
}

variable "retention_days" {
  description = "Days a received message is kept in the bucket."
  type        = number
}

variable "key_admin_actions" {
  description = "What this account may do to administer the mail key. Listed in full: a key policy here holds no wildcard."
  type        = list(string)
}

variable "key_service_actions" {
  description = "What the mail services may do with the key: encrypt what is stored and published, decrypt to deliver."
  type        = list(string)
  default     = ["kms:Decrypt", "kms:GenerateDataKey"]
}

variable "key_service_principals" {
  description = "The services that handle received mail."
  type        = list(string)
  default     = ["ses.amazonaws.com", "sns.amazonaws.com"]
}

variable "ses_service_principal" {
  description = "The service that receives mail."
  type        = string
  default     = "ses.amazonaws.com"
}

variable "key_rotation_enabled" {
  description = "Whether the key material is rotated on AWS's schedule."
  type        = bool
  default     = true
}

variable "key_deletion_window_days" {
  description = "Days between asking for the key's deletion and it happening."
  type        = number
  default     = 30
}

variable "key_alias_prefix" {
  description = "KMS requires every alias to begin with this."
  type        = string
  default     = "alias/"
}

variable "mail_from_host" {
  description = "The host under the domain used as the return path."
  type        = string
  default     = "mail"
}

variable "dkim_host" {
  description = "The host under the domain that SES's signing names sit beneath."
  type        = string
  default     = "_domainkey"
}

variable "dkim_target" {
  description = "Where SES's signing names point."
  type        = string
  default     = "dkim.amazonses.com"
}

variable "dkim_token_count" {
  description = "How many signing names SES gives an identity."
  type        = number
  default     = 3
}

variable "dmarc_host" {
  description = "The host under the domain a DMARC policy is published at."
  type        = string
  default     = "_dmarc"
}

variable "inbound_endpoint" {
  description = "Where mail for the domain is delivered, by Region."
  type        = string
  default     = "inbound-smtp.%s.amazonaws.com"
}

variable "feedback_endpoint" {
  description = "Where bounces for the return path are delivered, by Region."
  type        = string
  default     = "feedback-smtp.%s.amazonses.com"
}

variable "mx_priority" {
  description = "Priority of the mail exchanger records. Each name has one, so the number only has to be valid."
  type        = number
  default     = 10
}

variable "record_ttl_seconds" {
  description = "How long a resolver may remember one of these records."
  type        = number
  default     = 300
}

variable "behavior_on_mx_failure" {
  description = "What SES does if the return path's record cannot be found: send with its own, or refuse."
  type        = string
  default     = "USE_DEFAULT_VALUE"
}

variable "receive_tls_policy" {
  description = "Whether mail that arrives without TLS is refused."
  type        = string
  default     = "Require"
}

variable "object_key_prefix" {
  description = "The folder in the bucket received mail is kept under."
  type        = string
  default     = "received/"
}

variable "topic_encoding" {
  description = "How a message's content is written into what the topic passes on."
  type        = string
  default     = "UTF-8"
}

variable "abort_incomplete_upload_days" {
  description = "Days after which an unfinished multipart upload is removed."
  type        = number
  default     = 1
}

variable "force_destroy" {
  description = "Whether Terraform may empty the mail bucket to delete it. Only the destroy path sets it."
  type        = bool
  default     = false
}
