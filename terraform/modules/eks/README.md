# Module: eks

An EKS cluster with managed node groups, the core addons, and the IAM OIDC
provider that makes IRSA possible.

## Usage

```hcl
module "eks" {
  source = "../../modules/eks"

  cluster_name       = "portfolio-dev"
  kubernetes_version = null            # null = whatever AWS currently defaults to

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids

  public_access_cidrs = ["203.0.113.4/32"]   # your IP

  node_groups = {
    general = {
      instance_types = ["t3.large", "t3a.large"]
      capacity_type  = "SPOT"
      min_size       = 2
      max_size       = 4
      desired_size   = 2
    }
  }

  cluster_admin_principal_arns = [aws_iam_role.ci.arn]
}
```

## Decisions

### The Kubernetes version is not hardcoded

Leave `kubernetes_version = null` and the module asks EKS which versions are on
standard support and takes the one AWS marks as the default for new clusters,
falling back to the newest if the API reports no default.

Two reasons. A repo pinned to `"1.34"` is wrong a few months later. And more
expensively: once a version falls into **extended support** the control plane
goes from $0.10 to $0.60 an hour. The cluster also sets
`upgrade_policy { support_type = "STANDARD" }` so it refuses to drift there.

Pin it explicitly when you want the repo reproducible at a known version.

### `authentication_mode = "API"`

Access entries, not the `aws-auth` ConfigMap.

| | `aws-auth` ConfigMap | access entries |
|---|---|---|
| Audit trail | none, it is a ConfigMap edit | CloudTrail |
| Managed by terraform | awkwardly | natively |
| Recovery from a bad edit | none, everyone is locked out | any principal with `eks:CreateAccessEntry` |

`bootstrap_cluster_creator_admin_permissions = true` grants cluster-admin to
whoever ran the apply. Everyone else goes in `cluster_admin_principal_arns`.

### Secrets are envelope-encrypted with a CMK

Without `encryption_config`, Secret objects sit in EKS-managed etcd encrypted
with an AWS-managed key you cannot audit or revoke. With it, every Secret write
goes through a key you own, so revoking it makes the data unreadable and
CloudTrail shows the `Decrypt` calls.

### The control plane log group is created here

EKS creates it itself on first log write, with retention set to **never
expire**. Creating it first is the only way to control retention, and it has to
exist before the cluster.

### A launch template, for exactly two reasons

Neither can be set on a bare managed node group:

- **IMDSv2 required, hop limit 1.** A compromised pod cannot reach
  `169.254.169.254` to steal the node role's credentials. That is the attack
  IRSA exists to make unnecessary; this closes the other half.
- **Encrypted gp3 root volume.**

`image_id` is deliberately absent. Leave it out and EKS supplies the correct
AL2023 AMI and the bootstrap user data for the cluster version. Set it and you
own the user data forever, which is a common route to nodes that never register.

### The cluster security group is attached explicitly

```hcl
vpc_security_group_ids = [
  aws_eks_cluster.this.vpc_config[0].cluster_security_group_id,   # <- not optional
  aws_security_group.node.id,
]
```

As soon as a managed node group uses a launch template with
`vpc_security_group_ids` set, **EKS stops attaching the cluster security group
for you**. Forget it and the nodes boot, pass their EC2 health check, and never
join the cluster.

### `ignore_changes` on `desired_size`

In a real cluster the autoscaler owns that number. Without this, terraform
fights it on every apply.

## Addons

| Addon | Wave | Why |
|---|---|---|
| `kube-proxy`, `vpc-cni`, `eks-pod-identity-agent` | before nodes | needed as the node joins |
| `coredns` | after nodes | has nowhere to run until a node exists |
| `aws-ebs-csi-driver` | after nodes | with its own IRSA role |

EKS pre-installs the first three as unmanaged versions it will never update.
Declaring them as `aws_eks_addon` with
`resolve_conflicts_on_create = "OVERWRITE"` takes ownership, so upgrades become
a terraform diff rather than a `kubectl patch` nobody remembers doing.

**The EBS CSI driver is not optional in practice.** A fresh cluster has no CSI
driver at all, so the first PersistentVolumeClaim, which here is Prometheus
asking for 20Gi, stays Pending forever with `waiting for a volume to be
created` and no other clue.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `cluster_name` | string | required | Also the prefix for roles, KMS alias and log group. |
| `kubernetes_version` | string | `null` | `null` auto-selects. |
| `vpc_id` | string | required | |
| `private_subnet_ids` | list(string) | required | At least two AZs. |
| `public_subnet_ids` | list(string) | `[]` | For internet-facing load balancers. No node launches here. |
| `endpoint_public_access` | bool | `true` | |
| `public_access_cidrs` | list(string) | `["0.0.0.0/0"]` | **Set this to your own address.** |
| `enabled_cluster_log_types` | list(string) | all five | `audit` and `authenticator` are the useful ones. |
| `cluster_log_retention_days` | number | `7` | |
| `node_groups` | map(object) | one `t3.medium` group | See the variable description. |
| `cluster_admin_principal_arns` | list(string) | `[]` | Extra cluster-admins via access entries. |
| `enable_ebs_csi_driver` | bool | `true` | |
| `tags` | map(string) | `{}` | |

## Outputs

`cluster_name`, `cluster_arn`, `cluster_endpoint`, `cluster_version`,
`cluster_certificate_authority_data`, `cluster_security_group_id`,
`node_security_group_id`, `oidc_provider_arn`, `oidc_provider_url`,
`node_role_arn`, `node_role_name`, `kms_key_arn`, `update_kubeconfig_command`.

`oidc_provider_url` is the issuer host **without** the `https://` prefix,
because that is the form IAM condition keys need. Leaving the scheme on is the
classic reason an IRSA trust policy silently never matches.
