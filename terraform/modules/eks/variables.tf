variable "cluster_name" {
  description = "Name of the EKS cluster. Also used as the prefix for the IAM roles, KMS alias and log group."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version, for example 1.34. Leave null to let the module pick the newest version still on EKS standard support, read live from the API, so this file does not rot every few months."
  type        = string
  default     = null

  validation {
    condition     = var.kubernetes_version == null || can(regex("^1\\.[0-9]{2}$", coalesce(var.kubernetes_version, "1.00")))
    error_message = "kubernetes_version must look like 1.34 (major.minor, no patch), or be null to auto-select."
  }
}

variable "vpc_id" {
  description = "VPC the cluster lives in."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for the control plane ENIs and the worker nodes."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "EKS needs subnets in at least two availability zones."
  }
}

variable "public_subnet_ids" {
  description = "Public subnets. Handed to the control plane as well so internet-facing load balancers can be placed, but no node ever launches here."
  type        = list(string)
  default     = []
}

variable "endpoint_public_access" {
  description = "Whether the Kubernetes API is reachable from the internet. Keep true while you are working from a laptop with a changing IP; the public_access_cidrs variable is what actually narrows it."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint. The default is wide open, which is fine for a demo cluster whose only authentication path is IAM, but set it to your own address for anything real."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enabled_cluster_log_types" {
  description = "Control plane logs shipped to CloudWatch. 'audit' and 'authenticator' are the two that actually answer 'who did this and were they allowed to'."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "cluster_log_retention_days" {
  description = "Retention on the control plane log group. The log group is created here rather than by EKS so that retention is not 'never expire'."
  type        = number
  default     = 7
}

variable "node_groups" {
  description = <<-EOT
    Managed node groups, keyed by name. Each entry:
      instance_types - list of instance types. With capacity_type SPOT, give several so the pool has somewhere to go when one type is reclaimed.
      capacity_type  - ON_DEMAND or SPOT.
      min_size / max_size / desired_size - autoscaling bounds.
      disk_size_gb   - root volume size, gp3, encrypted.
      labels         - Kubernetes node labels.
      taints         - list of { key, value, effect } where effect is NO_SCHEDULE, NO_EXECUTE or PREFER_NO_SCHEDULE.
  EOT
  type = map(object({
    instance_types = optional(list(string), ["t3.medium"])
    capacity_type  = optional(string, "ON_DEMAND")
    min_size       = optional(number, 2)
    max_size       = optional(number, 4)
    desired_size   = optional(number, 2)
    disk_size_gb   = optional(number, 30)
    labels         = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = optional(string)
      effect = string
    })), [])
  }))

  default = {
    default = {}
  }

  validation {
    condition     = alltrue([for g in var.node_groups : contains(["ON_DEMAND", "SPOT"], g.capacity_type)])
    error_message = "capacity_type must be ON_DEMAND or SPOT."
  }

  validation {
    condition     = alltrue([for g in var.node_groups : g.desired_size >= g.min_size && g.desired_size <= g.max_size])
    error_message = "desired_size must sit between min_size and max_size."
  }
}

variable "cluster_admin_principal_arns" {
  description = "IAM principals granted cluster-admin through EKS access entries. The identity that runs terraform apply already gets admin via bootstrap_cluster_creator_admin_permissions; this is for everyone else, for example the CI apply role."
  type        = list(string)
  default     = []
}

variable "enable_ebs_csi_driver" {
  description = "Install the EBS CSI driver addon with its own IRSA role. Required for any PersistentVolumeClaim, which includes Prometheus and Grafana."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags merged onto every taggable resource."
  type        = map(string)
  default     = {}
}
