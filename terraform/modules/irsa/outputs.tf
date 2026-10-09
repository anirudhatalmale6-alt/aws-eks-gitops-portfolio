output "role_arn" {
  description = "ARN of the role. This is the value of the eks.amazonaws.com/role-arn annotation on the service account."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Name of the role."
  value       = aws_iam_role.this.name
}

output "service_account_annotation" {
  description = "Ready-made annotation map to paste onto the ServiceAccount, or to feed a Helm chart's serviceAccount.annotations value."
  value = {
    "eks.amazonaws.com/role-arn" = aws_iam_role.this.arn
  }
}

output "trusted_subjects" {
  description = "The exact sub claims this role trusts. Compare against the pod's real token when a trust policy is not matching."
  value       = local.subjects
}
