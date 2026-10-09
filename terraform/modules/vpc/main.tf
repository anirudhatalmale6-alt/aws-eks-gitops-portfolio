#
# Network layout
# --------------
# The private subnets are deliberately much larger than the public ones. Every pod
# in this cluster gets a real VPC IP from the VPC CNI, so the private ranges have to
# hold nodes plus pods. The public subnets only ever hold NAT gateways and
# internet-facing load balancers, so a /24 each is plenty.
#
#   10.0.0.0/16        VPC
#   10.0.0.0/19        private  az[0]     8190 usable
#   10.0.32.0/19       private  az[1]
#   10.0.64.0/19       private  az[2]
#   10.0.192.0/24      public   az[0]      251 usable
#   10.0.193.0/24      public   az[1]
#   10.0.194.0/24      public   az[2]
#
locals {
  az_count = length(var.availability_zones)

  private_subnet_cidrs = [for i in range(local.az_count) : cidrsubnet(var.cidr_block, 3, i)]
  public_subnet_cidrs  = [for i in range(local.az_count) : cidrsubnet(var.cidr_block, 8, 192 + i)]

  nat_gateway_count = var.single_nat_gateway ? 1 : local.az_count

  # Tags the AWS Load Balancer Controller looks for when it has to pick subnets on
  # its own. Without these an ingress just sits there with no address and the
  # controller logs "unable to discover at least one subnet".
  cluster_discovery_tags = var.eks_cluster_name == null ? {} : {
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
  }

  tags = merge(var.tags, { "Module" = "vpc" })
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = var.name })
}

# The default security group allows all traffic between its members. Nothing should
# ever use it, so strip every rule off it rather than leaving it open.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name}-default-do-not-use" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name}-igw" })
}

resource "aws_subnet" "public" {
  count = local.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # Off, and it is worth knowing why, because almost every VPC example on the
  # internet sets this to true for public subnets.
  #
  # This flag only affects EC2 INSTANCES launched into the subnet. Nothing in
  # this project launches an instance into a public subnet: the nodes are all
  # private, NAT gateways get an explicit Elastic IP, and load balancer ENIs are
  # given public addresses by ELB itself. So leaving it on would hand a public IP
  # to anything anyone ever launches here by accident, and buy nothing.
  map_public_ip_on_launch = var.public_subnet_auto_assign_public_ip

  tags = merge(
    local.tags,
    local.cluster_discovery_tags,
    {
      Name                     = "${var.name}-public-${var.availability_zones[count.index]}"
      Tier                     = "public"
      "kubernetes.io/role/elb" = "1"
    },
  )
}

resource "aws_subnet" "private" {
  count = local.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.private_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = merge(
    local.tags,
    local.cluster_discovery_tags,
    {
      Name                              = "${var.name}-private-${var.availability_zones[count.index]}"
      Tier                              = "private"
      "kubernetes.io/role/internal-elb" = "1"
    },
  )
}

resource "aws_eip" "nat" {
  count = local.nat_gateway_count

  domain = "vpc"

  tags = merge(local.tags, { Name = "${var.name}-nat-${count.index}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(local.tags, { Name = "${var.name}-nat-${count.index}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name}-public" })
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = local.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One route table per private subnet even when there is a single NAT gateway, so
# flipping single_nat_gateway to false later is an in-place route change rather
# than a rebuild of the routing layer.
resource "aws_route_table" "private" {
  count = local.az_count

  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name}-private-${var.availability_zones[count.index]}" })
}

resource "aws_route" "private_default" {
  count = local.az_count

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
}

resource "aws_route_table_association" "private" {
  count = local.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

#
# Gateway endpoint for S3
# -----------------------
# Every image layer pull from ECR fetches its blobs from S3. Routing that through
# the gateway endpoint instead of the NAT gateway removes the per-GB NAT data
# processing charge, which on a cluster that pulls images all day is the single
# cheapest optimisation available. Gateway endpoints are free.
#
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(local.tags, { Name = "${var.name}-s3" })
}

data "aws_region" "current" {}

#
# Flow logs
#
resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/aws/vpc/${var.name}/flow-logs"
  retention_in_days = var.flow_log_retention_days

  tags = local.tags
}

data "aws_iam_policy_document" "flow_logs_assume" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs[0].arn}:*"]
  }
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name               = "${var.name}-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume[0].json

  tags = local.tags
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs[0].json
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id               = aws_vpc.this.id
  traffic_type         = "REJECT"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn         = aws_iam_role.flow_logs[0].arn

  tags = merge(local.tags, { Name = "${var.name}-rejects" })
}
