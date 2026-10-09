locals {
  tags = merge(var.tags, { "Module" = "ecr" })
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_ecr_repository" "this" {
  for_each = var.repositories

  name = each.key

  # IMMUTABLE means a tag, once pushed, can never be moved to a different digest.
  # It is the difference between "deploy :v1.4.2" meaning one specific artefact
  # forever and meaning "whatever someone last pushed". Mutable tags are how a
  # rollback silently redeploys the broken image.
  image_tag_mutability = each.value.image_tag_mutability

  # Basic scanning: every push is checked against the ECR CVE feed for operating
  # system packages. It is free. It does NOT look at application dependencies
  # inside the layers, for example a vulnerable npm or pip package. That needs
  # enhanced scanning, which is the aws_ecr_registry_scanning_configuration
  # resource below and is billed per image scanned.
  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = var.kms_key_arn == null ? "AES256" : "KMS"
    kms_key         = var.kms_key_arn
  }

  force_delete = each.value.force_delete

  tags = merge(local.tags, { Name = each.key })
}

#
# Lifecycle policy
# ----------------
# ECR storage is 0.10 USD per GB per month and a CI pipeline that pushes on every
# commit fills it quickly with images nobody will ever pull again. Rules are
# evaluated in priority order and the first match wins, so the untagged rule has
# to come before the keep-N rule or untagged layers survive.
#
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = var.repositories

  repository = aws_ecr_repository.this[each.key].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after ${each.value.untagged_expiry_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = each.value.untagged_expiry_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the newest ${each.value.keep_last_images} images tagged ${join(" or ", each.value.protected_tag_prefixes)}"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = each.value.protected_tag_prefixes
          countType     = "imageCountMoreThan"
          countNumber   = each.value.keep_last_images
        }
        action = { type = "expire" }
      },
    ]
  })
}

#
# Repository policy
# -----------------
# Pulls are granted to the node role, so pods can start, and optionally to other
# accounts. Pushes are granted to the CI role only. Nothing in the cluster can
# push, which means a compromised pod cannot replace the image it is running.
#
data "aws_iam_policy_document" "repository" {
  for_each = var.repositories

  dynamic "statement" {
    for_each = length(var.pull_principal_arns) > 0 ? [1] : []

    content {
      sid    = "AllowPull"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = var.pull_principal_arns
      }

      actions = [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
      ]
    }
  }

  dynamic "statement" {
    for_each = length(var.push_principal_arns) > 0 ? [1] : []

    content {
      sid    = "AllowPush"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = var.push_principal_arns
      }

      actions = [
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:BatchCheckLayerAvailability",
      ]
    }
  }
}

resource "aws_ecr_repository_policy" "this" {
  for_each = {
    for name, cfg in var.repositories : name => cfg
    if length(var.pull_principal_arns) > 0 || length(var.push_principal_arns) > 0
  }

  repository = aws_ecr_repository.this[each.key].name
  policy     = data.aws_iam_policy_document.repository[each.key].json
}

#
# Enhanced scanning (optional, off by default)
# --------------------------------------------
# This is Amazon Inspector reading inside the layers, so it catches a vulnerable
# application dependency that basic scanning cannot see.
#
# Two things make it dangerous to switch on casually. It is billed per image
# scanned plus per re-scan when a new CVE lands, and the setting is PER ACCOUNT
# PER REGION, not per repository. Two copies of this module in the same account
# with different values would fight over it forever, which is why it is a
# separate opt-in flag and the dev environment leaves it off.
#
resource "aws_ecr_registry_scanning_configuration" "this" {
  count = var.enable_enhanced_scanning ? 1 : 0

  scan_type = "ENHANCED"

  rule {
    scan_frequency = "SCAN_ON_PUSH"

    repository_filter {
      filter      = "*"
      filter_type = "WILDCARD"
    }
  }
}
