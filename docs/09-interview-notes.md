# 09 Interview notes

What this project lets you answer, and the answers.

A note on using it. The value of a portfolio project in an interview is not that
it exists, it is that you can be asked a follow-up and keep going. So for each
question below there is the answer, and then **the thing that makes it
credible**: a trade-off you can name, a failure you hit, or a number.

Do not memorise these. Build it, break it, and then these will be things you
remember rather than things you recite.

---

## Terraform and state

### "How do you handle terraform state in a team?"

Remote state in S3 with versioning, encryption at rest, and a bucket policy that
denies non-TLS access. Locking is S3's native lock file: `use_lockfile = true`,
which writes a `.tflock` object next to the state using a conditional
`If-None-Match` write.

**What makes it credible:** "Most guides still say to create a DynamoDB table
for locking. That changed. Terraform 1.10 added native S3 locking, 1.11
deprecated `dynamodb_table`, and it is on its way out. It removes a billable
resource and a failure mode: with a separate table, if somebody deletes it,
applies silently stop locking rather than failing."

### "How do you structure Terraform?"

Five modules that know nothing about environments, and one `envs/dev` directory
that is the only place they are wired together. A staging or prod directory is a
copy of that one file with different tfvars, not a fork of the code.

**Follow-up you should expect:** *"Why not use the community `terraform-aws-modules/eks` module?"*
Because for this purpose, writing the cluster, the node group launch template,
the OIDC provider and the addons directly is the point. Reading the official
module teaches you what it does; writing it teaches you why. In production I
would probably use it, and I would be able to read its source and know what it
was doing.

### "How do you stop infrastructure code going stale?"

The Kubernetes version is not hardcoded. The module queries EKS for the versions
on standard support and takes the one AWS marks as default for new clusters.

**What makes it credible:** "A repo pinned to `"1.34"` is wrong a few months
later, and the cost of being wrong is not cosmetic: a version that falls into
extended support takes the control plane from ten cents an hour to sixty. The
cluster also sets `upgrade_policy { support_type = "STANDARD" }` so it refuses
to drift there silently."

---

## Networking

### "Walk me through your VPC design."

Three AZs. Public subnets are `/24` and hold only NAT gateways and load balancer
ENIs. Private subnets are `/19` and hold everything else.

**The question behind the question** is whether you know *why* the private
subnets are so much bigger. Because the VPC CNI gives every pod a real VPC IP.
A node running 30 pods consumes 31 addresses. A `/24` private subnet runs out
after about eight nodes, and the symptom is pods stuck in `ContainerCreating`
with `failed to assign an IP address to container`, which does not obviously
read as "subnet too small".

### "What would you change for production?"

One NAT gateway is the default here because it saves $66 a month and this is a
demo. In production, one per AZ: a single NAT is a single point of failure for
all outbound traffic, and an AZ failure that takes it out takes every image
pull and every AWS API call with it.

The variable is already there, `single_nat_gateway`, and one route table per
private subnet exists precisely so that flipping it is an in-place route change
rather than a rebuild of the routing layer.

### "Anything you did for cost?"

An S3 gateway endpoint on the private route tables. Every ECR image layer pull
fetches its blobs from S3; without the endpoint that traffic goes out through
the NAT gateway at $0.045 per GB. Gateway endpoints are free. On a cluster that
pulls images all day it is the single cheapest optimisation available.

---

## EKS and Kubernetes

### "How do you grant people access to the cluster?"

EKS access entries, with `authentication_mode = "API"`.

**What makes it credible:** "The older mechanism is the `aws-auth` ConfigMap,
and it has two real problems. Editing a ConfigMap to grant cluster access leaves
no audit trail, and a bad edit locks everyone out with no way back in. Access
entries are IAM resources: CloudTrail sees them, terraform can repair them, and
any principal in the account with `eks:CreateAccessEntry` can restore access if
you lose the creating identity."

### "Explain IRSA."

