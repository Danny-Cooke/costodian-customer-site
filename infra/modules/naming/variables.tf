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
  description = "The bounded context this name belongs to, e.g. web, ci."
  type        = string
}

variable "types" {
  description = "Logical key to resource kind. The kind must be one of the type vocabulary in this module."
  type        = map(string)
}

variable "globally_unique" {
  description = "Keys in var.types whose name must be globally unique and S3-safe (lowercase, 3-63 characters)."
  type        = list(string)
  default     = []
}

variable "max_name_length" {
  description = "The tightest common AWS limit: IAM role names and Lambda function names are both 64 characters."
  type        = number
  default     = 64
}

variable "max_bucket_name_length" {
  description = "S3 bucket names are 3 to 63 characters."
  type        = number
  default     = 63
}

variable "min_bucket_name_length" {
  description = "S3 bucket names are 3 to 63 characters."
  type        = number
  default     = 3
}
