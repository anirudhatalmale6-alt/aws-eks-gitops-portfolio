output "repository_urls" {
  description = "Map of repository name to its full URL, which is what goes in a Kubernetes image field."
  value       = { for name, r in aws_ecr_repository.this : name => r.repository_url }
}

output "repository_arns" {
  description = "Map of repository name to ARN."
  value       = { for name, r in aws_ecr_repository.this : name => r.arn }
}

output "registry_url" {
  description = "Account registry host, the part before the first slash in any image reference."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.region}.amazonaws.com"
}

output "docker_login_command" {
  description = "Copy-paste command to authenticate a local docker or podman against this registry."
  value       = "aws ecr get-login-password --region ${data.aws_region.current.region} | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.region}.amazonaws.com"
}
