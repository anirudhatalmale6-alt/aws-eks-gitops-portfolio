#
# Cluster addons
# --------------
# EKS pre-installs vpc-cni, coredns and kube-proxy on a new cluster, but as
# unmanaged versions it will never update. Declaring them as aws_eks_addon takes
# ownership so upgrades are a terraform diff rather than a kubectl patch nobody
# remembers doing. resolve_conflicts_on_create = OVERWRITE is what lets terraform
# adopt the copies EKS already put there.
#
locals {
  # coredns has nowhere to run until there is a node, and kube-proxy wants to be
  # present before the node joins. Order is therefore not cosmetic.
  core_addons = {
    "kube-proxy" = { before_nodes = true }
    "vpc-cni"    = { before_nodes = true }
    "coredns"    = { before_nodes = false }
    # Required by Pod Identity, the newer alternative to IRSA. Installed so the
    # cluster supports both association styles; this project uses IRSA because
    # the upstream Helm charts still document service account annotations.
    "eks-pod-identity-agent" = { before_nodes = true }
  }
}

data "aws_eks_addon_version" "core" {
  for_each = local.core_addons

  addon_name         = each.key
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

resource "aws_eks_addon" "pre_node" {
  for_each = { for k, v in local.core_addons : k => v if v.before_nodes }

  cluster_name  = aws_eks_cluster.this.name
  addon_name    = each.key
  addon_version = data.aws_eks_addon_version.core[each.key].version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.tags
}

resource "aws_eks_addon" "post_node" {
  for_each = { for k, v in local.core_addons : k => v if !v.before_nodes }

  cluster_name  = aws_eks_cluster.this.name
  addon_name    = each.key
  addon_version = data.aws_eks_addon_version.core[each.key].version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.tags

  depends_on = [aws_eks_node_group.this]
}

#
# EBS CSI driver
# --------------
# Not optional in practice. A fresh EKS cluster has no CSI driver at all, so the
# first PersistentVolumeClaim, which on this project is Prometheus asking for
# 20Gi, stays Pending forever with "waiting for a volume to be created" and no
# other clue. The driver needs its own IAM role because it calls CreateVolume and
# AttachVolume on behalf of the cluster.
#
data "aws_iam_policy_document" "ebs_csi_assume" {
  count = var.enable_ebs_csi_driver ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }

    # Both conditions are needed. Without the :sub check any service account in
    # the cluster could assume this role; without the :aud check the token
    # audience is unverified.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  count = var.enable_ebs_csi_driver ? 1 : 0

  name               = "${var.cluster_name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume[0].json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  count = var.enable_ebs_csi_driver ? 1 : 0

  role       = aws_iam_role.ebs_csi[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

data "aws_eks_addon_version" "ebs_csi" {
  count = var.enable_ebs_csi_driver ? 1 : 0

  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

resource "aws_eks_addon" "ebs_csi" {
  count = var.enable_ebs_csi_driver ? 1 : 0

  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = data.aws_eks_addon_version.ebs_csi[0].version
  service_account_role_arn = aws_iam_role.ebs_csi[0].arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.tags

  depends_on = [
    aws_eks_node_group.this,
    aws_iam_role_policy_attachment.ebs_csi,
  ]
}
