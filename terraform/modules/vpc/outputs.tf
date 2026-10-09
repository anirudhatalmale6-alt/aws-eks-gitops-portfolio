output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs, ordered to match var.availability_zones."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs, ordered to match var.availability_zones. Nodes and pods live here."
  value       = aws_subnet.private[*].id
}

output "public_subnet_cidrs" {
  description = "Public subnet CIDR blocks."
  value       = local.public_subnet_cidrs
}

output "private_subnet_cidrs" {
  description = "Private subnet CIDR blocks."
  value       = local.private_subnet_cidrs
}

output "nat_gateway_public_ips" {
  description = "Elastic IPs of the NAT gateways. Everything the cluster sends to the internet comes from these addresses, which is what you give someone who needs to allow-list the cluster."
  value       = aws_eip.nat[*].public_ip
}

output "nat_gateway_count" {
  description = "How many NAT gateways were actually created."
  value       = local.nat_gateway_count
}

output "flow_log_group_name" {
  description = "CloudWatch log group holding rejected-traffic flow logs, or null when flow logs are disabled."
  value       = var.enable_flow_logs ? aws_cloudwatch_log_group.flow_logs[0].name : null
}
