# Module: vpc

A three-tier-ready VPC sized for EKS: public subnets for NAT gateways and
internet-facing load balancers, large private subnets for nodes and pods.

## Why the private subnets are so much bigger

EKS uses the Amazon VPC CNI by default, which means **every pod gets a real VPC IP
address**, not an overlay address. A node running 30 pods consumes 31 addresses out
of its subnet. A `/24` private subnet would run out of IPs after eight nodes, and the
failure looks like pods stuck in `ContainerCreating` with
`failed to assign an IP address to container` in the kubelet log.

So private subnets are `/19` (8,190 usable addresses each) and public subnets are
`/24`, because the only things in a public subnet are NAT gateways and load balancer
ENIs.

## Subnet discovery tags

The AWS Load Balancer Controller does not guess. It looks for tags:

| Tag | Value | Where | What breaks without it |
|---|---|---|---|
| `kubernetes.io/role/elb` | `1` | public subnets | `Service type=LoadBalancer` and internet-facing Ingress never get an address |
| `kubernetes.io/role/internal-elb` | `1` | private subnets | internal Ingress never gets an address |
| `kubernetes.io/cluster/<name>` | `shared` | both | controller cannot narrow candidates when several clusters share the VPC |

## Cost levers in this module

| Lever | Default | Effect |
|---|---|---|
| `single_nat_gateway = true` | on | One NAT instead of three. Saves about 64 USD/month at us-east-1 pricing. Single point of failure for egress. |
| S3 gateway endpoint | always on | Free. Keeps ECR layer pulls off the NAT, which removes the 0.045 USD/GB NAT data processing charge on image pulls. |
| `enable_flow_logs` | on, `REJECT` only | Logging only rejected traffic keeps the CloudWatch bill near zero while still answering "is a security group dropping this?". |

## Usage

```hcl
module "vpc" {
  source = "../../modules/vpc"

  name               = "portfolio-dev"
  cidr_block         = "10.0.0.0/16"
  availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]
  eks_cluster_name   = "portfolio-dev"
  single_nat_gateway = true

  tags = { Project = "aws-eks-gitops-portfolio" }
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | Name prefix for every resource. |
| `cidr_block` | string | `10.0.0.0/16` | VPC CIDR. |
| `availability_zones` | list(string) | required | At least two. |
| `single_nat_gateway` | bool | `true` | One NAT gateway instead of one per AZ. |
| `enable_flow_logs` | bool | `true` | Flow logs for rejected traffic to CloudWatch. |
| `flow_log_retention_days` | number | `7` | Log group retention. |
| `eks_cluster_name` | string | `null` | Adds the `kubernetes.io/cluster/<name>` discovery tag. |
| `tags` | map(string) | `{}` | Merged onto everything taggable. |

## Outputs

`vpc_id`, `vpc_cidr_block`, `public_subnet_ids`, `private_subnet_ids`,
`public_subnet_cidrs`, `private_subnet_cidrs`, `nat_gateway_public_ips`,
`nat_gateway_count`, `flow_log_group_name`.
