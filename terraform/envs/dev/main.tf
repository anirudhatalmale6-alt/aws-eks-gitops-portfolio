#
# dev environment
# ===============
# This is the only place where modules are wired together. Modules themselves
# contain no environment-specific values, which is what makes a staging or prod
# directory a copy of this file with different tfvars rather than a fork of the
# code.
#
data "aws_availability_zones" "available" {
  state = "available"

  # Local Zones and Wavelength Zones show up in this list and EKS cannot use
  # them. Asking for opt-in-not-required leaves only the standard AZs.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name = "${var.project}-${var.environment}"

  availability_zones = slice(
    data.aws_availability_zones.available.names,
    0,
    var.availability_zone_count,
  )

  ecr_repository_name = "${local.name}/demo-app"

  state_bucket_arn = "arn:${data.aws_partition.current.partition}:s3:::${var.state_bucket_name}"
}

#
# 1. Network
#
module "vpc" {
  source = "../../modules/vpc"

  name               = local.name
  cidr_block         = var.vpc_cidr
  availability_zones = local.availability_zones
  single_nat_gateway = var.single_nat_gateway
  enable_flow_logs   = var.enable_flow_logs
  eks_cluster_name   = local.name

  tags = var.tags
}

#
# 2. Cluster
#
module "eks" {
  source = "../../modules/eks"

  cluster_name       = local.name
  kubernetes_version = var.kubernetes_version

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids

  endpoint_public_access = true
  public_access_cidrs    = var.api_public_access_cidrs

  node_groups = {
    general = {
      instance_types = var.node_instance_types
      capacity_type  = var.node_capacity_type
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size
      disk_size_gb   = 40
      labels = {
        "workload" = "general"
      }
    }
  }

  # The CI apply role has to be able to talk to the cluster as well, otherwise a
  # pipeline that creates the cluster cannot read a single thing inside it.
  cluster_admin_principal_arns = [module.github_oidc.role_arns["terraform-apply"]]

  enable_ebs_csi_driver = true

  tags = var.tags
}

#
# 3. Image registry
#
module "ecr" {
  source = "../../modules/ecr"

  repositories = {
    (local.ecr_repository_name) = {
      image_tag_mutability = "IMMUTABLE"
      untagged_expiry_days = 7
      keep_last_images     = 20
      # Images are tagged with the short commit SHA, so that is the prefix the
      # keep-N rule has to match.
      protected_tag_prefixes = ["sha-", "v"]
      # True only because this is a demo stack that gets torn down. On anything
      # real, leave it false so terraform destroy cannot silently delete the
      # artefacts you deployed from.
      force_delete = true
    }
  }

  # Nodes pull. Only the CI image-build role pushes. Nothing running in the
  # cluster can overwrite an image.
  pull_principal_arns = [module.eks.node_role_arn]
  push_principal_arns = [module.github_oidc.role_arns["ecr-push"]]

  # Account-and-region wide setting and billed per scan, so off by default here.
  enable_enhanced_scanning = false

  tags = var.tags
}

#
# 4. GitHub Actions access, no stored keys
#
module "github_oidc" {
  source = "../../modules/iam-github-oidc"

  name_prefix  = local.name
  github_owner = var.github_owner
  github_repo  = var.github_repo

  create_oidc_provider       = var.create_github_oidc_provider
  existing_oidc_provider_arn = var.existing_github_oidc_provider_arn

  roles = {
    # Runs on pull requests. Read everything, write nothing except the state
    # lock file, because `terraform plan` has to take the lock.
    terraform-plan = {
      description = "Read-only terraform plan from pull requests"
      subjects    = ["pull_request"]
      managed_policy_arns = [
        "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess",
      ]
      policy_json = data.aws_iam_policy_document.terraform_state_access.json
    }

    # Gated on a GitHub deployment environment rather than on a branch.
    #
    # When a job declares `environment: aws-dev`, GitHub puts
    # ...:environment:aws-dev in the sub claim INSTEAD of the branch ref, so the
    # branch cannot also be asserted here. The branch restriction therefore has
    # to be configured on the environment itself, in
    # Settings > Environments > aws-dev > Deployment branches, limited to main.
    # Do that and you also get the required-reviewer gate for free, which means
    # an apply needs a human click. docs/03-cicd.md spells out those settings.
    terraform-apply = {
      description = "terraform apply, gated on the aws-dev GitHub environment"
      subjects = [
        "environment:aws-dev",
      ]
      policy_json          = data.aws_iam_policy_document.terraform_apply.json
      max_session_duration = 3600
    }

    # Build and push container images. Cannot touch anything except ECR.
    ecr-push = {
      description = "Push container images to ECR from main"
      subjects = [
        "ref:refs/heads/main",
        "ref:refs/tags/v*",
      ]
      policy_json = data.aws_iam_policy_document.ecr_push.json
    }
  }

  tags = var.tags
}

#
# 5. IRSA role for the AWS Load Balancer Controller
# -------------------------------------------------
# Without this controller an Ingress object is inert: nothing creates an ALB and
# the Ingress never gets an ADDRESS. The controller is installed by Argo CD, but
# its IAM role has to exist first, because the chart's service account carries
# the role ARN as an annotation at install time.
#
module "irsa_aws_load_balancer_controller" {
  source = "../../modules/irsa"

  role_name   = "${local.name}-aws-load-balancer-controller"
  description = "AWS Load Balancer Controller for ${local.name}"

  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url

  service_accounts = [
    {
      namespace = "kube-system"
      name      = "aws-load-balancer-controller"
    }
  ]

  # Taken verbatim from the controller's own release, not hand-written, because
  # hand-trimming this policy is how people end up with an ALB that provisions
  # but never registers targets. The file records which release it came from.
  policy_json = file("${path.module}/policies/aws-load-balancer-controller.json")

  tags = var.tags
}
