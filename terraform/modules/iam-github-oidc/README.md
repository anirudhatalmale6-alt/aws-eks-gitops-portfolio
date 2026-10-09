# Module: iam-github-oidc

GitHub Actions to AWS with no stored credentials. Creates the OIDC identity
provider and any number of roles, each trusted only for specific workflow
contexts.

## Usage

```hcl
module "github_oidc" {
  source = "../../modules/iam-github-oidc"

  name_prefix  = "portfolio-dev"
  github_owner = "your-username"
  github_repo  = "aws-eks-gitops-portfolio"

  roles = {
    terraform-plan = {
      description         = "Read-only plan from pull requests"
      subjects            = ["pull_request"]
      managed_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      policy_json         = data.aws_iam_policy_document.state_access.json
    }

    terraform-apply = {
      subjects    = ["environment:aws-dev"]
      policy_json = data.aws_iam_policy_document.apply.json
    }

    ecr-push = {
      subjects    = ["ref:refs/heads/main", "ref:refs/tags/v*"]
      policy_json = data.aws_iam_policy_document.ecr_push.json
    }
  }
}
```

## Subjects

`subjects` is the part of the OIDC `sub` claim **after**
`repo:<owner>/<name>:`. The module prefixes it for you.

| What the job is | Subject to use |
|---|---|
| a pull request | `pull_request` |
| a push to main | `ref:refs/heads/main` |
| a tag matching v* | `ref:refs/tags/v*` |
| any branch | `ref:refs/heads/*` |
| declares `environment: aws-dev` | `environment:aws-dev` |

**The one that catches people:** declaring an `environment:` in a job replaces
the branch ref in the `sub` claim, it does not add to it. A role trusted for
`ref:refs/heads/main` will **not** match a job that declares an environment.
That is why the branch restriction for the apply role lives on the GitHub
environment's deployment branch policy rather than in the trust policy.

## The mistake this module refuses

A trust policy with the `aud` condition but **no `sub` condition** is assumable
by any GitHub Actions workflow on the internet. So is `sub: "repo:*"`. Both have
appeared in published guides.

The `roles` variable validates that:

- every role has at least one subject,
- no subject starts with a wildcard,
- no subject contains `repo:`, which would mean someone is trying to write the
  full claim and escape the owner/repo scope.

So the mistake fails at `terraform plan`.

## No thumbprint

`thumbprint_list` is deliberately omitted. Since 2023 IAM validates recognised
providers, GitHub included, against its own trust store.

A pinned thumbprint is a scheduled outage: correct until GitHub rotates the
certificate, and then every pipeline in the account stops at once. Plenty of
teams have had that morning.

## One provider per account

AWS allows exactly one identity provider per URL. If the account already has a
GitHub one:

```sh
aws iam list-open-id-connect-providers
```

```hcl
create_oidc_provider       = false
existing_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
```

A validation rule catches `create_oidc_provider = false` with no ARN at plan
time, rather than letting it become a null principal in a trust policy that AWS
rejects with `MalformedPolicyDocument`.

## Wiring the roles into the repository

```sh
terraform output gh_variable_setup_commands
```

prints ready-to-paste `gh variable set` commands.

**Variables, not secrets.** A role ARN is not a credential: knowing it gets you
nothing without a GitHub token whose `sub` matches the trust policy. Storing it
as a secret only masks it in logs, which makes a failed assume-role harder to
debug for no security gain.

## Debugging an assume-role failure

```sh
terraform output -json trusted_subjects
```

against what the job actually sent. To see that, add a step before
`configure-aws-credentials`:

```yaml
- name: Show the OIDC claims
  uses: actions/github-script@v7
  with:
    script: |
      const t = await core.getIDToken('sts.amazonaws.com');
      core.info(JSON.stringify(JSON.parse(
        Buffer.from(t.split('.')[1], 'base64').toString()), null, 2));
```

The token is short-lived and scoped to `sts.amazonaws.com`, but it is still a
credential, so take that step out again once the problem is found.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | string | required | Roles are `<prefix>-<key>`. |
| `path` | string | `/github-actions/` | |
| `github_owner` | string | required | Owner only, no slash. Validated. |
| `github_repo` | string | required | Repo name only, no slash. Validated. |
| `create_oidc_provider` | bool | `true` | |
| `existing_oidc_provider_arn` | string | `null` | Required when the above is false. Validated. |
| `roles` | map(object) | required | See above. |
| `tags` | map(string) | `{}` | |

## Outputs

`oidc_provider_arn`, `role_arns`, `role_names`, `trusted_subjects`,
`gh_variable_commands`.
