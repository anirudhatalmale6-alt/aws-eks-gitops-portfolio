#
# Remote state backend
# ====================
#
# Chicken and egg: the S3 bucket that holds terraform state cannot itself be
# stored in that bucket before it exists. So this one directory runs with LOCAL
# state, creates the bucket, and then step 2 of docs/02-backend.md migrates its
# own state into the bucket it just made. After that there is no local state
# anywhere in the project.
#
# State LOCKING, and why there is no DynamoDB table here
# ------------------------------------------------------
# Every tutorial still tells you to create a DynamoDB table with a LockID hash
# key and pass dynamodb_table to the backend. That advice is out of date.
#
#   - Terraform 1.10 added native S3 locking: the backend writes a
#     <key>.tflock object next to the state file using a conditional
#     write (If-None-Match), which S3 has supported atomically since
#     August 2024. Whoever creates the object holds the lock.
#   - Terraform 1.11 deprecated the dynamodb_table argument.
#   - Terraform 1.12 and later warn on it, and it is slated for removal.
#
# So the current, supported configuration is `use_lockfile = true` and no table.
# That also removes a resource from the bill and removes the failure mode where
# the lock table was deleted and every apply started racing silently.
#
# If an interviewer asks "how do you do state locking", this is the answer worth
# giving, because it shows you are reading release notes and not blog posts from
# 2019.
#

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # The bucket name has to be globally unique across all of AWS, so the account
  # ID is appended rather than asking you to invent something nobody has taken.
  bucket_name = coalesce(
    var.state_bucket_name,
    "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}",
  )

  tags = merge(var.tags, {
    Project   = var.project
    Component = "terraform-backend"
    ManagedBy = "terraform"
  })
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  # Deliberately NOT force_destroy. This bucket holds the only record of what
  # exists in the account. Deleting it by accident means every future apply tries
  # to build everything again, on top of what is already there, and most of those
  # creates fail on name conflicts. Emptying it has to be a conscious manual act.
  force_destroy = false

  tags = merge(local.tags, { Name = local.bucket_name })
}

# Versioning is not optional on a state bucket. A corrupted or truncated state
# push is recoverable only because the previous version is still there.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }

    # Cuts KMS request costs by reusing a data key for objects with the same
    # prefix. Irrelevant with AES256, significant once a CI pipeline is reading
    # state on every pull request.
    bucket_key_enabled = var.kms_key_arn != null
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# State files are small but every apply writes a new version. Without this rule
# the bucket accumulates every version of every state file forever.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = var.state_version_retention_days
      newer_noncurrent_versions = var.state_versions_to_keep
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

data "aws_iam_policy_document" "state" {
  # Refuse any request that did not arrive over TLS. Without this, a bucket
  # policy audit flags the bucket, and more practically a misconfigured client
  # could ship state, which contains every resource ID and sometimes secrets, in
  # the clear.
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Belt and braces on encryption: reject an upload that explicitly asks for no
  # server side encryption, even though the bucket default would have applied it.
  statement {
    sid    = "DenyUnencryptedObjectUploads"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = var.kms_key_arn == null ? ["AES256", "aws:kms"] : ["aws:kms"]
    }

    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}
