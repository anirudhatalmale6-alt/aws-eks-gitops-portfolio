# 08 Cost

The single most expensive mistake with this project is leaving it running.

## What the defaults cost

us-east-1 list prices. `terraform output cost_note` prints a figure computed
from what was actually created, so it follows your settings rather than this
table.

| | Rate | Per day | Per month |
|---|---|---|---|
| EKS control plane | $0.10/hr | $2.40 | $73.00 |
| NAT gateway × 1 | $0.045/hr | $1.08 | $32.85 |
| 2 × t3.large **spot** | ~$0.025/hr each | ~$1.20 | ~$36.50 |
| ALB | $0.0225/hr + LCU | ~$0.55 | ~$16.50 |
| EBS gp3, ~30 GiB | $0.08/GiB-mo | ~$0.08 | ~$2.40 |
| Elastic IP (attached) | free | 0 | 0 |
| CloudWatch Logs, 7 day retention | ~$0.50/GB | pennies | ~$1 |
| S3 state | pennies | 0 | ~$0.10 |
| **Total** | | **~$5.30** | **~$162** |

Plus data processing: NAT at $0.045/GB and ALB LCUs. On a demo with no real
traffic both are cents.

**Two days of screenshots is about eleven dollars. A month of forgetting is a
hundred and sixty.**

## What moves the number

| Change | Effect | Cost |
|---|---|---|
| `single_nat_gateway = false` | one NAT per AZ, no single point of failure for egress | **+$66/mo** |
| `node_capacity_type = "ON_DEMAND"` | no interruptions | **+$85/mo** |
| `availability_zone_count = 2` | with per-AZ NAT, one fewer | −$33/mo |
| `node_desired_size = 1` | will not fit the full stack, see below | −$18/mo |
| `enable_enhanced_scanning = true` | Inspector reads inside image layers | per scan, account-wide |
| drifting into EKS extended support | | **control plane ×6, $438/mo** |

That last one deserves emphasis. Once a Kubernetes version leaves standard
support the control plane goes from $0.10 to $0.60 an hour. This stack sets
`upgrade_policy { support_type = "STANDARD" }` so it refuses to drift there, and
leaves the version selection to the live API rather than a hardcoded string that
goes stale.

## Why two nodes, not one

Argo CD, kube-prometheus-stack, metrics-server, the load balancer controller and
three demo replicas do not fit on one `t3.large`. A single node leaves pods
Pending with `Insufficient memory`, which looks like a bug and is arithmetic.

Rough floor:

| | memory requested |
|---|---|
| Argo CD (5 components) | ~700 Mi |
| kube-prometheus-stack | ~1.6 Gi |
| metrics-server × 2 | 128 Mi |
| ALB controller × 2 | 192 Mi |
| CoreDNS, kube-proxy, CNI, EBS CSI | ~400 Mi |
| demo-app × 3 (both containers) | ~150 Mi |
| **Total** | **~3.2 Gi** |

A `t3.large` is 8 GiB nominal, of which roughly 7.1 GiB is allocatable after the
kubelet's reservations. One node would technically fit it, with no headroom for
a rolling update and nothing left when a spot instance is reclaimed. Two is the
honest minimum.

## Why spot is the default

Roughly 70 percent off, and for a portfolio cluster the interruption risk is
irrelevant: if a node goes away, the node group replaces it and the
PodDisruptionBudget keeps two replicas serving.

Being able to say *why you would not* do this in production is the more useful
half of the answer: a stateful workload needs PodDisruptionBudgets that are
actually honoured, a node termination handler to drain on the two-minute
warning, and a diverse instance type list so the pool has somewhere to go.
`node_instance_types` lists three types for exactly that reason.

## Keeping the bill honest

**Set a budget before you apply.** AWS Budgets is free and the alert arrives
before the invoice does.

```sh
cat > /tmp/budget.json <<'EOF'
{
  "BudgetName": "eks-portfolio",
  "BudgetLimit": {"Amount": "50", "Unit": "USD"},
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST"
}
EOF
aws budgets create-budget \
  --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --budget file:///tmp/budget.json
```

**Everything is tagged.** `default_tags` on the provider puts `Project`,
`Environment`, `ManagedBy` and `Repository` on every resource, including the
ones created inside modules that never thought about tagging. Activate `Project`
as a cost allocation tag in Billing and Cost Explorer will break the bill down
by it, which is the only way tagging is actually useful.

**Check for orphans after a teardown.** These are the three that cost money with
no cluster attached to explain them:

```sh
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].{id:VolumeId,size:Size,created:CreateTime}'

aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].PublicIp'

aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
```

An unattached Elastic IP is $3.60 a month doing nothing. Since February 2024
AWS charges for them whether or not they are in use.

## The one-line habit

```sh
make destroy
```

Run it when you are done for the day. `make apply` takes fifteen to twenty
minutes to bring it all back, which is a reasonable price for not paying $5 a
day to have a cluster nobody is looking at.

Next: [09-interview-notes.md](09-interview-notes.md).
