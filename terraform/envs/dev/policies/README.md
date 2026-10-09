# Vendored IAM policies

## `aws-load-balancer-controller.json`

Taken verbatim from the controller's own release, not hand-written.

| | |
|---|---|
| Source | `https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.6.0/docs/install/iam_policy.json` |
| Release | `v3.6.0`, which is what Helm chart `aws-load-balancer-controller` **3.6.0** installs |
| Statements | 16 |
| Distinct actions | 80 |
| Changes applied | re-indented to 2 spaces, nothing else |

### Why it is vendored rather than fetched

A `terraform apply` that pulls a policy off the internet is an apply whose result
depends on what GitHub served that minute. Vendoring means the policy is in
`git log`, a change to it shows up in code review, and the stack builds the same
way in six months.

### Why it is not trimmed

It is tempting to cut this down: 80 actions looks excessive for "create a load
balancer". Every attempt to trim it by hand ends the same way. The controller
provisions an ALB successfully, then fails somewhere later with a permission
error that surfaces as an Ingress stuck without an address, or a target group
with no registered targets, and the controller log is the only place that says
why. The actions it needs depend on which annotations you use, so a policy
trimmed against today's manifests breaks the first time someone adds
`alb.ingress.kubernetes.io/certificate-arn`.

Note that the policy is already conditioned upstream: most of the destructive
actions are gated on `aws:ResourceTag/elbv2.k8s.aws/cluster`, so the controller
can only modify load balancers it created itself.

### Refreshing it

```sh
VERSION=v3.6.0   # match the chart's appVersion
curl -fsSL -o aws-load-balancer-controller.json \
  "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${VERSION}/docs/install/iam_policy.json"
```

Then bump the chart's `targetRevision` in
`kubernetes/argocd/applications/10-aws-load-balancer-controller.yaml` in the same
commit, so the policy and the controller never disagree about which version this
cluster runs.

Checked while writing this: the policy published for `v2.14.0` and the one
published for `v3.6.0` are byte-for-byte identical, so upgrading the controller
across that major version does not require an IAM change. Verify it again rather
than assuming it next time.
