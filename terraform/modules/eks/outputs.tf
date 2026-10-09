output "cluster_name" {
  description = "Cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "Cluster ARN."
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_version" {
  description = "Kubernetes minor version actually running, whether it was pinned or auto-selected."
  value       = aws_eks_cluster.this.version
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA bundle for the API server. Needed by anything building a kubeconfig by hand."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "The EKS-managed cluster security group. Anything that needs to reach the API from inside the VPC gets allowed in here."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_security_group_id" {
  description = "The additional security group attached to worker nodes by this module."
  value       = aws_security_group.node.id
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for this cluster. Every IRSA role trusts this."
  value       = aws_iam_openid_connect_provider.cluster.arn
}

output "oidc_provider_url" {
  description = "OIDC issuer host without the https:// prefix, which is the form IAM condition keys need."
  value       = local.oidc_issuer_host
}

output "node_role_arn" {
  description = "IAM role the worker nodes run as."
  value       = aws_iam_role.node.arn
}

output "node_role_name" {
  description = "Name of the worker node IAM role, for attaching extra policies from outside the module."
  value       = aws_iam_role.node.name
}

output "kms_key_arn" {
  description = "CMK used for Kubernetes Secret envelope encryption."
  value       = aws_kms_key.cluster.arn
}

output "update_kubeconfig_command" {
  description = "Copy-paste command to point kubectl at this cluster."
  value       = "aws eks update-kubeconfig --region ${data.aws_region.current.region} --name ${aws_eks_cluster.this.name}"
}

data "aws_region" "current" {}
