output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version actually running."
  value       = module.eks.cluster_version
}

output "update_kubeconfig_command" {
  description = "Run this first after apply. Everything in docs/04-gitops.md assumes kubectl is pointed here."
  value       = module.eks.update_kubeconfig_command
}

output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs, where nodes and pods live."
  value       = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs, where NAT gateways and internet-facing load balancers live."
  value       = module.vpc.public_subnet_ids
}

output "nat_gateway_public_ips" {
  description = "Everything the cluster sends to the internet comes from these addresses."
  value       = module.vpc.nat_gateway_public_ips
}

output "ecr_repository_url" {
  description = "Full image repository URL. This is the value the demo app's Kubernetes manifest needs."
  value       = module.ecr.repository_urls[local.ecr_repository_name]
}

output "oidc_provider_arn" {
  description = "Cluster IAM OIDC provider ARN, the trust anchor for every IRSA role."
  value       = module.eks.oidc_provider_arn
}

output "aws_load_balancer_controller_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller. Goes into the controller's Argo CD Application values."
  value       = module.irsa_aws_load_balancer_controller.role_arn
}

output "github_actions_role_arns" {
  description = "The three CI role ARNs, keyed by purpose. Set these as repository VARIABLES, not secrets: a role ARN is not a credential and seeing it in a log is harmless."
  value       = module.github_oidc.role_arns
}

output "github_variable_setup_commands" {
  description = "Copy-paste gh CLI commands that wire the role ARNs into the repository so the workflows can find them."
  value = concat(
    module.github_oidc.gh_variable_commands,
    [
      "gh variable set AWS_REGION --repo ${var.github_owner}/${var.github_repo} --body ${var.aws_region}",
      "gh variable set ECR_REPOSITORY --repo ${var.github_owner}/${var.github_repo} --body ${local.ecr_repository_name}",
      "gh variable set EKS_CLUSTER_NAME --repo ${var.github_owner}/${var.github_repo} --body ${module.eks.cluster_name}",
      "gh variable set TF_STATE_BUCKET --repo ${var.github_owner}/${var.github_repo} --body ${var.state_bucket_name}",
    ],
  )
}

#
# Values the Kubernetes layer needs. Printed as one block so the GitOps step is a
# copy-paste rather than a scavenger hunt through the other outputs.
#
output "gitops_values" {
  description = "Substitute these into kubernetes/platform/*.yaml before the first Argo CD sync."
  value = {
    cluster_name                          = module.eks.cluster_name
    aws_region                            = var.aws_region
    vpc_id                                = module.vpc.vpc_id
    alb_controller_role_arn               = module.irsa_aws_load_balancer_controller.role_arn
    ecr_repository_url                    = module.ecr.repository_urls[local.ecr_repository_name]
    git_repo_url                          = "https://github.com/${var.github_owner}/${var.github_repo}.git"
    estimated_monthly_usd_if_left_running = local.cost_estimate_monthly_usd
  }
}

#
# A rough, deliberately pessimistic monthly figure, computed from what was
# actually created rather than from a blog post. It is printed on every apply so
# the number is in front of you before you walk away from a running cluster.
#
locals {
  # us-east-1 on-demand list prices, USD, as of the time of writing. Override in
  # tfvars if your region differs.
  price_eks_control_plane_hour = 0.10
  price_nat_gateway_hour       = 0.045
  price_t3_large_hour          = 0.0832
  spot_discount                = 0.70

  hours_per_month = 730

  cost_estimate_monthly_usd = ceil(
    local.price_eks_control_plane_hour * local.hours_per_month
    + local.price_nat_gateway_hour * module.vpc.nat_gateway_count * local.hours_per_month
    + local.price_t3_large_hour * var.node_desired_size * local.hours_per_month *
    (var.node_capacity_type == "SPOT" ? (1 - local.spot_discount) : 1)
  )
}

output "cost_note" {
  description = "Rough monthly cost if this stack is left running, and the one command that stops it."
  value = join(" ", [
    "Leaving this stack up costs roughly ${local.cost_estimate_monthly_usd} USD per month",
    "(EKS control plane + ${module.vpc.nat_gateway_count} NAT gateway(s) + ${var.node_desired_size} x ${var.node_capacity_type} node(s)),",
    "excluding load balancers, EBS volumes and data transfer.",
    "Tear it down with: make destroy",
  ])
}