A pod's service account carries an annotation naming an IAM role. A mutating
webhook injects a projected token into the pod along with `AWS_ROLE_ARN` and
`AWS_WEB_IDENTITY_TOKEN_FILE`. The SDK calls
`sts:AssumeRoleWithWebIdentity` with that token. STS validates the signature
against the cluster's OIDC issuer, which is registered as an IAM identity
provider, and checks the conditions in the trust policy. The pod gets
credentials that expire in an hour and refresh automatically.

**The follow-up:** *"What are the conditions, and why both?"*
`:sub` pins which service account in which namespace may assume the role.
Without it, every pod in the cluster can. `:aud` pins the token audience to
`sts.amazonaws.com`, so a token minted for something else cannot be replayed.

**Credibility detail:** the nodes enforce IMDSv2 with a hop limit of 1, so a
compromised pod cannot reach `169.254.169.254` to steal the node role's
credentials. That is the attack IRSA exists to make unnecessary; closing both
is the point.

### "Pod Identity or IRSA?"

Pod Identity is newer and simpler: an association in EKS rather than a trust
policy per role, and no OIDC provider to manage. This cluster installs the
`eks-pod-identity-agent` addon so it supports both.

IRSA is used because the upstream Helm charts still document service account
annotations, so it is what actually works today without patching charts. For
new in-house workloads I would use Pod Identity.

### "Why no CPU limit on your app container?"

There is a memory limit and deliberately no CPU limit.

A memory limit is a real safety net: exceed it and the container is OOM-killed,
which is better than it eating the node and taking the kubelet with it.

A CPU limit is enforced by CFS throttling, which pauses the process for the
remainder of the 100ms period once the quota is spent. On a bursty web workload
that produces latency spikes on a node with plenty of idle CPU. The *request*
already guarantees a share under contention, so the limit buys nothing and costs
tail latency.

**Be ready to disagree with yourself:** in a multi-tenant cluster with
chargeback, or where one team's runaway loop can starve another's, CPU limits
are the right call. It is a trade, not a rule.

### "How is the workload hardened?"

The namespace enforces the `restricted` Pod Security Standard, which is API
server admission with no extra component to install. That requires
`runAsNonRoot`, `allowPrivilegeEscalation: false`, all capabilities dropped and
a seccomp profile, and the Deployment sets all four.

**The detail that shows it is real:** the image is
`nginx-unprivileged`, not `nginx`. The official nginx image starts as root to
bind port 80 and then drops privileges, so it cannot satisfy `runAsNonRoot` and
the namespace would reject it. The unprivileged variant runs as uid 101 on port
8080. That is the difference between a manifest that claims to be hardened and
one that actually passes admission.

### "Tell me about a bug you hit."

This is the question the whole project is for. Pick one and tell it properly.

> With `readOnlyRootFilesystem: true`, the container needs a writable mount at
> `/etc/nginx/conf.d` because it renders its config at startup. A Kubernetes
> emptyDir arrives owned `root:root` and the container runs as uid 101, so the
> render failed. The base image logged the error **and started anyway**, falling
> back to its packaged default site. The pod was Running. The page looked fine.
> But `/healthz` was a 404, so the probes failed, and the actual cause was one
> line in the startup log.
>
> The fix was two parts. `fsGroup: 101` on the pod so the mount is group-owned
> correctly. And I added an entrypoint script that asserts the rendered config
> is really there and exits non-zero if it is not, so the failure is a
> CrashLoopBackOff with a clear message instead of a Running pod serving the
> wrong thing. There is a test that runs the container both ways: the good case
> must work, the bad case must fail.

That answer demonstrates reading logs, understanding filesystem ownership in
Kubernetes, and the instinct to turn a silent failure into a loud one.

---

## GitOps

### "What is the difference between GitOps and a CI pipeline?"

Push versus pull. A pipeline that ends in `kubectl apply` holds cluster
credentials and the cluster's state is whatever the last job left. GitOps puts
an agent inside the cluster that continuously makes it match git.

