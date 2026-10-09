# 07 Troubleshooting

Fourteen failures that happen on this stack. Each one is here because the
symptom does not point at the cause, which is the only kind of entry worth
writing down.

Two of them, marked **found while building this**, were hit during development
and are now guarded by a check in `make validate`.

---

## 1. `terraform destroy` fails on a subnet after fifteen minutes

```
Error: deleting EC2 Subnet (subnet-0abc...): DependencyViolation:
The subnet 'subnet-0abc...' has dependencies and cannot be deleted.
```

**Cause.** The AWS Load Balancer Controller created an ALB, its target groups
and its security groups in response to the Ingress. Terraform never created
them, so terraform does not know they exist and will not delete them. They hold
ENIs in the subnets, and a subnet cannot go while an ENI is in it.

**Fix.** Order, not force. Delete the Kubernetes objects first and let the
controller clean up what it owns.

```sh
make destroy        # scripts/teardown.sh does exactly this
```

If you already have the orphan:

```sh
aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<vpc-id> \
  --query 'NetworkInterfaces[].{id:NetworkInterfaceId,desc:Description,status:Status}'
```

The `Description` names what is holding it. Delete that, then destroy again.

---

## 2. Nodes launch, pass their EC2 health check, and never join the cluster

`kubectl get nodes` is empty. The instances are Running in the EC2 console. The
node group eventually reports `NodeCreationFailure: Instances failed to join the
kubernetes cluster`.

**Cause.** As soon as a managed node group uses a launch template with
`vpc_security_group_ids` set, **EKS stops attaching the cluster security group
for you**. Without it the kubelet cannot reach the API server.

**Fix.** Attach both. `terraform/modules/eks/main.tf` does:

```hcl
vpc_security_group_ids = [
  aws_eks_cluster.this.vpc_config[0].cluster_security_group_id,   # not optional
  aws_security_group.node.id,
]
```

**How to confirm:** SSM onto a node (`AmazonSSMManagedInstanceCore` is attached
for exactly this) and run `journalctl -u kubelet -n 100`. A timeout reaching the
API endpoint is the security group. A 401 or 403 is the IAM role.

---

## 3. Every `kubectl` command says `Unauthorized`

```
error: You must be logged in to the server (Unauthorized)
```

**Cause.** `bootstrap_cluster_creator_admin_permissions = true` grants
cluster-admin to **the identity that ran the apply**, and nobody else. You are
now a different one: a different SSO role, a different profile, a different
account.

**Fix.**

```sh
aws sts get-caller-identity          # who am I now
aws eks describe-cluster --name <cluster> \
  --query 'cluster.accessConfig'     # authenticationMode should be API
```

Then, as the identity that created it, grant the new one access:

