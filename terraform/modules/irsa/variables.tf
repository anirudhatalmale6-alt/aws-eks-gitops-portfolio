variable "role_name" {
  description = "Name of the IAM role."
  type        = string
}

variable "description" {
  description = "What this role is for. Shows up in the IAM console, which future you will appreciate."
  type        = string
  default     = "IRSA role for an EKS service account"
}

variable "path" {
  description = "IAM path. Grouping IRSA roles under /eks-irsa/ makes them easy to find and easy to scope a permissions boundary to."
  type        = string
  default     = "/eks-irsa/"
}

variable "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider, from the eks module output oidc_provider_arn."
  type        = string
}

variable "oidc_provider_url" {
  description = "OIDC issuer host WITHOUT the https:// prefix, from the eks module output oidc_provider_url. IAM condition keys are built from the bare host; leaving the scheme on is the classic reason a trust policy silently never matches."
  type        = string

  validation {
    condition     = !startswith(var.oidc_provider_url, "https://")
    error_message = "oidc_provider_url must not include the https:// scheme. Use the eks module's oidc_provider_url output, which has it stripped."
  }
}

variable "service_accounts" {
  description = "Service accounts allowed to assume this role. Keep this list as short as possible; every entry is another pod that can use these permissions."
  type = list(object({
    namespace = string
    name      = string
  }))

  validation {
    condition     = length(var.service_accounts) > 0
    error_message = "At least one service account is required, otherwise nothing can ever assume the role."
  }
}

variable "managed_policy_arns" {
  description = "AWS managed or pre-existing customer managed policies to attach."
  type        = list(string)
  default     = []
}

variable "policy_json" {
  description = "Inline policy document as JSON. Build it with aws_iam_policy_document rather than a heredoc so terraform validates the shape."
  type        = string
  default     = null
}

variable "max_session_duration" {
  description = "Maximum credential lifetime in seconds. 3600 is the AWS default and the shortest the SDKs refresh transparently."
  type        = number
  default     = 3600
}

variable "permissions_boundary_arn" {
  description = "Optional permissions boundary. A hard ceiling that survives someone attaching a wider policy later."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags merged onto the role."
  type        = map(string)
  default     = {}
}
