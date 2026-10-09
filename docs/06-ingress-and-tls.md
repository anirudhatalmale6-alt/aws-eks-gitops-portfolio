# 06 Ingress and TLS

## What exists now

One Ingress, `kubernetes/apps/demo-app/ingress.yaml`, which the AWS Load
Balancer Controller turns into an internet-facing ALB listening on port 80.

```sh
make url
# http://k8s-demo-demoapp-1a2b3c4d5e-123456789.us-east-1.elb.amazonaws.com
```

Allow two to three minutes after the first sync. An ALB is not instant.

## HTTP only, and why that is stated rather than hidden

HTTPS needs an ACM certificate. An ACM certificate needs a domain you own and
can validate. This repository cannot assume you have one.

The alternative, shipping a commented-out `certificate-arn` line that nobody
fills in, is worse: it looks like TLS was considered and done, and it quietly
is not. So the Ingress says plainly in a comment that HTTPS is not configured,
and this page says what to add.

## Adding TLS

You need a domain in Route 53 or wherever, then:

```sh
aws acm request-certificate \
  --domain-name demo.example.com \
  --validation-method DNS \
  --region us-east-1          # MUST be the ALB's region, not us-east-1 by habit
```

ACM prints a CNAME to add to your DNS. Validation completes in a few minutes.
Then three annotations and one rule:

```yaml
metadata:
  annotations:
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:...:certificate/...
    # Redirect every plaintext request to HTTPS at the load balancer, so no
    # request reaches a pod unencrypted and the app needs no redirect logic.
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    # TLS 1.2 minimum. The default policy still permits TLS 1.0.
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
spec:
  rules:
    - host: demo.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: demo-app
                port:
                  name: http
```

Two things that catch people:

- **The certificate must be in the same region as the ALB.** A certificate in
  `us-east-1` for an ALB in `eu-west-1` is not an error you get told about
  clearly; the listener just never gets created. (`us-east-1` is only special
  for CloudFront.)
- **`ssl-redirect` needs HTTP to still be in `listen-ports`.** Remove port 80
  and there is nothing left to redirect from, so plain-HTTP visitors get a
  connection refused instead of a redirect.

### DNS

Point the domain at the ALB with an ALIAS record, not a CNAME at the apex:

```sh
ADDR=$(kubectl -n demo get ingress demo-app \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "$ADDR"
```

`external-dns` can automate this from the Ingress `host` field. It is not
installed here because it needs a Route 53 hosted zone and an IRSA role of its
own, and the IRSA module in this repository is exactly the piece you would use
to add it.

## Why `target-type: ip`

```yaml
alb.ingress.kubernetes.io/target-type: ip
```

This registers the **pod** IPs directly with the ALB target group.

The alternative, `instance`, registers the **nodes** and relies on a NodePort.
Every request then takes an extra kube-proxy hop to find a pod, and the ALB
health check tests the node rather than the pod, so a node with one unhealthy
pod still reports healthy.

With the VPC CNI giving every pod a real VPC address there is no reason to take
that hop. Draining also works per pod rather than per node, which is what makes
`maxUnavailable: 0` on the rolling update actually mean something.

## Why the health check is on `/healthz`

```yaml
alb.ingress.kubernetes.io/healthcheck-path: /healthz
```

Not `/`. If `/` ever starts returning a redirect, or a 404 after a bad deploy,
the target group still knows the truth. `/healthz` exists only to answer that
question and is excluded from the access log so it does not pollute request
metrics.

## Publishing Grafana

If you want Grafana reachable rather than port-forwarded, do it properly:

1. An **internal** scheme (`alb.ingress.kubernetes.io/scheme: internal`) plus a
   VPN or a bastion, or
2. internet-facing **with** TLS and real authentication in front of it:
   `alb.ingress.kubernetes.io/auth-type: oidc` and an identity provider, or ALB
   authentication through Cognito.

Grafana on a public ALB with the chart's generated password and no TLS is an
open admin panel. Search engines find those.

## When the Ingress has no ADDRESS

In order, this is what to check:

```sh
# 1. Is the controller running at all?
kubectl -n kube-system get deploy aws-load-balancer-controller

# 2. What is it saying? This is almost always where the answer is.
kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=100

# 3. Are the public subnets tagged? Without kubernetes.io/role/elb = 1 the
#    controller logs "unable to discover at least one subnet".
aws ec2 describe-subnets --filters Name=vpc-id,Values=<vpc-id> \
  --query 'Subnets[].{id:SubnetId,tags:Tags}'

# 4. Can it call AWS? "AccessDenied" means the IRSA annotation on the service
#    account is missing or names the wrong role.
kubectl -n kube-system get sa aws-load-balancer-controller -o yaml | grep role-arn
```

More in [07-troubleshooting.md](07-troubleshooting.md).

Next: [07-troubleshooting.md](07-troubleshooting.md).
