data "aws_partition" "current" {}

#
# Kubernetes version
# ------------------
# Hardcoding "1.34" in a repo means the repo is wrong a few months later. When
# var.kubernetes_version is null the module asks EKS which versions are on
# standard support right now and takes the one AWS marks as the default for new
# clusters, falling back to the newest if the API reports no default.
#
# Standard support matters for more than freshness: once a version falls into
# extended support the control plane goes from 0.10 to 0.60 USD per hour. That
# 6x jump has surprised a lot of people who simply never upgraded.
#
data "aws_eks_cluster_versions" "standard" {
  cluster_type   = "eks"
  version_status = "STANDARD_SUPPORT"
  default_only   = false
  include_all    = false
}

locals {
  standard_versions = data.aws_eks_cluster_versions.standard.cluster_versions

  # Sort by minor number, not as a string, so 1.9 never sorts above 1.34.
  versions_newest_first = reverse([
    for v in sort([
      for v in local.standard_versions :
      format("1.%03d", tonumber(split(".", v.cluster_version)[1]))
    ]) : replace(v, "/^1\\.0*/", "1.")
  ])

  # Prefer the version AWS itself marks as the default for new clusters. It lags
  # the newest release by a few weeks, and that lag is exactly the window where
  # addons and Helm charts have not caught up yet. Fall back to newest on
  # standard support if the API reports no default.
  aws_default_version = try(
    [for v in local.standard_versions : v.cluster_version if v.default_version][0],
    try(local.versions_newest_first[0], null),
  )

  kubernetes_version = coalesce(var.kubernetes_version, local.aws_default_version)

  tags = merge(var.tags, { "Module" = "eks" })

  # Normalised OIDC issuer host, used in every IRSA trust policy.
  oidc_issuer_host = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

#
# Envelope encryption for Kubernetes Secrets
# ------------------------------------------
# Without this, Secret objects sit in the EKS-managed etcd encrypted with an AWS
# managed key you cannot audit or revoke. With it, every Secret write goes through
# this CMK, so revoking the key makes the data unreadable and CloudTrail shows the
# Decrypt calls.
#
resource "aws_kms_key" "cluster" {
  description             = "EKS secret envelope encryption for ${var.cluster_name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(local.tags, { Name = "${var.cluster_name}-secrets" })
}

resource "aws_kms_alias" "cluster" {
  name          = "alias/eks/${var.cluster_name}"
  target_key_id = aws_kms_key.cluster.key_id
}

#
# Control plane log group
# -----------------------
# EKS creates this group itself on first log write, with retention set to "never
# expire". Creating it here first is the only way to control retention, and it has
# to exist before the cluster or the cluster creates it with the wrong settings.
#
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.cluster_log_retention_days

  tags = local.tags
}

#
# Cluster IAM role
#
data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy",
  ])

  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

#
# Cluster
#
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = local.kubernetes_version

  enabled_cluster_log_types = var.enabled_cluster_log_types

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access ? var.public_access_cidrs : null
  }

  # API, not CONFIG_MAP. The old aws-auth ConfigMap is still honoured in
  # CONFIG_MAP and API_AND_CONFIG_MAP mode, but editing a ConfigMap to grant
  # cluster access has no audit trail and a bad edit locks everyone out with no
  # way back in. Access entries are IAM resources: CloudTrail sees them and
  # terraform can repair them.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.cluster.arn
    }
    resources = ["secrets"]
  }

  # Refuse to drift into extended support, where the control plane costs 6x.
  # An upgrade becomes a deliberate change to var.kubernetes_version instead of
  # a surprise line on the bill.
  upgrade_policy {
    support_type = "STANDARD"
  }

  tags = merge(local.tags, { Name = var.cluster_name })

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

#
# IRSA trust anchor
# -----------------
# Registers the cluster's own OIDC issuer as an identity provider in the account.
# This single resource is what makes "a pod assumes an IAM role" possible without
# any static credentials anywhere.
#
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]

  tags = merge(local.tags, { Name = "${var.cluster_name}-irsa" })
}

#
# Node IAM role
#
data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    # Lets you open a shell on a node through SSM instead of opening port 22 to
    # the world and managing an SSH key. There is no bastion in this project
    # because there does not need to be one.
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

#
# Node security group
# -------------------
# The launch template below attaches BOTH this group and the EKS-managed cluster
# security group. That is not optional: as soon as a managed node group uses a
# launch template with vpc_security_group_ids set, EKS stops attaching the cluster
# security group for you. Forget it and the nodes boot, pass their EC2 health
# check, and never join the cluster.
#
resource "aws_security_group" "node" {
  name        = "${var.cluster_name}-node"
  description = "Additional security group for ${var.cluster_name} worker nodes"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${var.cluster_name}-node" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "node_self" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "-1"
  description                  = "Node to node: pod to pod traffic, CoreDNS, and the kubelet read path"
}

resource "aws_vpc_security_group_egress_rule" "node_all" {
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Egress to the internet via NAT: image pulls, AWS APIs, OS updates"
}

#
# Launch template
# ---------------
# A launch template is here for exactly two reasons that cannot be set on a bare
# managed node group: IMDSv2 enforcement and an encrypted gp3 root volume.
#
# image_id is deliberately absent. Leave it out and EKS supplies the correct
# AL2023 AMI and the bootstrap user data for the cluster version. Set it and you
# own the user data forever, which is a common way to end up with nodes that
# never register.
#
resource "aws_launch_template" "node" {
  for_each = var.node_groups

  name_prefix = "${var.cluster_name}-${each.key}-"
  description = "Worker nodes for ${var.cluster_name} node group ${each.key}"

  vpc_security_group_ids = [
    aws_eks_cluster.this.vpc_config[0].cluster_security_group_id,
    aws_security_group.node.id,
  ]

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = each.value.disk_size_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # IMDSv2 only, and one hop. A compromised pod cannot curl 169.254.169.254 to
  # steal the node role's credentials, which is the whole reason IRSA exists.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "${var.cluster_name}-${each.key}" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.tags, { Name = "${var.cluster_name}-${each.key}" })
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_eks_node_group" "this" {
  for_each = var.node_groups

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-${each.key}"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  instance_types = each.value.instance_types
  capacity_type  = each.value.capacity_type
  labels         = each.value.labels

  scaling_config {
    min_size     = each.value.min_size
    max_size     = each.value.max_size
    desired_size = each.value.desired_size
  }

  launch_template {
    id      = aws_launch_template.node[each.key].id
    version = aws_launch_template.node[each.key].latest_version
  }

  # Replace a third of the group at a time during a version bump instead of one
  # node at a time, which on a three node group is the difference between a six
  # minute upgrade and a twenty minute one.
  update_config {
    max_unavailable_percentage = 33
  }

  dynamic "taint" {
    for_each = each.value.taints

    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = local.tags

  # desired_size is managed by the cluster autoscaler or Karpenter in a real
  # cluster, so terraform must stop fighting it after the initial create.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

#
# Access entries
# --------------
# The creating identity is already admin via bootstrap_cluster_creator_admin_permissions.
# Everything else that needs in, for example the CI apply role, is granted here.
#
resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"

  tags = local.tags
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}