```sh
aws eks create-access-entry --cluster-name <cluster> --principal-arn <arn>
aws eks associate-access-policy --cluster-name <cluster> --principal-arn <arn> \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

Or add the ARN to `cluster_admin_principal_arns` and re-apply, which is the
version that survives a rebuild.

**If you have lost the creating identity entirely:** access entries are IAM
resources, so any principal with `eks:CreateAccessEntry` in the account can
restore access. That is the practical reason `authentication_mode = "API"` is
better than the old `aws-auth` ConfigMap, where a bad edit locked everyone out
with no way back.

---

## 4. Prometheus sits in Pending forever

```
pod has unbound immediate PersistentVolumeClaims
```

Three different causes, in order of likelihood.

**a. Two default StorageClasses.** EKS ships `gp2` marked default;
`kubernetes/platform` adds `gp3` marked default. With two, a PVC that does not
name a class is refused, and the message is an **event on the PVC**, not
anything `kubectl get pvc` shows.

```sh
kubectl get storageclass          # look for two with (default)
kubectl describe pvc -n monitoring
```

`scripts/deploy.sh` patches the flag off `gp2` and is idempotent.

**b. No EBS CSI driver.** A fresh EKS cluster has no CSI driver at all, so
nothing acts on the PVC and the event says `waiting for a volume to be created`.

```sh
kubectl get pods -n kube-system | grep ebs-csi
```

The `eks` module installs it as an addon with its own IRSA role.

**c. The driver is installed but has no permissions.** It starts fine and then
fails its first `CreateVolume` call.

```sh
kubectl -n kube-system logs deploy/ebs-csi-controller -c ebs-plugin | grep -i denied
```

That means the IRSA trust policy does not match
`system:serviceaccount:kube-system:ebs-csi-controller-sa`.

---

## 5. The Ingress never gets an ADDRESS

Covered in [06-ingress-and-tls.md](06-ingress-and-tls.md). Short version, in
order: controller not running, subnets not tagged `kubernetes.io/role/elb`,
IRSA annotation missing. The controller's own log says which.

---

## 6. The HPA shows `<unknown>/60%` and never scales

```
NAME       REFERENCE             TARGETS         MINPODS   MAXPODS   REPLICAS
demo-app   Deployment/demo-app   <unknown>/60%   3         10        3
```

**Cause.** No `metrics-server`. EKS does not install it, and the HPA reads the
`metrics.k8s.io` API, which only metrics-server (or Prometheus Adapter) serves.
Nothing is marked unhealthy and no event explains it.

**Not** solved by having Prometheus. Prometheus scrapes the same underlying
kubelet metrics but does not serve that API.

```sh
kubectl top nodes        # "Metrics API not available" is the same cause
kubectl get apiservice v1beta1.metrics.k8s.io
```

Installed here as `kubernetes/argocd/applications/11-metrics-server.yaml`.

**While you are there:** most guides tell you to add `--kubelet-insecure-tls`.
That disables certificate verification against the kubelet and is **not needed
on EKS**, where the kubelet serving certificate is signed by the cluster CA
metrics-server already trusts. It is needed on kubeadm and kind clusters, which
is why the advice is everywhere.

---

## 7. Pods stuck in `ContainerCreating`, `failed to assign an IP address`

**Cause.** The VPC CNI gives every pod a real VPC IP out of the node's subnet. A
node running 30 pods consumes 31 addresses. Private subnets sized `/24` run out
after about eight nodes.

**Fix in this repo:** private subnets are `/19`, 8190 usable each.

```sh
aws ec2 describe-subnets --subnet-ids <id> \
  --query 'Subnets[].AvailableIpAddressCount'
kubectl -n kube-system logs -l k8s-app=aws-node --tail=50 | grep -i "no available"
```

If you are already out of space, add a secondary CIDR to the VPC and run the CNI
in custom networking mode. That is a rebuild, which is why the subnet sizing is
worth getting right the first time.

---

## 8. `error acquiring the state lock`

```
Error: Error acquiring the state lock
ConditionalCheckFailed: ... envs/dev/terraform.tfstate.tflock
```

**If something is genuinely running**, wait. `-lock-timeout=10m` makes a CI run
queue rather than fail.

**If a run was killed**, the lock object is orphaned:

```sh
terraform force-unlock <LOCK_ID>        # the ID is in the error message
```

**If it happens on every run with `AccessDenied`**, it is the IAM policy, not a
stale lock. The state policy needs `s3:DeleteObject` on the key prefix:
releasing the lock is a delete, and without it every run leaves a lock behind.
`s3:ListBucket` goes on the **bucket** ARN while the object actions go on the
key prefix; getting that split wrong produces exactly this.

---

## 9. GitHub Actions: `Credentials could not be loaded`

**Cause, nine times out of ten.** The job is missing:

```yaml
permissions:
  id-token: write
```

Without it GitHub will not mint an OIDC token, and the error looks like a
secrets problem.

**Otherwise**, it is the trust policy not matching. The role's
`trusted_subjects` output prints exactly what it expects. Compare against what
the job actually sent:

| Job | Actual `sub` |
|---|---|
| on a branch | `repo:owner/name:ref:refs/heads/main` |
| on a PR | `repo:owner/name:pull_request` |
| with `environment: aws-dev` | `repo:owner/name:environment:aws-dev` |

Note the third: declaring an environment replaces the branch ref in the claim.
A trust policy expecting `ref:refs/heads/main` will not match a job that
declares an environment, and vice versa.

```sh
terraform -chdir=terraform/envs/dev output trusted_subjects
```

**On a fork PR**, there is no token at all, by design. `terraform-plan` skips.

---

## 10. `EntityAlreadyExists` on the GitHub OIDC provider

```
Error: creating IAM OIDC Provider: EntityAlreadyExists:
Provider with url https://token.actions.githubusercontent.com already exists.
```

**Cause.** An AWS account can hold exactly one identity provider per URL, and
yours already has one from another project.

**Fix.**

```sh
aws iam list-open-id-connect-providers
```

then in `terraform.tfvars`:

```hcl
create_github_oidc_provider       = false
existing_github_oidc_provider_arn = "arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com"
```

---

## 11. `ImageTagAlreadyExists` when pushing to ECR

**Cause.** The repository is `IMMUTABLE`, so a tag cannot be moved once pushed.
Re-running the build workflow on an unchanged commit tries to push the same
`sha-<short>` again.

**This is working as intended.** Immutable tags are why `:v1.4.2` means one
specific artefact forever, and why a rollback redeploys exactly what was there
before rather than whatever was pushed last. `build-image.yml` checks whether
the tag exists and skips the push instead of failing.

---

## 12. The app serves a default nginx page, `/healthz` returns 404

**Found while building this.**

**Cause.** The container renders its nginx config at startup into
`/etc/nginx/conf.d`. With `readOnlyRootFilesystem: true` that has to be a
writable mount, and a Kubernetes emptyDir arrives owned `root:root` while the
container runs as uid 101. The image's own script reports:

```
20-envsubst-on-templates.sh: ERROR: /etc/nginx/templates exists,
                             but /etc/nginx/conf.d is not writable
