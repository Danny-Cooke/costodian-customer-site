# Declared in every stack of this environment; the values come from
# ../platform.tfvars.json, which every stack is run with
# (-var-file=../platform.tfvars.json). JSON so that the site build tool reads
# the same file for the product's name instead of a second copy of it.

variable "product_name" {
  description = "The product's name as a person reads it. The one place it is declared; the AWS project token is derived from it, and the site build reads it from this same file."
  type        = string
}

variable "project_suffix" {
  description = "What this repository builds for the product, joined to the derived product token to make the project naming slot."
  type        = string
}

variable "platform" {
  description = "The naming slots, the partition and the Regions every module shares. No project slot: it is derived from product_name and project_suffix. The partition is declared rather than looked up, so that a script can compose an ARN from the configuration alone, with no AWS call and no credentials."
  type = object({
    prefix      = string
    environment = string
    postfix     = string
    partition   = string
    region      = string
    edge_region = string
  })
}

variable "components" {
  description = "The component token of each bounded context."
  type = object({
    web     = string
    ci      = string
    account = string
  })
}

variable "services" {
  description = "The AWS services the pipeline changes, one role per service. The same list keys the bootstrap stack's service_roles map and composes the role ARNs each provider in the site stack assumes."
  type        = list(string)
}

variable "repository" {
  description = "The repository this infrastructure is defined in. Used as a tag."
  type        = string
}

variable "managed_by" {
  description = "What manages these resources. Used as a tag."
  type        = string
}

variable "owner" {
  description = "Who owns these resources. Used as a tag."
  type        = string
}
