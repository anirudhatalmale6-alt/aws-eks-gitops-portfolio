# Module: irsa

"This Kubernetes service account may assume this IAM role." One role, one trust
policy, no static credentials anywhere.

## Usage

```hcl
module "irsa_alb_controller" {
  source = "../../modules/irsa"

  role_name   = "portfolio-dev-aws-load-balancer-controller"
  description = "AWS Load Balancer Controller"

  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url   # no https:// prefix

  service_accounts = [
    { namespace = "kube-system", name = "aws-load-balancer-controller" }
  ]

  policy_json = file("${path.module}/policies/aws-load-balancer-controller.json")
}
```

Then annotate the service account with the output:

```yaml
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: <module output role_arn>
```

## What it replaces

An AWS access key pasted into a Kubernetes Secret, mounted into a pod, never
rotated, and still valid the day someone leaks the manifest.

## How it works

1. The pod's service account carries
   `eks.amazonaws.com/role-arn: <this role>`.
2. A mutating webhook in the cluster sees the annotation and injects a projected
   service account token at
   `/var/run/secrets/eks.amazonaws.com/serviceaccount/token`, plus the
   `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE` environment variables.
3. The AWS SDK inside the container finds those and calls
   `sts:AssumeRoleWithWebIdentity`.
4. STS validates the token's signature against the cluster's OIDC issuer, which
   was registered as an IAM identity provider, and checks the conditions in the
   trust policy.
5. The pod gets credentials that expire in an hour and refresh automatically.
   Nothing durable is written anywhere.

## The two conditions, and why both

```
"<issuer>:sub" = "system:serviceaccount:<namespace>:<name>"
"<issuer>:aud" = "sts.amazonaws.com"
```

- **`:sub`** pins which service account in which namespace may assume this role.
  Omit it and **every pod in the cluster** can.
- **`:aud`** pins the token audience, so a token minted for something else
  cannot be replayed here.

Both are mandatory in this module; there is no option to skip either.

## The mistake this module makes impossible

`oidc_provider_url` must be the issuer host **without** the scheme:

```
oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E   ✓
https://oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B7   ✗
```

IAM condition keys are built from the bare host. Leave the scheme on and the
trust policy is syntactically valid, applies without error, and silently never
matches anything. The variable has a validation rule that rejects it, and the
`eks` module's `oidc_provider_url` output has it stripped already.

## Pod Identity

EKS Pod Identity is the newer alternative: an association in EKS rather than a
trust policy per role, and no OIDC provider to manage. The `eks` module installs
the `eks-pod-identity-agent` addon so the cluster supports both.

IRSA is used here because the upstream Helm charts still document service
account annotations, so it is what works today without patching charts. For new
in-house workloads, Pod Identity is simpler.

## Debugging a trust policy that does not match

```sh
# What the role actually trusts:
terraform output -json | jq '.<module>.value.trusted_subjects'

# What the pod actually presents:
kubectl -n <ns> exec <pod> -- cat /var/run/secrets/eks.amazonaws.com/serviceaccount/token \
  | cut -d. -f2 | base64 -d 2>/dev/null | jq '{sub, aud, iss}'
```

Compare the two strings character by character. It is almost always the
namespace, a typo in the service account name, or the scheme on the issuer.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `role_name` | string | required | |
| `description` | string | generic | Shows in the IAM console. |
| `path` | string | `/eks-irsa/` | Grouping makes these easy to find and easy to scope a boundary to. |
| `oidc_provider_arn` | string | required | From the `eks` module. |
| `oidc_provider_url` | string | required | Bare host, no `https://`. Validated. |
| `service_accounts` | list(object) | required | `{ namespace, name }`. Keep it short. |
| `managed_policy_arns` | list(string) | `[]` | |
| `policy_json` | string | `null` | Build it with `aws_iam_policy_document`. |
| `max_session_duration` | number | `3600` | |
| `permissions_boundary_arn` | string | `null` | A ceiling that survives a wider policy being attached later. |
| `tags` | map(string) | `{}` | |

## Outputs

`role_arn`, `role_name`, `service_account_annotation`, `trusted_subjects`.
