#!/usr/bin/env bash
#
# Install Argo CD and hand the cluster over to it.
#
# Everything this script does is the irreducible bootstrap problem: something
# has to install the thing that installs everything else. After this runs, the
# answer to "how do I change the cluster" is "commit to the repo", and nobody
# should need kubectl again except to look.
#
# Re-running it is safe. Every step is idempotent.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
export PATH="$REPO_ROOT/.tools:$PATH"

ENV_DIR="${ENV_DIR:-terraform/envs/dev}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.4}"
ARGOCD_NAMESPACE="argocd"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

for tool in kubectl terraform; do
  command -v "$tool" >/dev/null || die "$tool not found on PATH"
done

# ---------------------------------------------------------------------------
say "Pointing kubectl at the cluster"
# ---------------------------------------------------------------------------
CLUSTER_NAME="$(terraform -chdir="$ENV_DIR" output -raw cluster_name 2>/dev/null)" \
  || die "Could not read cluster_name. Has terraform applied yet?"
AWS_REGION="$(terraform -chdir="$ENV_DIR" output -json gitops_values | python3 -c 'import json,sys; print(json.load(sys.stdin)["value"]["aws_region"])')"

aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null
note "kubeconfig points at $CLUSTER_NAME in $AWS_REGION"

# Prove the connection before doing anything else. Everything below assumes it,
# and a wrong kubeconfig context is the quietest way to apply manifests to the
# wrong cluster.
kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach the cluster. Check api_public_access_cidrs against your current IP: curl -s ifconfig.me"
note "connected: $(kubectl config current-context)"

ready_nodes="$(kubectl get nodes --no-headers 2>/dev/null | grep -cw Ready || true)"
[[ "$ready_nodes" -ge 1 ]] || die "No Ready nodes. Nothing can be scheduled yet; check the node group in the EKS console."
note "$ready_nodes node(s) Ready"

# ---------------------------------------------------------------------------
say "Making gp3 the only default StorageClass"
# ---------------------------------------------------------------------------
# EKS ships gp2 marked default. kubernetes/platform adds gp3 marked default.
# TWO defaults is a broken cluster: a PVC that does not name a class is refused,
# and the reason appears only as an event on the PVC. Prometheus then sits in
# Pending with no obvious cause.
if kubectl get storageclass gp2 >/dev/null 2>&1; then
  current="$(kubectl get storageclass gp2 \
    -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null || true)"
  if [[ "$current" == "true" ]]; then
    kubectl patch storageclass gp2 -p \
      '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null
    note "removed the default flag from gp2"
  else
    note "gp2 is already not the default"
  fi
else
  note "no gp2 StorageClass on this cluster, nothing to do"
fi

# ---------------------------------------------------------------------------
say "Installing Argo CD $ARGOCD_VERSION"
# ---------------------------------------------------------------------------
# Argo CD is installed with kubectl, not managed by itself, and that is the
# correct answer to "why is this not in git like everything else". Something has
# to exist before the thing that reconciles git can run. Argo CD can be made to
# manage its own upgrades afterwards; the first install cannot come from Argo CD.
kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# Server-side apply: the Argo CD CRDs carry schemas large enough that a
# client-side apply can exceed the 262144 byte annotation limit and fail with
# "metadata.annotations: Too long".
kubectl apply -n "$ARGOCD_NAMESPACE" --server-side --force-conflicts -f "$MANIFEST" >/dev/null
note "applied the Argo CD manifests"

say "Waiting for Argo CD to become available"
for deploy in argocd-repo-server argocd-server argocd-applicationset-controller; do
  kubectl -n "$ARGOCD_NAMESPACE" rollout status "deployment/$deploy" --timeout=5m >/dev/null \
    || die "$deploy did not become ready. 'kubectl -n argocd describe pod' will say why; on a two node cluster it is usually insufficient memory."
  note "$deploy ready"
done
kubectl -n "$ARGOCD_NAMESPACE" rollout status statefulset/argocd-application-controller --timeout=5m >/dev/null
note "argocd-application-controller ready"

# ---------------------------------------------------------------------------
say "Handing the cluster over to git"
# ---------------------------------------------------------------------------
if grep -rq '_PLACEHOLDER' kubernetes/argocd 2>/dev/null; then
  die "kubernetes/argocd still contains placeholders. Run ./scripts/render-manifests.sh, commit and push first, or Argo CD will try to clone a repository called GIT_REPO_URL_PLACEHOLDER."
fi

# Project before Applications: an Application whose project does not exist
# refuses to sync, with a message that does not obviously point at ordering.
kubectl apply -f kubernetes/argocd/projects/portfolio.yaml >/dev/null
note "AppProject applied"

kubectl apply -f kubernetes/argocd/bootstrap/root-app.yaml >/dev/null
note "root Application applied"

say "Done. Argo CD owns the cluster from here."

cat <<EOF

Watch it converge:
  kubectl -n argocd get applications -w

Everything should reach Synced / Healthy in roughly 5 to 10 minutes. The order
is set by sync waves: platform, then the load balancer controller and
metrics-server, then monitoring, then demo-app.

Argo CD UI:
  kubectl -n argocd port-forward svc/argocd-server 8080:443
  open https://localhost:8080        (the certificate is self-signed, that is expected)
  user: admin
  pass: \$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)

Grafana:
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
  open http://localhost:3000
  user: admin
  pass: \$(kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d)

The demo app, once the Ingress has an address (allow 2 to 3 minutes for the ALB):
  kubectl -n demo get ingress demo-app

When you are finished taking screenshots, tear it down. The cluster bills by
the hour whether anyone is looking at it:
  make destroy
EOF
