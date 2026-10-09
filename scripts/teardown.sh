#!/usr/bin/env bash
#
# Tear the whole stack down, in the order that actually works.
#
# THE REASON THIS SCRIPT EXISTS
# -----------------------------
# `terraform destroy` on its own fails on this stack, and the failure is slow
# and confusing. It looks like this:
#
#   Error: deleting EC2 Subnet (subnet-0abc...): DependencyViolation:
#   The subnet 'subnet-0abc...' has dependencies and cannot be deleted.
#
# after roughly fifteen minutes of waiting.
#
# The cause: the AWS Load Balancer Controller created an ALB, its target groups
# and its security groups in response to an Ingress object. Terraform never
# created those, so terraform does not know they exist and will not delete
# them. They hold ENIs in the subnets, and the subnets cannot go while the ENIs
# are there.
#
# The fix is ordering, not force. Delete the Kubernetes objects first and let
# the controller clean up the AWS resources it owns, THEN destroy the
# infrastructure. That is what this does.
#
# Same class of problem, same fix: EBS volumes from PersistentVolumeClaims.
# Those are reclaimPolicy Delete, so removing the namespaces releases them.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
export PATH="$REPO_ROOT/.tools:$PATH"

ENV_DIR="${ENV_DIR:-terraform/envs/dev}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '    \033[33m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
say "What is about to be destroyed"
# ---------------------------------------------------------------------------
if CLUSTER_NAME="$(terraform -chdir="$ENV_DIR" output -raw cluster_name 2>/dev/null)"; then
  note "cluster:  $CLUSTER_NAME"
else
  note "No terraform outputs. Either nothing is deployed, or the backend is not initialised."
  CLUSTER_NAME=""
fi

if [[ "$AUTO_APPROVE" != "true" ]]; then
  echo
  read -r -p "This deletes the cluster and everything in it. Type 'destroy' to continue: " reply
  [[ "$reply" == "destroy" ]] || { echo "Aborted."; exit 1; }
fi

# ---------------------------------------------------------------------------
say "Step 1: remove the Kubernetes objects that own AWS resources"
# ---------------------------------------------------------------------------
if [[ -n "$CLUSTER_NAME" ]] && kubectl cluster-info >/dev/null 2>&1; then

  # Deleting the root Application cascades, because of the
  # resources-finalizer.argocd.argoproj.io finalizer on it: Argo CD removes the
  # child Applications, which remove their workloads, which removes the Ingress.
  if kubectl -n argocd get application root >/dev/null 2>&1; then
    note "deleting the root Argo CD Application (cascades to everything it manages)"
    kubectl -n argocd delete application root --wait=true --timeout=5m || warn "root Application deletion timed out, continuing"
  fi

  # Belt and braces. If Argo CD was already gone, or a finalizer hung, these
  # objects may still be there, and they are the ones that matter.
  note "deleting any remaining Ingress and LoadBalancer Services"
  kubectl delete ingress --all --all-namespaces --timeout=3m 2>/dev/null || true
  for svc in $(kubectl get svc --all-namespaces \
        -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    ns="${svc%%/*}"; name="${svc##*/}"
    note "  deleting Service $ns/$name"
    kubectl -n "$ns" delete svc "$name" --timeout=3m 2>/dev/null || true
  done

  # PVCs hold EBS volumes. reclaimPolicy is Delete, so removing the PVC removes
  # the volume. Leave them and you keep paying for orphaned gp3 volumes long
  # after the cluster is gone.
  note "deleting PersistentVolumeClaims"
  kubectl delete pvc --all -n monitoring --timeout=3m 2>/dev/null || true
  kubectl delete pvc --all -n demo --timeout=3m 2>/dev/null || true

  # The controller needs a moment to finish the delete calls it was just asked
  # to make. Going straight to terraform destroy races it.
  say "Step 2: waiting for AWS to release the load balancers"
  note "the controller deletes the ALB, its target groups and its security groups"
  deadline=$(( SECONDS + 300 ))
  while (( SECONDS < deadline )); do
    remaining="$(aws elbv2 describe-load-balancers \
      --query "length(LoadBalancers[?contains(to_string(@), '${CLUSTER_NAME}')])" \
      --output text 2>/dev/null || echo 0)"
    [[ "$remaining" == "0" || -z "$remaining" ]] && break
    note "  $remaining load balancer(s) still present, waiting..."
    sleep 15
  done

  if (( SECONDS >= deadline )); then
    warn "Still waiting after 5 minutes. terraform destroy may fail with"
    warn "DependencyViolation on a subnet. If it does, find the leftover with:"
    warn "  aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<vpc id>"
    warn "and delete whatever is holding the ENI, then run this again."
  else
    note "load balancers are gone"
  fi

else
  warn "Cannot reach the cluster, skipping the Kubernetes cleanup."
  warn "If terraform destroy then fails on a subnet DependencyViolation, that is why:"
  warn "an ALB created by the controller is still holding an ENI in the subnet."
fi

# ---------------------------------------------------------------------------
say "Step 3: terraform destroy"
# ---------------------------------------------------------------------------
destroy_args=(-input=false)
[[ "$AUTO_APPROVE" == "true" ]] && destroy_args+=(-auto-approve)

terraform -chdir="$ENV_DIR" destroy "${destroy_args[@]}"

# ---------------------------------------------------------------------------
say "Step 4: what is deliberately left behind"
# ---------------------------------------------------------------------------
cat <<'EOF'
    Two things survive on purpose.

    The S3 state bucket (terraform/bootstrap). It is not force_destroy, because
    it holds the only record of what exists in the account. Removing it is a
    conscious act:

      aws s3 rm s3://<bucket> --recursive
      cd terraform/bootstrap && terraform destroy

    The CloudWatch log groups, which have a 7 day retention and expire on their
    own. Their cost is pennies, and keeping them a week means the audit log of
    the cluster outlives the cluster, which is occasionally exactly what you
    want.

    Worth a check afterwards, because an orphan here is a bill with no cluster
    attached to explain it:

      aws ec2 describe-volumes --filters Name=status,Values=available
      aws ec2 describe-addresses --query 'Addresses[?AssociationId==null]'
      aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
EOF
