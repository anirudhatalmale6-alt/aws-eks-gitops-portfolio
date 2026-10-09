variable "repositories" {
  description = <<-EOT
    Repositories to create, keyed by repository name. Each entry:
      image_tag_mutability  - IMMUTABLE (default) or MUTABLE.
      untagged_expiry_days  - days before an untagged image is expired.
      keep_last_images      - how many images matching protected_tag_prefixes to keep.
      protected_tag_prefixes - tag prefixes the keep-N rule applies to.
      force_delete          - allow terraform destroy to delete a repository that still holds images.
  EOT
  type = map(object({
    image_tag_mutability   = optional(string, "IMMUTABLE")
    untagged_expiry_days   = optional(number, 7)
    keep_last_images       = optional(number, 20)
    protected_tag_prefixes = optional(list(string), ["v", "sha-", "main-"])
    force_delete           = optional(bool, true)
  }))

  validation {
    condition = alltrue([
      for r in var.repositories : contains(["IMMUTABLE", "MUTABLE"], r.image_tag_mutability)
    ])
    error_message = "image_tag_mutability must be IMMUTABLE or MUTABLE."
  }

  validation {
    condition     = alltrue([for r in var.repositories : length(r.protected_tag_prefixes) > 0])
    error_message = "protected_tag_prefixes cannot be empty, otherwise the keep-N rule matches nothing and old images are never cleaned up."
  }
}

variable "kms_key_arn" {
  description = "Customer managed KMS key for repository encryption. Null means ECR's own AES256 encryption, which is free; a CMK costs 1 USD per month plus request charges."
  type        = string
  default     = null
}

variable "pull_principal_arns" {
  description = "IAM principals allowed to pull. Normally the EKS node role."
  type        = list(string)
  default     = []
}

variable "push_principal_arns" {
  description = "IAM principals allowed to push. Normally the GitHub Actions image-build role only."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags merged onto every repository."
  type        = map(string)
  default     = {}
}

variable "enable_enhanced_scanning" {
  description = "Turn on Amazon Inspector enhanced scanning. Read the comment in main.tf first: this setting is account-and-region wide, not per repository, and it is billed per scan."
  type        = bool
  default     = false
}
