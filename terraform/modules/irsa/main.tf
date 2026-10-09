#
# IRSA: IAM Roles for Service Accounts
# ------------------------------------
# What this replaces: an AWS access key pasted into a Kubernetes Secret, mounted
# into a pod, never rotated, and still valid the day someone leaks the manifest.
#
# How it actually works, because this is the single most asked EKS interview
# question:
#
#   1. The pod's service account carries the annotation
#      eks.amazonaws.com/role-arn: <this role>.
#   2. A mutating webhook in the cluster sees that annotation and injects a
#      projected service account token into the pod at
#      /var/run/secrets/eks.amazonaws.com/serviceaccount/token, plus the
#      AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE environment variables.
#   3. The AWS SDK inside the container finds those variables and calls
#      sts:AssumeRoleWithWebIdentity, presenting the token.
#   4. STS validates the token's signature against the cluster's OIDC issuer,
#      which was registered as an IAM identity provider, and checks it against
#      the conditions in the trust policy below.
#   5. The SDK gets temporary credentials that expire in an hour and are renewed
#      automatically. Nothing durable is ever written anywhere.
#
# The two conditions below are both load bearing:
#   :sub - pins which service account in which namespace may assume this role.
#          Omit it and EVERY pod in the cluster can assume it.
#   :aud - pins the token audience to sts.amazonaws.com so a token minted for
#          something else cannot be replayed here.
#
locals {
  tags = merge(var.tags, { "Module" = "irsa" })

  # system:serviceaccount:<namespace>:<name>, which is the exact string the
  # projected token carries in its sub claim.
  subjects = [
    for sa in var.service_accounts :
    "system:serviceaccount:${sa.namespace}:${sa.name}"
  ]
}

data "aws_iam_policy_document" "assume" {
  statement {
    sid     = "AssumeViaClusterOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    # StringLike, not StringEquals, only because a service account name may be
    # given with a wildcard, for example "*-controller". With no wildcard in the
    # name the two behave identically.
    condition {
      test     = "StringLike"
      variable = "${var.oidc_provider_url}:sub"
      values   = local.subjects
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name        = var.role_name
  description = var.description
  path        = var.path

  assume_role_policy = data.aws_iam_policy_document.assume.json

  # A pod that assumes this role gets credentials for at most this long before
  # the SDK has to go back to STS. One hour is the AWS default and the shortest
  # the SDK will transparently handle.
  max_session_duration = var.max_session_duration

  # Hard ceiling on what this role can ever do, independent of the policies
  # attached to it. Even if someone attaches AdministratorAccess later, the
  # effective permissions are the intersection with this boundary.
  permissions_boundary = var.permissions_boundary_arn

  tags = merge(local.tags, { Name = var.role_name })
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = toset(var.managed_policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}

resource "aws_iam_policy" "inline" {
  count = var.policy_json == null ? 0 : 1

  name        = "${var.role_name}-policy"
  path        = var.path
  description = "Permissions for ${var.role_name}"
  policy      = var.policy_json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "inline" {
  count = var.policy_json == null ? 0 : 1

  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.inline[0].arn
}
