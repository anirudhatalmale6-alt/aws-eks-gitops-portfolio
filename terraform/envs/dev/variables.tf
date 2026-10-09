variable "project" {
  description = "Short project slug. Prefixes resource names and tags everything."
  type        = string
  default     = "eks-gitops"
}

variable "environment" {
  description = "Environment name. Part of every resource name, so dev and prod cannot collide in one account."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "Region everything is created in."
  type        = string
  default     = "us-east-1"
}

variable "availability_zone_count" {
  description = "How many AZs to spread across. Three is the default so a single AZ failure still leaves two thirds of the nodes."
  type        = number
  default     = 3

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 4
    error_message = "Pick between 2 and 4 availability zones. EKS requires 2; past 4 you are paying for NAT gateways you will not use on a demo."
  }
}

variable "vpc_cidr" {
  description = "CIDR for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "single_nat_gateway" {
  description = "One NAT gateway for the whole VPC instead of one per AZ. True saves roughly 64 USD a month on a three AZ build and is the right answer for a demo cluster."
  type        = bool
  default     = true
}

variable "kubernetes_version" {
  description = "Pin the Kubernetes minor version, for example \"1.33\". Leave null and the eks module takes the version AWS currently marks as the default for new clusters."
  type        = string
  default     = null
}

variable "node_instance_types" {
  description = "Instance types for the worker node group. Several types are given because SPOT capacity for any single type can disappear; the node group falls through the list."
  type        = list(string)
  default     = ["t3.large", "t3a.large", "t3.xlarge"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT. SPOT is around 70 percent cheaper and perfectly reasonable for a portfolio cluster, as long as you can explain in an interview why you would not run a stateful production workload on it without PodDisruptionBudgets and node termination handling."
  type        = string
  default     = "SPOT"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_min_size" {
  description = "Minimum nodes."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum nodes."
  type        = number
  default     = 4
}

variable "node_desired_size" {
  description = "Nodes at creation. Two t3.large is the floor for Argo CD plus kube-prometheus-stack plus the demo app; one node will leave pods Pending on insufficient memory."
  type        = number
  default     = 2
}

variable "api_public_access_cidrs" {
  description = "CIDRs allowed to reach the Kubernetes API endpoint. Set this to YOUR_IP/32 for anything you care about. The default is open because a changing home IP otherwise locks you out of your own cluster mid-build."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "github_owner" {
  description = "Your GitHub username or organisation. Used in the OIDC trust policies, so a wrong value here means CI cannot assume any role."
  type        = string
}

variable "github_repo" {
  description = "This repository's name on GitHub."
  type        = string
  default     = "aws-eks-gitops-portfolio"
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC identity provider. Set to false if the account already has one, since AWS allows only one per URL."
  type        = bool
  default     = true
}

variable "existing_github_oidc_provider_arn" {
  description = "ARN of an existing GitHub OIDC provider, when create_github_oidc_provider is false."
  type        = string
  default     = null
}

variable "state_bucket_name" {
  description = "Name of the terraform state bucket from the bootstrap stack. The CI plan and apply roles are scoped to exactly this bucket rather than to s3:*."
  type        = string
}

variable "enable_flow_logs" {
  description = "VPC flow logs for rejected traffic."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra tags merged on top of the provider default_tags."
  type        = map(string)
  default     = {}
}
