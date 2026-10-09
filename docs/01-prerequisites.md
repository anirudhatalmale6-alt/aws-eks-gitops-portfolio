# 01 Prerequisites

## What you need

| | Why |
|---|---|
| An AWS account **you own** | This creates IAM roles and an OIDC identity provider. A company sandbox with a permissions boundary will refuse about half of it. |
| AWS CLI v2, logged in | `aws sts get-caller-identity` must work before anything else does. |
| A GitHub account | The OIDC trust policy names your username. |
| `git`, `python3`, `jq` | `jq` is only used by `scripts/render-manifests.sh`. |
| Docker or Podman | Only to build and test the demo image. |
| About $5 a day while it runs | See [08-cost.md](08-cost.md). |

Everything else, Terraform, tflint, trivy, kubectl, helm and kubeconform, is
installed by `make tools` into `.tools/` at pinned versions with
checksum verification. Nothing is installed system-wide.

## Permissions

The identity you run `terraform apply` as needs to create VPCs, EKS clusters,
IAM roles and an IAM OIDC provider. In a personal account that is your admin
user or an admin role.

If you are using SSO or an assumed role, note which identity it is.
`bootstrap_cluster_creator_admin_permissions = true` grants cluster-admin in
Kubernetes to **whoever ran the apply**, and nobody else. Apply as one identity
and then try to use `kubectl` as a different one and every command returns
`error: You must be logged in to the server (Unauthorized)`. See
[07-troubleshooting.md](07-troubleshooting.md).

## Region

`us-east-1` by default. Anything works, but check two things first:

```sh
# Does the region have at least three availability zones?
aws ec2 describe-availability-zones --region eu-west-2 \
  --filters Name=opt-in-status,Values=opt-in-not-required \
  --query 'length(AvailabilityZones)'

# Is t3.large available there? Some regions have t3a or t4g instead.
aws ec2 describe-instance-type-offerings --region eu-west-2 \
  --filters Name=instance-type,Values=t3.large --query 'length(InstanceTypeOfferings)'
```

If the first returns fewer than three, set `availability_zone_count = 2`.

## Service quotas

A new AWS account has low defaults, and the one that bites is Elastic IPs.

```sh
# Elastic IPs per region. Default is 5. One NAT gateway needs one.
aws service-quotas get-service-quota --service-code ec2 --quota-code L-0263D0A3

# Running on-demand standard vCPUs. Default is often 5, which is not enough
# for two t3.large (4 vCPU) plus anything else you have running.
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A

# VPCs per region. Default is 5.
aws service-quotas get-service-quota --service-code vpc --quota-code L-F678F1CE
```

The vCPU quota is the common one. It fails at node group creation, well after
the VPC and the control plane are built, with
`VcpuLimitExceeded`. A quota increase request is usually
granted within a few hours; ask before you start rather than halfway through.

Spot instances have a **separate** quota, `L-34B43A08`. The default node group
uses spot, so that is the one that matters here.

## First run

```sh
git clone https://github.com/YOUR-USERNAME/aws-eks-gitops-portfolio.git
cd aws-eks-gitops-portfolio

make tools
make validate
```

`make validate` runs twenty-eight checks and touches nothing in AWS. If it is
green, the repository is internally consistent and the problem, when you hit
one, is in your account rather than in the code. That is a useful thing to know
before you start spending money.

Next: [02-backend.md](02-backend.md).
