# 03 CI/CD and GitHub OIDC

## What this replaces

The thing most pipelines do: put `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` in GitHub repository secrets. Those credentials are
permanent. Nobody rotates them. A leaked workflow log, a malicious third-party
action, or a fork of your workflow habits and they still work next year.

There is no access key anywhere in this repository or in its secrets.

## How a job gets credentials

```
  job starts
     │
     ├─ asks GitHub for an OIDC token          ← needs  permissions: id-token: write
     │     the token's "sub" claim describes exactly where the job is running:
     │       repo:you/aws-eks-gitops-portfolio:pull_request
     │       repo:you/aws-eks-gitops-portfolio:environment:aws-dev
     │       repo:you/aws-eks-gitops-portfolio:ref:refs/heads/main
     │
     ├─ aws-actions/configure-aws-credentials sends it to STS
     │     sts:AssumeRoleWithWebIdentity
     │
     ├─ STS verifies GitHub's signature, then checks the sub against the
     │     role's trust policy
     │
     └─ job gets credentials that expire when the job does
```

Forgetting `permissions: id-token: write` produces
`Credentials could not be loaded`, which reads like a secrets problem and is
not one. It is the single most common setup mistake.

## The mistake that matters

A trust policy with the `aud` condition but **no `sub` condition** is assumable
by any GitHub Actions workflow on the internet. So is `sub` of `repo:*`. Both
have appeared in published blog posts.

`terraform/modules/iam-github-oidc` refuses both. The `roles` variable has a
validation rule that rejects a subject starting with a wildcard or containing
`repo:`, so the mistake fails at `terraform plan` rather than becoming a hole
nobody looks at again.

## The three roles

Each is scoped to one job and cannot do the others' work.

| Role | Assumable from | Can do |
|---|---|---|
| `terraform-plan` | `pull_request` | `ReadOnlyAccess`, plus read/write on the state key prefix only |
| `terraform-apply` | `environment:aws-dev` | ec2, eks, ecr, elb, autoscaling, logs, kms, tag, and a narrowed slice of IAM |
| `ecr-push` | `ref:refs/heads/main`, `ref:refs/tags/v*` | push to **one** ECR repository |

### On the apply role being broad

It is, and [`terraform/envs/dev/iam.tf`](../terraform/envs/dev/iam.tf) says so
in a comment rather than claiming otherwise. A role that creates a VPC, an EKS
cluster and IAM roles from nothing needs broad permissions. There is no small
policy that does it.

What it is not is unbounded:

- **Bounded by service.** Anything within that list of services, nothing
  outside it. No RDS, no Lambda, no Organizations, no billing.
- **`iam:PassRole` narrowed twice.** By resource, to roles whose name starts
  with this stack's prefix, so an admin role sitting next to it cannot be
  passed. By `iam:PassedToService`, so even those can only go to EKS, the EKS
  node group service, EC2 and VPC flow logs.
- **An explicit `Deny`** on creating users, minting access keys, attaching
  policies to users or groups, and removing a permissions boundary. An explicit
  `Deny` beats any `Allow` in IAM evaluation, so this holds even if somebody
  later attaches `AdministratorAccess` to the same role.

That closes the usual escalation chain: the pipeline cannot create an identity
for itself and walk out with durable credentials.

## The gate on apply

`terraform-apply` is trusted for `environment:aws-dev` and nothing else. When a
job declares `environment:`, GitHub puts that in the `sub` claim **instead of**
the branch ref, so the branch cannot also be asserted in the trust policy.

The branch restriction therefore lives on the environment. Configure it once:

**Settings → Environments → New environment → `aws-dev`**

| Setting | Value | Effect |
|---|---|---|
| Deployment branches | Selected branches → `main` | A job on any other branch cannot get the token |
| Required reviewers | yourself | An apply waits for a human click |
| Wait timer | optional | A pause in which to cancel |

Without this, the role is assumable from any branch in your repository. With
it, an apply is: open a PR, read the plan comment, merge, then deliberately run
the workflow and approve it.

## Wiring it up

After `make apply`, terraform prints the exact commands:

```sh
terraform -chdir=terraform/envs/dev output github_variable_setup_commands
```

which gives you something like:

```sh
gh variable set AWS_TERRAFORM_PLAN_ROLE_ARN  --repo you/repo --body arn:aws:iam::...:role/...
gh variable set AWS_TERRAFORM_APPLY_ROLE_ARN --repo you/repo --body arn:aws:iam::...:role/...
gh variable set AWS_ECR_PUSH_ROLE_ARN        --repo you/repo --body arn:aws:iam::...:role/...
gh variable set AWS_REGION                   --repo you/repo --body us-east-1
gh variable set ECR_REPOSITORY               --repo you/repo --body eks-gitops-dev/demo-app
gh variable set EKS_CLUSTER_NAME             --repo you/repo --body eks-gitops-dev
gh variable set TF_STATE_BUCKET              --repo you/repo --body eks-gitops-portfolio-tfstate-...
```

**Variables, not secrets.** A role ARN is not a credential: knowing it gets you
nothing without a GitHub token whose `sub` matches the trust policy. Storing it
as a secret only means it is masked in logs, which makes debugging a failed
assume-role harder for no security gain.

## The four workflows

| Workflow | Trigger | AWS | What it does |
|---|---|---|---|
| [`ci.yml`](../.github/workflows/ci.yml) | every push and PR | none | `scripts/validate.sh`: 28 checks. Runs on fork PRs because it needs no credentials. |
| [`terraform-plan.yml`](../.github/workflows/terraform-plan.yml) | PR touching `terraform/**` | plan role | plans and posts the diff as a PR comment, updating the same comment rather than adding one per push |
| [`terraform-apply.yml`](../.github/workflows/terraform-apply.yml) | manual only | apply role | plan to a file, then apply **that file**, so what was reviewed is what is built |
| [`build-image.yml`](../.github/workflows/build-image.yml) | push to `main` touching `app/**` | ecr-push role | build, push, then commit the new tag. No cluster access. |

A few details that are deliberate:

- **`ci.yml` and your laptop run the same script.** `scripts/validate.sh`. That
  is the only way "it passes on my machine" stops being something people say.
- **`terraform-plan` skips on fork PRs.** A fork gets no OIDC token by design,
  or anyone who forked this could assume a role in your account. It skips
  rather than fails, so `ci.yml` remains the meaningful signal.
- **`terraform-apply` has `cancel-in-progress: false`.** Interrupting an apply
  leaves the state lock held and the infrastructure in an unknown state.
- **`build-image` has no `kubectl`.** That is the subject of
  [04-gitops.md](04-gitops.md).

Next: [04-gitops.md](04-gitops.md).