```

and then **carries on**. nginx starts, falls back to the packaged
`default.conf`, and serves a working-looking site with no `/healthz`, no
`/stub_status` and no pod identity. Probes fail with a bare 404 and the real
cause is one line buried in the startup log.

**Fix, two parts.** The pod sets `fsGroup: 101` so the mount is group-owned by
the container's group. And the image now refuses to start at all in that state:
`app/docker-entrypoint.d/25-assert-config-rendered.sh` asserts the rendered
config is present and, if it is not, prints the diagnosis and exits non-zero.

A CrashLoopBackOff with a clear message beats a Running pod serving the wrong
thing. `scripts/check_image.sh` runs both cases on every build: the good one
must work, the bad one must fail.

---

## 13. A Helm value you set has no effect

**Found while building this.**

**Cause.** An unknown key in a Helm values file is **not an error**. None of the
three charts used here ships a `values.schema.json`, so Helm merges whatever you
give it and the templates ignore anything they do not recognise. Verified
directly: rendering each chart with a deliberately invented key exits 0.

So a key renamed in a chart upgrade produces a cluster where the setting you
believed you applied is simply absent, with nothing saying so.

**Fix.** Render the chart and look for the setting in the output.
`scripts/check_helm.sh` does that with eighteen assertions on the rendered
manifests. It found a real one: a `metrics-server` values block that appended
`--kubelet-preferred-address-types` through `args` when the chart already passed
it through `defaultArgs`, launching the container with the flag twice.

```sh
helm template x <chart> --repo <repo> --version <v> -f values.yaml | grep <setting>
```

---

## 14. An Argo CD Application flaps between Synced and OutOfSync

**Cause.** Something in the cluster is writing to a field that git also
specifies, so Argo CD reverts it, the controller rewrites it, forever.

Two instances in this project, both handled with `ignoreDifferences`:

- **The HPA owns `spec.replicas`.** Git says 3; the HPA says 7. Without the
  exception, `selfHeal` scales it back to 3 on every reconcile.
- **The Prometheus operator writes a `caBundle`** into its own webhook
  configuration. Git cannot know that value, so Argo CD would wipe it and break
  admission.

To find which field:

```sh
kubectl -n argocd get app <name> -o jsonpath='{.status.conditions}'
# or in the UI: App Details -> Diff
```

Then add the narrowest possible exception:

```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    name: demo-app
    jsonPointers: [/spec/replicas]
```

Resist widening it. An `ignoreDifferences` that covers a whole object means Argo
CD has stopped managing that object and nobody will notice.

---

## General approach

When something in the cluster is wrong, in this order:

```sh
kubectl get events -A --sort-by=.lastTimestamp | tail -30   # usually enough
kubectl -n <ns> describe pod <pod>                          # Events at the bottom
kubectl -n <ns> logs <pod> -c <container> --previous        # --previous after a restart
kubectl -n argocd get applications                          # is git even applied
```

For AWS-side problems, CloudTrail answers "was the call made, and was it
allowed":

```sh
aws cloudtrail lookup-events --max-results 20 \
  --lookup-attributes AttributeKey=EventName,AttributeValue=CreateLoadBalancer
```

And the cluster's own audit log, which this project enables, answers the same
question for the Kubernetes API:

```sh
aws logs tail /aws/eks/<cluster>/cluster --since 30m --filter-pattern '"Forbidden"'
```

Next: [08-cost.md](08-cost.md).