**The concrete version:** "In my project the build workflow pushes an image and
then edits the image tag in the kustomization file and commits. That is where it
stops. It has no kubeconfig. Argo CD notices the commit and rolls the
Deployment. Two consequences: `git log` on that file is the complete deployment
history, because there is no other path by which the running image can change;
and a compromised CI workflow cannot deploy to the cluster."

### "What is `selfHeal` and where does it bite?"

It reverts anything changed in the cluster by hand. It bites wherever a
controller legitimately owns a field git also specifies.

Two in this project. The HPA owns `spec.replicas`: git says 3, the HPA says 7,
and without an exception they fight on every reconcile. The Prometheus operator
writes a `caBundle` into its own webhook config, which git cannot know, so Argo
CD would wipe it and break admission. Both handled with the narrowest possible
`ignoreDifferences`.

### "Why sync waves?"

demo-app declares a ServiceMonitor and a PrometheusRule, which are CRDs
kube-prometheus-stack installs. Applied together, demo-app is rejected with
`no matches for kind "ServiceMonitor"`.

**The interesting half:** "Argo CD usually recovers on retry, which is worse
than failing, because the ordering bug is invisible until the day the retry
budget runs out. So there is a check in CI that asserts the wave ordering."

---

## Security

### "How does CI authenticate to AWS?"

GitHub OIDC. No access keys anywhere.

**The follow-up that separates people:** *"What is the common mistake?"*
A trust policy with the `aud` condition but no `sub` condition is assumable by
any GitHub Actions workflow on the internet. So is `sub: repo:*`. My OIDC module
has a validation rule that rejects a subject starting with a wildcard, so the
mistake fails at plan time.

### "Is your CI role least privilege?"

No, and I would rather say so than claim otherwise. A role that builds a VPC, an
EKS cluster and IAM roles needs broad permissions; there is no small policy that
does it.

What it is: bounded by service list, so nothing outside ec2, eks, ecr, elb,
autoscaling, logs, kms and tag. `iam:PassRole` narrowed twice, by resource to
roles with this stack's name prefix and by `iam:PassedToService` to four
services. And an explicit `Deny` on creating users, minting access keys and
removing permissions boundaries, which beats any `Allow` in IAM evaluation and
closes the usual escalation chain.

The next step, if someone asked for it, is a permissions boundary attached to
every role the apply role is allowed to create.

### "What do you do with security scanner findings?"

Three are suppressed in `.trivyignore.yaml`, each with a written reason and an
**expiry date**, so they come back and get looked at again. A fourth, public
subnets auto-assigning public IPs, I fixed rather than suppressed: nothing in
this architecture launches an instance into a public subnet, so the setting was
buying nothing.

**The principle worth saying:** an unexplained suppression is indistinguishable
from a bug someone hid, and a suppression with no end date never gets revisited.

---

## Testing and verification

### "How do you know it works before you deploy it?"

`make validate`, twenty-eight checks, no AWS account needed, and CI runs the
identical script.

**The two worth describing, because they caught real bugs:**

1. The Helm check renders each chart at its pinned version with the values from
   its Argo CD Application, and then asserts the values actually took effect in
   the output. None of these charts ships a `values.schema.json`, so Helm
   accepts an unknown key silently. That found a metrics-server values block
   passing `--kubelet-preferred-address-types` twice.
2. The image check runs the container with a read-only root filesystem and no
   capabilities, and separately asserts it **refuses to start** when its config
   mount is not writable. That is the bug in the "tell me about a bug" answer
   above, now guarded.

**The principle:** a check that can only pass is not a check. Both of those have
a negative control, a deliberately broken input that must fail.

---

## Questions to ask them

Interviews run both ways, and these tell you a lot:

- How do you manage Terraform state, and have you moved off the DynamoDB lock
  table yet?
- Push or pull deployment? If a pipeline holds cluster credentials, what stops
  it being the easiest way into production?
- How do you grant cluster access, `aws-auth` or access entries?
- What is on call like, and what fraction of alerts are actionable?
