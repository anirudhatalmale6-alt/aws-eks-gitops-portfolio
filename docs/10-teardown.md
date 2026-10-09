# 10 Teardown

```sh
make destroy
```

That is the whole thing. The rest of this page is why it is not just
`terraform destroy`, and how to check you actually stopped paying.

## Why order matters

`terraform destroy` on its own fails on this stack, slowly:

```
Error: deleting EC2 Subnet (subnet-0abc...): DependencyViolation:
The subnet 'subnet-0abc...' has dependencies and cannot be deleted.
```

after about fifteen minutes of waiting.

The AWS Load Balancer Controller created an ALB, its target groups and its
security groups in response to the Ingress object. Terraform never created
them, so terraform does not know they exist and will not delete them. They hold
ENIs in the subnets, and a subnet cannot be deleted while an ENI is in it.

The fix is ordering, not force:

| Step | What | Why |
|---|---|---|
| 1 | Delete the root Argo CD Application | Cascades, via its finalizer, to every child Application and their workloads, which removes the Ingress |
| 2 | Delete any remaining Ingress and `type: LoadBalancer` Services | In case Argo CD was already gone or a finalizer hung |
| 3 | Delete the PVCs | `reclaimPolicy: Delete`, so this releases the EBS volumes |
| 4 | Wait for AWS to report the load balancers gone | The controller's delete calls are asynchronous; going straight to terraform races them |
| 5 | `terraform destroy` | Now there is nothing holding an ENI |

`scripts/teardown.sh` does all five, waits up to five minutes at step 4, and
tells you what to look at if it times out.

## If it fails anyway

Find what is holding the ENI. The `Description` field names it.

```sh
VPC=$(terraform -chdir=terraform/envs/dev output -raw vpc_id)

aws ec2 describe-network-interfaces --filters Name=vpc-id,Values="$VPC" \
  --query 'NetworkInterfaces[].{id:NetworkInterfaceId,desc:Description,status:Status,sg:Groups[0].GroupName}' \
  --output table
```

Common ones:

| Description starts with | What it is | Delete |
|---|---|---|
| `ELB app/k8s-...` | an ALB the controller made | `aws elbv2 delete-load-balancer --load-balancer-arn ...` |
| `ELB net/k8s-...` | an NLB from a `type: LoadBalancer` Service | same |
| `aws-K8S-i-...` | a pod ENI from the VPC CNI | goes when the node does |
| `Amazon EKS <cluster>` | a control plane ENI | goes when the cluster does |

Then `make destroy` again. It is idempotent.

## What is deliberately left behind

**The S3 state bucket.** It is not `force_destroy`, because it holds the only
record of what exists in the account. Removing it is a conscious act:

```sh
aws s3 rm "s3://$(terraform -chdir=terraform/bootstrap output -raw state_bucket_name)" --recursive
terraform -chdir=terraform/bootstrap destroy
```

Note that versioning is on, so `rm --recursive` leaves the old versions. To
empty it completely you need to delete the versions too, which the console's
"Empty bucket" button does in one click and is genuinely the easier route.

**The CloudWatch log groups.** 7 day retention, so they expire on their own.
Their cost is pennies, and keeping them a week means the cluster's audit log
outlives the cluster, which is occasionally exactly what you want.

**The GitHub OIDC provider**, if you set `create_github_oidc_provider = false`
because the account already had one. Terraform will not delete what it did not
create.

## Checking you actually stopped paying

Three things cost money with no cluster attached to explain them. Run these
after every teardown:

```sh
# Orphaned EBS volumes. A PVC that was not deleted before the cluster leaves
# these behind at $0.08/GiB-month, forever.
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].{id:VolumeId,size:Size,created:CreateTime}' --output table

# Unattached Elastic IPs. $3.60/month each, charged since February 2024 whether
# or not they are in use.
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].PublicIp' --output table

# Load balancers. ~$16/month each.
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output table
```

And the authoritative check, a day or two later, which catches anything the
three above miss:

```sh
aws ce get-cost-and-usage \
  --time-period Start=$(date -d '7 days ago' +%Y-%m-%d),End=$(date +%Y-%m-%d) \
  --granularity DAILY --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[-1].Groups[?Metrics.UnblendedCost.Amount>`0.01`].[Keys[0],Metrics.UnblendedCost.Amount]' \
  --output table
```

Cost Explorer data lags by about a day, so a teardown this morning will still
show yesterday's spend. What you are looking for is the day **after** the
teardown being near zero.

## Bringing it back

```sh
make init && make apply && make render && make deploy
```

Fifteen to twenty minutes, most of it the EKS control plane. That is a
reasonable price for not paying five dollars a day to have a cluster nobody is
looking at.

The state bucket survives, so `make bootstrap` is not needed again. The manifest
placeholders will already be rendered from last time, but the cluster name, VPC
id and role ARNs are new, so run `make render` again and commit the diff.
