variable "name_prefix" {
  description = "Prefix for every role created here. Roles are named <prefix>-<role key>."
  type        = string
}

variable "path" {
  description = "IAM path for the roles and policies."
  type        = string
  default     = "/github-actions/"
}

variable "github_owner" {
  description = "GitHub user or organisation that owns the repository, for example your GitHub username."
  type        = string

  validation {
    condition     = length(trimspace(var.github_owner)) > 0 && !strcontains(var.github_owner, "/")
    error_message = "github_owner is the owner only, with no slash. Put the repository name in github_repo."
  }
}

variable "github_repo" {
  description = "Repository name, without the owner."
  type        = string

  validation {
    condition     = length(trimspace(var.github_repo)) > 0 && !strcontains(var.github_repo, "/")
    error_message = "github_repo is the repository name only, with no slash."
  }
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC identity provider. An AWS account can only have one per URL, so set this to false and pass existing_oidc_provider_arn if the account already has it."
  type        = bool
  default     = true
}

variable "existing_oidc_provider_arn" {
  description = "ARN of an existing GitHub OIDC provider, used when create_oidc_provider is false."
  type        = string
  default     = null

  validation {
    condition     = var.existing_oidc_provider_arn == null || can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:oidc-provider/", coalesce(var.existing_oidc_provider_arn, "none")))
    error_message = "existing_oidc_provider_arn must be an IAM oidc-provider ARN."
  }

  # Catch the mismatch at plan time instead of discovering it as a null principal
  # in a trust policy that AWS then rejects with a MalformedPolicyDocument.
  validation {
    condition     = var.create_oidc_provider || var.existing_oidc_provider_arn != null
    error_message = "With create_oidc_provider = false you must pass existing_oidc_provider_arn. Find it with: aws iam list-open-id-connect-providers"
  }
}

variable "roles" {
  description = <<-EOT
    Roles to create, keyed by a short name. Each entry:
      description          - shown in the IAM console.
      subjects             - GitHub OIDC sub claims, WITHOUT the leading "repo:owner/name:".
                             Examples: "pull_request", "ref:refs/heads/main",
                             "environment:production", "ref:refs/tags/v*".
      managed_policy_arns  - managed policies to attach.
      policy_json          - inline policy document as JSON.
      max_session_duration - seconds; a job that runs longer than this loses its credentials mid-run.
      permissions_boundary_arn - optional hard ceiling on the role.
  EOT
  type = map(object({
    description              = optional(string, "GitHub Actions role")
    subjects                 = list(string)
    managed_policy_arns      = optional(list(string), [])
    policy_json              = optional(string)
    max_session_duration     = optional(number, 3600)
    permissions_boundary_arn = optional(string)
  }))

  validation {
    condition     = alltrue([for r in var.roles : length(r.subjects) > 0])
    error_message = "Every role needs at least one subject, otherwise nothing can assume it."
  }

  # The guard that matters. A subject of "*" expands to repo:owner/name:* which
  # at least stays inside one repository, but a subject containing a slash or
  # starting with a wildcard can escape the repo scope entirely and hand the
  # role to anyone on GitHub.
  validation {
    condition = alltrue(flatten([
      for r in var.roles : [
        for s in r.subjects : !startswith(s, "*") && !strcontains(s, "repo:")
      ]
    ]))
    error_message = "A subject must be the part AFTER repo:owner/name:, must not start with a wildcard, and must not contain 'repo:'. Anything else risks a trust policy that any GitHub repository can assume."
  }

  validation {
    condition     = alltrue([for r in var.roles : r.max_session_duration >= 900 && r.max_session_duration <= 43200])
    error_message = "max_session_duration must be between 900 and 43200 seconds."
  }
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default     = {}
}
