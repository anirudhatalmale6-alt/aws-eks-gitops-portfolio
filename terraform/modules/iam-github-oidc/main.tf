#
# GitHub Actions to AWS, with no stored credentials
# -------------------------------------------------
# The thing this replaces: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY sitting in
# GitHub repository secrets. Those are permanent, they are copied into every fork
# of your workflow habits, nobody rotates them, and a leaked workflow log or a
# malicious third-party action walks away with credentials that still work next
# year.
#
# What happens instead, on every single job:
#   1. The workflow asks GitHub for a signed OIDC token. That needs
#      permissions: id-token: write in the workflow, which is why forgetting that
#      one line produces "Credentials could not be loaded".
#   2. The token's sub claim describes exactly where the job is running, for
#      example repo:owner/name:ref:refs/heads/main or repo:owner/name:pull_request.
#   3. aws-actions/configure-aws-credentials sends the token to STS with
#      AssumeRoleWithWebIdentity.
#   4. STS checks GitHub's signature, then checks the sub against the trust
#      policy below.
#   5. The job gets credentials that expire when the job does.
#
# THE MISTAKE THAT MATTERS: a trust policy with the aud condition but no sub
# condition is assumable by any GitHub Actions workflow on the entire internet.
# So is sub = "repo:*". This module refuses both; see the validation on
# var.roles.
#
locals {
  tags = merge(var.tags, { "Module" = "iam-github-oidc" })

  oidc_host = "token.actions.githubusercontent.com"

  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.existing_oidc_provider_arn
}

#
# An AWS account can hold exactly one identity provider per URL. If the account
# already has a GitHub provider, set create_oidc_provider = false and pass its
# ARN instead, or the apply fails with EntityAlreadyExists.
#
# thumbprint_list is deliberately omitted. Since 2023 IAM validates recognised
# providers, GitHub included, against its own trust store. A pinned thumbprint is
# a scheduled outage: it is correct until GitHub rotates the certificate, and
# then every pipeline in the account stops at once.
#
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]

  tags = merge(local.tags, { Name = "github-actions" })
}

data "aws_iam_policy_document" "assume" {
  for_each = var.roles

  statement {
    sid     = "AssumeViaGitHubOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${local.oidc_host}:sub"
      values   = [for s in each.value.subjects : "repo:${var.github_owner}/${var.github_repo}:${s}"]
    }
  }
}

resource "aws_iam_role" "this" {
  for_each = var.roles

  name        = "${var.name_prefix}-${each.key}"
  description = each.value.description
  path        = var.path

  assume_role_policy = data.aws_iam_policy_document.assume[each.key].json

  max_session_duration = each.value.max_session_duration
  permissions_boundary = each.value.permissions_boundary_arn

  tags = merge(local.tags, { Name = "${var.name_prefix}-${each.key}" })
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = merge([
    for role_key, role in var.roles : {
      for arn in role.managed_policy_arns :
      "${role_key}:${arn}" => { role = role_key, arn = arn }
    }
  ]...)

  role       = aws_iam_role.this[each.value.role].name
  policy_arn = each.value.arn
}

resource "aws_iam_policy" "inline" {
  for_each = { for k, v in var.roles : k => v if v.policy_json != null }

  name        = "${var.name_prefix}-${each.key}"
  path        = var.path
  description = "Permissions for ${var.name_prefix}-${each.key}"
  policy      = each.value.policy_json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "inline" {
  for_each = { for k, v in var.roles : k => v if v.policy_json != null }

  role       = aws_iam_role.this[each.key].name
  policy_arn = aws_iam_policy.inline[each.key].arn
}
