output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider in use, whether this module created it or it was passed in."
  value       = local.oidc_provider_arn
}

output "role_arns" {
  description = "Map of role key to ARN. These are the values that go in the workflow's role-to-assume, as repository variables rather than secrets since an ARN is not sensitive."
  value       = { for k, r in aws_iam_role.this : k => r.arn }
}

output "role_names" {
  description = "Map of role key to role name."
  value       = { for k, r in aws_iam_role.this : k => r.name }
}

output "trusted_subjects" {
  description = "Fully expanded sub claims per role. Compare these against the 'sub' in the OIDC token your workflow actually sent when an assume-role is being refused."
  value = {
    for k, r in var.roles : k => [
      for s in r.subjects : "repo:${var.github_owner}/${var.github_repo}:${s}"
    ]
  }
}

output "gh_variable_commands" {
  description = "Copy-paste gh CLI commands that set each role ARN as a repository variable."
  value = [
    for k, r in aws_iam_role.this :
    "gh variable set AWS_${upper(replace(k, "-", "_"))}_ROLE_ARN --repo ${var.github_owner}/${var.github_repo} --body ${r.arn}"
  ]
}
