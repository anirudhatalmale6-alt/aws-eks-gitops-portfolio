variable "name" {
  description = "Name prefix applied to every resource in this module."
  type        = string
}

variable "cidr_block" {
  description = "IPv4 CIDR block for the VPC. A /16 gives room for three /19 private subnets plus small public subnets."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.cidr_block))
    error_message = "cidr_block must be a valid IPv4 CIDR, for example 10.0.0.0/16."
  }
}

variable "availability_zones" {
  description = "Availability zones to spread subnets across. Two is the EKS minimum; three is what this project uses so a single AZ outage still leaves a quorum of nodes."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "EKS requires subnets in at least two availability zones."
  }
}

variable "single_nat_gateway" {
  description = "Run one NAT gateway for the whole VPC instead of one per AZ. Cheaper (saves roughly 32 USD per month per AZ removed) but the NAT becomes a single point of failure. Fine for a demo, wrong for production."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Send VPC flow logs to CloudWatch Logs. Useful for the troubleshooting story, costs a little per GB ingested."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "Retention for the flow log group. Keep it short on a demo account."
  type        = number
  default     = 7
}

variable "eks_cluster_name" {
  description = "Cluster name used for the kubernetes.io subnet discovery tags. Leave null if the VPC is not for EKS."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags merged onto every taggable resource."
  type        = map(string)
  default     = {}
}

variable "public_subnet_auto_assign_public_ip" {
  description = "Give every EC2 instance launched into a public subnet a public IP. False, because nothing in this project launches an instance in a public subnet: nodes are private, NAT gateways carry an explicit Elastic IP, and ELB assigns its own addresses. Only set true if you deliberately add a bastion here."
  type        = bool
  default     = false
}
