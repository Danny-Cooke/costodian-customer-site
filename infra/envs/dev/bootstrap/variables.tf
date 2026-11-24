variable "github_owner" {
  description = "The GitHub account or organisation that owns the repository."
  type        = string
}

variable "github_repository" {
  description = "The repository whose workflows may assume the entry roles."
  type        = string
}

variable "github_environments" {
  description = "The GitHub environment each role is tied to. A job can only assume the role of its own environment: a pull request reaches plan, a deploy from main reaches deploy, and the Bootstrap and Destroy workflows reach the seed's bootstrap role. The bootstrap entry is not a role of this stack - the seed owns that role and trusts that one environment - and scripts/seed.sh and scripts/names.sh read it from here."
  type = object({
    bootstrap = string
    plan      = string
    deploy    = string
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

variable "github_oidc_thumbprints" {
  description = "Certificate thumbprints for the issuer, passed to the seed's CloudFormation stack. IAM ignores them for token.actions.githubusercontent.com, which it validates against its own trust store, but the resource still takes the list. Not used by this stack; read from here by scripts/seed.sh so that it is declared once."
  type        = list(string)
}

variable "create_oidc_provider" {
  description = "True when this account has no GitHub sign-in provider yet; an account can hold only one per issuer. Not used by this stack - the seed creates the provider and this stack only reads it - and read from here by scripts/seed.sh so that it is declared once."
  type        = bool
}

variable "seed_managed_by" {
  description = "The ManagedBy tag the seed's resources carry. They are the one thing not made by Terraform, so it is not the stacks' managed_by value."
  type        = string
}

variable "state_bucket_force_destroy" {
  description = "Whether Terraform may empty the state bucket to delete it. A property of the run, not of the environment, so it has a default and only the destroy path sets it. The bucket also carries prevent_destroy, which takes no variable, so the destroy path takes the bucket out of state and deletes it directly; this is the escape hatch for an operator who has lifted prevent_destroy by hand."
  type        = bool
  default     = false
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
  description = "The permissions boundary for the sign-up functions' roles and for the customer data role they assume: the most any of them may ever be granted, by service. A role's own policy is narrower; this is the ceiling, and it is not written by the pipeline's IAM role. ssm_path_actions are the ones taken on the label path itself rather than on one label under it."
  type = object({
    dynamodb_actions = list(string)
    kms_actions      = list(string)
    logs_actions     = list(string)
    cognito_actions  = list(string)
    sts_actions      = list(string)
    ssm_actions      = list(string)
    ssm_path_actions = list(string)
  })
}

variable "github_subject_prefix" {
  description = "The start of the subject GitHub puts in this repository's tokens, as GitHub reports it (repos/<owner>/<repo>/actions/oidc/customization/sub). Empty uses the plain repo:<owner>/<repository> form."
  type        = string
  default     = ""
}
