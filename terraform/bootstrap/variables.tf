variable "project" {
  description = "Short project slug, used to name the bucket and tag everything."
  type        = string
  default     = "eks-gitops-portfolio"
}

variable "aws_region" {
  description = "Region the state bucket lives in. State does not have to sit in the same region as the infrastructure, but keeping them together avoids cross-region data charges on every plan."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Explicit bucket name. Leave null to get <project>-tfstate-<account id>, which is unique without you having to think about it."
  type        = string
  default     = null
}

variable "kms_key_arn" {
  description = "Customer managed KMS key for state encryption. Null uses S3-managed AES256, which is free and already encrypts at rest. A CMK adds auditable Decrypt calls in CloudTrail for about 1 USD per month."
  type        = string
  default     = null
}

variable "state_version_retention_days" {
  description = "How long a superseded state version is kept before expiry."
  type        = number
  default     = 90
}

variable "state_versions_to_keep" {
  description = "How many superseded versions to keep regardless of age. Keeps a recent rollback target available even if the retention window passes."
  type        = number
  default     = 10

  validation {
    condition     = var.state_versions_to_keep >= 1 && var.state_versions_to_keep <= 100
    error_message = "state_versions_to_keep must be between 1 and 100."
  }
}

variable "tags" {
  description = "Extra tags merged onto every resource."
  type        = map(string)
  default     = {}
}
