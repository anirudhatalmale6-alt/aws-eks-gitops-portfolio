#
# Policies for the three CI roles
# ===============================
#
# An honest note about the apply role, because this is where portfolio projects
# usually cheat and attach AdministratorAccess with a comment saying "tighten
# later".
#
# A role that builds a VPC, an EKS cluster and IAM roles from nothing genuinely
# needs broad permissions. There is no small policy that can do it. What you CAN
# do, and what is done below, is bound it by service rather than leave it at
# "*": the role can do anything within ec2, eks, ecr, iam, kms, logs,
# elasticloadbalancing, autoscaling and the one state bucket, and nothing at all
# outside that list. No RDS, no Lambda, no Organizations, no billing, no
# ability to create a user and hand out keys to it.
#
# That is a real reduction in blast radius and it is defensible in an interview,
# which is better than claiming a least-privilege policy that is actually
# admin with extra steps. The next step past this, if someone asks, is a
# permissions boundary attached to every role the apply role is allowed to
# create, so a compromised pipeline cannot mint itself something wider.
#

#
# State access, shared by plan and apply
# --------------------------------------
# Four permissions on the state object and its lock file. ListBucket is on the
# bucket ARN; the object permissions are on the key prefix. Getting that split
# wrong is the most common cause of "Error acquiring the state lock:
# AccessDenied" on an otherwise correct setup.
#
data "aws_iam_policy_document" "terraform_state_access" {
  statement {
    sid    = "ListStateBucket"
    effect = "Allow"

    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]
  }

  statement {
    sid    = "ReadWriteOwnState"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      # DeleteObject is what releases the .tflock file at the end of a run.
      # Without it every run leaves a stale lock behind and the next one blocks.
      "s3:DeleteObject",
    ]

    resources = [
      "${local.state_bucket_arn}/envs/${var.environment}/*",
    ]
  }
}

data "aws_iam_policy_document" "terraform_apply" {
  source_policy_documents = [data.aws_iam_policy_document.terraform_state_access.json]

  statement {
    sid    = "InfrastructureServices"
    effect = "Allow"

    actions = [
      "ec2:*",
      "eks:*",
      "ecr:*",
      "elasticloadbalancing:*",
      "autoscaling:*",
      "logs:*",
      "kms:*",
      "tag:*",
    ]

    resources = ["*"]
  }

  # IAM is separated out so the deny below can carve the dangerous parts back
  # out of it without touching the services above.
  statement {
    sid    = "IamForClusterAndWorkloads"
    effect = "Allow"

    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:ListRoles",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:ListPolicies",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider",
      "iam:ListOpenIDConnectProviders",
      "iam:TagOpenIDConnectProvider",
      "iam:CreateServiceLinkedRole",
      "iam:ListInstanceProfiles",
      "iam:ListInstanceProfilesForRole",
    ]

    resources = ["*"]
  }

  #
  # PassRole, kept separate and conditioned
  # ---------------------------------------
  # iam:PassRole on "*" is a privilege escalation primitive, not a convenience:
  # it lets the holder hand ANY role in the account to a service that will then
  # act with it. "Create an EC2 instance, pass it the admin role, read the
  # credentials off the instance metadata" is the classic chain.
  #
  # So it is narrowed twice over:
  #
  #   by resource - only roles whose name starts with this stack's prefix, which
  #                 is every role this project creates and nothing else in the
  #                 account. An admin role sitting next to it cannot be passed.
  #   by service  - only to the services that legitimately need a role here:
  #                 EKS for the cluster role, the EKS node group service and EC2
  #                 for the node instance profile, and VPC flow logs.
  #
  statement {
    sid    = "PassOnlyThisStacksRolesAndOnlyToClusterServices"
    effect = "Allow"

    actions = ["iam:PassRole"]

    resources = [
      # Roles at the IAM root path, for example eks-gitops-dev-cluster.
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.name}-*",
      # IRSA roles, which this project groups under a path of their own.
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/eks-irsa/${local.name}-*",
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"

      values = [
        "eks.amazonaws.com",
        "eks-nodegroup.amazonaws.com",
        "ec2.amazonaws.com",
        "vpc-flow-logs.amazonaws.com",
      ]
    }
  }

  # The hard stop. Even though the statements above are broad, the pipeline can
  # never create a human or machine user, never mint a long-lived access key,
  # never attach a policy to a user or group, and never widen a permissions
  # boundary. An explicit Deny beats any Allow in IAM evaluation, so this holds
  # even if someone later attaches AdministratorAccess to the same role.
  statement {
    sid    = "DenyIdentityEscalation"
    effect = "Deny"

    actions = [
      "iam:CreateUser",
      "iam:DeleteUser",
      "iam:CreateAccessKey",
      "iam:UpdateAccessKey",
      "iam:CreateLoginProfile",
      "iam:UpdateLoginProfile",
      "iam:AttachUserPolicy",
      "iam:PutUserPolicy",
      "iam:AttachGroupPolicy",
      "iam:PutGroupPolicy",
      "iam:CreateGroup",
      "iam:DeleteUserPermissionsBoundary",
      "iam:DeleteRolePermissionsBoundary",
      "iam:CreateSAMLProvider",
      "iam:UpdateSAMLProvider",
      "organizations:*",
      "account:*",
      "aws-portal:*",
    ]

    resources = ["*"]
  }
}

#
# ECR push
# --------
# GetAuthorizationToken is the one action that cannot be scoped to a repository,
# because the token is issued per registry. Everything else is restricted to the
# single repository this project builds into, so a compromised build job cannot
# push into any other repository in the account.
#
data "aws_iam_policy_document" "ecr_push" {
  statement {
    sid       = "RegistryAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PushToThisRepositoryOnly"
    effect = "Allow"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      # Read-back actions, needed so the workflow can check whether a tag
      # already exists before trying to push an immutable tag twice.
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
      "ecr:GetDownloadUrlForLayer",
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${local.ecr_repository_name}",
    ]
  }
}
