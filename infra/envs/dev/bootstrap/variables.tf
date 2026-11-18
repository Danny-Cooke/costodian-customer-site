variable "github_owner" {
  description = "The GitHub account or organisation that owns the repository."
  type        = string
}

variable "github_repository" {
  description = "The repository whose workflows may assume the entry roles."
  type        = string
}

variable "github_environments" {
  description = "The GitHub environment each entry role is tied to. A job can only assume the role of its own environment: a pull request reaches plan, a deploy from main reaches deploy."
  type = object({
    plan   = string
    deploy = string
  })
}

variable "github_oidc_url" {
  description = "Issuer of GitHub Actions' identity tokens."
  type        = string
  default     = "https://token.actions.githubusercontent.com"
}

variable "github_oidc_audience" {
  description = "Audience GitHub Actions requests its token for."
  type        = string
  default     = "sts.amazonaws.com"
}

variable "create_oidc_provider" {
  description = "True when this account has no GitHub sign-in provider yet. An account can hold only one per issuer."
  type        = bool
}

variable "role_max_session_seconds" {
  description = "Longest session any of these roles may hold."
  type        = number
  default     = 3600
}

variable "site_state_key" {
  description = "The object key of the site stack's state in the state bucket. Must equal TF_STATE_KEY in the workflow."
  type        = string
}

variable "bootstrap_state_key" {
  description = "The object key this stack's own state is migrated to in the state bucket. Read by scripts/bootstrap.sh, so it is written once here."
  type        = string
}

variable "state_lock_suffix" {
  description = "What the S3 backend appends to the state key for the lock object it writes when use_lockfile is set."
  type        = string
  default     = ".tflock"
}

variable "deploy_assume_actions" {
  description = "What the deploy entry role may do to a service role. The whole of what it holds besides the state object: it cannot change a single AWS resource itself."
  type        = list(string)
}

variable "iam_service" {
  description = "Which key of var.services is the one allowed to write IAM. That role carries the permissions-boundary guard rails as well as its generated policy."
  type        = string
}

variable "publish_service" {
  description = "Which key of var.services is the role the workflow's publish step assumes. It is never assumed by Terraform."
  type        = string
}

variable "service_roles" {
  description = <<-EOT
    One entry per key of var.services: the role's description and its
    statements. A statement names the resource-pattern keys it applies to
    (resolved to ARNs in main.tf, where the account id, Region and composed
    name prefixes live) and splits its actions in two. The service role gets
    read_actions and write_actions; the plan role gets every service's
    read_actions and none of its write_actions, so one list is the source of
    both. Actions are listed in full: no wildcard action anywhere.
  EOT
  type = map(object({
    description = string
    statements = map(object({
      resources     = list(string)
      read_actions  = list(string)
      write_actions = list(string)
      conditions = optional(list(object({
        test     = string
        variable = string
        values   = list(string)
      })), [])
    }))
  }))
}

variable "access_boundary_guarded_actions" {
  description = "Actions the IAM service role may only take when the role being created or changed carries the permissions boundary. Denied otherwise, whatever its allow statements say."
  type        = list(string)
}

variable "access_never_allowed_actions" {
  description = "Actions the IAM service role is denied outright, on every resource, so it can never detach a boundary from anything."
  type        = list(string)
}

variable "access_protected_write_actions" {
  description = "IAM write actions denied on the boundary policy itself and on every pipeline role and policy, so the role that writes IAM cannot widen its own ceiling or any other role's."
  type        = list(string)
}

variable "function_boundary" {
  description = "The permissions boundary for the sign-up functions' roles: the most any function may ever be granted, by service. A function's own policy is narrower; this is the ceiling, and it is not written by the pipeline's IAM role."
  type = object({
    dynamodb_actions = list(string)
    kms_actions      = list(string)
    logs_actions     = list(string)
  })
}
