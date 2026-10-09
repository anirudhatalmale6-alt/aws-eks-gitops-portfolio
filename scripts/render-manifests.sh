#!/usr/bin/env bash
#
# Fill the placeholders in the Kubernetes manifests from the terraform outputs.
#
# Why placeholders at all
# -----------------------
# Four values are only knowable after terraform has run: the cluster name, the
# VPC id, the ECR repository URL and the IRSA role ARN. Two of those embed your
# AWS account ID. Committing them means a public portfolio repository publishes
# your account number, and means the repo only works for one person.
#
# So the committed manifests carry placeholders, and this script substitutes
# them IN PLACE, into files that are then committed to YOUR fork. That commit is
# what Argo CD syncs. It is a one-time step per cluster.
#
# Run it after `terraform apply`, review the diff, then commit.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ENV_DIR="${ENV_DIR:-terraform/envs/dev}"
export PATH="$REPO_ROOT/.tools:$PATH"

command -v terraform >/dev/null || { echo "terraform not found on PATH" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found on PATH; install it or read the values out of 'terraform output' by hand" >&2; exit 1; }

echo "Reading outputs from $ENV_DIR ..."
outputs="$(terraform -chdir="$ENV_DIR" output -json)" || {
  cat >&2 <<'EOF'
Could not read terraform outputs.

If this says "No outputs found", the stack has not been applied yet. If it says
the backend is not initialised, run:

  terraform -chdir=terraform/envs/dev init -backend-config=backend.hcl
EOF
  exit 1
}

get() {
  local key="$1"
  local value
  value="$(jq -r --arg k "$key" '.[$k].value // empty' <<<"$outputs")"
  if [[ -z "$value" || "$value" == "null" ]]; then
    echo "terraform output '$key' is empty. Has the stack finished applying?" >&2
    exit 1
  fi
  printf '%s' "$value"
}

CLUSTER_NAME="$(get cluster_name)"
VPC_ID="$(get vpc_id)"
ECR_REPOSITORY_URL="$(get ecr_repository_url)"
ALB_ROLE_ARN="$(get aws_load_balancer_controller_role_arn)"
AWS_REGION="$(jq -r '.gitops_values.value.aws_region' <<<"$outputs")"
GIT_REPO_URL="$(jq -r '.gitops_values.value.git_repo_url' <<<"$outputs")"

# The git remote is the authority on where Argo CD should look. The terraform
# variable is a guess built from github_owner and github_repo, and if someone
# forked the repo under a different name, the remote is right and the variable
# is wrong.
if remote="$(git remote get-url origin 2>/dev/null)"; then
  # Normalise an SSH remote (git@github.com:owner/repo.git) to the HTTPS form
  # Argo CD wants.
  normalised="$(sed -E 's#^git@([^:]+):#https://\1/#' <<<"$remote")"
  [[ "$normalised" == *.git ]] || normalised="${normalised}.git"
  if [[ "$normalised" != "$GIT_REPO_URL" ]]; then
    echo "Note: using the git remote, not the terraform guess."
    echo "      terraform: $GIT_REPO_URL"
    echo "      remote:    $normalised"
    GIT_REPO_URL="$normalised"
  fi
fi

cat <<EOF

Substituting:
  CLUSTER_NAME_PLACEHOLDER            -> $CLUSTER_NAME
  AWS_REGION_PLACEHOLDER              -> $AWS_REGION
  VPC_ID_PLACEHOLDER                  -> $VPC_ID
  ECR_REPOSITORY_URL_PLACEHOLDER      -> $ECR_REPOSITORY_URL
  ALB_CONTROLLER_ROLE_ARN_PLACEHOLDER -> $ALB_ROLE_ARN
  GIT_REPO_URL_PLACEHOLDER            -> $GIT_REPO_URL

EOF

changed=0
while IFS= read -r file; do
  grep -q '_PLACEHOLDER' "$file" || continue

  # A temp file plus mv, rather than sed -i, so an interrupted run cannot leave
  # a half-written manifest behind.
  tmp="$(mktemp)"
  sed -e "s|CLUSTER_NAME_PLACEHOLDER|${CLUSTER_NAME}|g" \
      -e "s|AWS_REGION_PLACEHOLDER|${AWS_REGION}|g" \
      -e "s|VPC_ID_PLACEHOLDER|${VPC_ID}|g" \
      -e "s|ECR_REPOSITORY_URL_PLACEHOLDER|${ECR_REPOSITORY_URL}|g" \
      -e "s|ALB_CONTROLLER_ROLE_ARN_PLACEHOLDER|${ALB_ROLE_ARN}|g" \
      -e "s|GIT_REPO_URL_PLACEHOLDER|${GIT_REPO_URL}|g" \
      "$file" > "$tmp"
  mv "$tmp" "$file"
  echo "  rendered $file"
  changed=$((changed + 1))
done < <(find kubernetes -name '*.yaml' -print | sort)

if (( changed == 0 )); then
  echo "Nothing to do: no placeholders left. Already rendered."
  exit 0
fi

# Prove it. A substitution that silently missed a file would otherwise only
# surface as an Argo CD Application pointing at a repository called
# GIT_REPO_URL_PLACEHOLDER.
if remaining="$(grep -rl '_PLACEHOLDER' kubernetes 2>/dev/null)"; then
  echo >&2
  echo "FAILED: placeholders still present after substitution:" >&2
  printf '  %s\n' $remaining >&2
  exit 1
fi

cat <<EOF

Rendered $changed file(s), no placeholders remain.

Next:
  git diff                       review it
  git add kubernetes && git commit -m "chore: render manifests for $CLUSTER_NAME"
  git push

Argo CD reads this from GitHub, not from your working copy, so nothing happens
until it is pushed.
EOF
