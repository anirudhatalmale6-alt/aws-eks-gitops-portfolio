# Module: ecr

Container image repositories with immutable tags, scanning on push, a lifecycle
policy, and a repository policy that separates who can pull from who can push.

## Usage

```hcl
module "ecr" {
  source = "../../modules/ecr"

  repositories = {
    "portfolio-dev/demo-app" = {
      image_tag_mutability   = "IMMUTABLE"
      untagged_expiry_days   = 7
      keep_last_images       = 20
      protected_tag_prefixes = ["sha-", "v"]
      force_delete           = true
    }
  }

  pull_principal_arns = [module.eks.node_role_arn]
  push_principal_arns = [module.github_oidc.role_arns["ecr-push"]]
}
```

## Decisions

### `IMMUTABLE` tags

A tag, once pushed, can never be moved to a different digest. That is the
difference between `:v1.4.2` meaning one specific artefact forever and meaning
"whatever somebody last pushed".

The practical consequence: a rollback redeploys exactly the bytes that were
running before. With mutable tags, a rollback redeploys whatever currently
answers to that name, which may be the broken build.

**Expected side effect:** re-running a build on an unchanged commit fails with
`ImageTagAlreadyExists`. That is correct. `build-image.yml` checks whether the
tag exists and skips the push rather than failing.

### Pull and push are different principals

Nodes pull. Only the CI image-build role pushes. Nothing running **in** the
cluster can push, which means a compromised pod cannot replace the image it is
running with one of its own.

### Scanning

`scan_on_push` is **basic** scanning: the operating system packages in the
image, checked against the ECR CVE feed, free.

It does **not** look at application dependencies inside the layers, for example
a vulnerable npm or pip package. That needs enhanced scanning, which is Amazon
Inspector reading inside the layers.

Enhanced scanning is behind `enable_enhanced_scanning`, off by default, for two
reasons spelled out in `main.tf`: it is billed per image scanned plus per
re-scan when a new CVE lands, and the setting is **per account per region**, not
per repository. Two copies of this module with different values would fight over
it forever.

### Lifecycle rules, and why order matters

ECR storage is $0.10 per GB per month and a pipeline that pushes on every commit
fills it quickly.

| Priority | Rule |
|---|---|
| 1 | expire untagged images after N days |
| 2 | keep only the newest N images matching the protected tag prefixes |

Rules are evaluated in priority order and **the first match wins**, so the
untagged rule has to come first or untagged layers survive forever.

`protected_tag_prefixes` must match how your pipeline tags. The default is
`["v", "sha-", "main-"]`; this project pushes `sha-<short>`. Get it wrong and
the keep-N rule matches nothing, silently, and old images are never cleaned up.
The variable has a validation rule rejecting an empty list for that reason.

### `force_delete`

`true` here only because this is a demo stack that gets torn down. On anything
real, leave it `false` so `terraform destroy` cannot silently delete the
artefacts you deployed from.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `repositories` | map(object) | required | Keyed by repository name. |
| `kms_key_arn` | string | `null` | `null` uses free AES256. A CMK is ~$1/month plus requests. |
| `pull_principal_arns` | list(string) | `[]` | Normally the EKS node role. |
| `push_principal_arns` | list(string) | `[]` | Normally the CI role only. |
| `enable_enhanced_scanning` | bool | `false` | Account-and-region wide. Read `main.tf` first. |
| `tags` | map(string) | `{}` | |

## Outputs

`repository_urls`, `repository_arns`, `registry_url`, `docker_login_command`.
