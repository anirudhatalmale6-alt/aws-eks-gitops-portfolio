#!/usr/bin/env bash
#
# Everything that can be checked without an AWS account
# =====================================================
# This is the whole offline test suite, and it is the same script CI runs. If it
# is green, the repository is consistent with itself: the Terraform parses and
# type-checks, the policies are the shape IAM expects, every Kubernetes manifest
# validates against the real API schemas including CRDs, and every Helm values
# block is valid for the exact chart version it is pinned to.
#
# What it CANNOT tell you: whether AWS will accept the plan. Service quotas,
# capacity, and IAM evaluation against your actual account only show up at
# apply. See docs/07-troubleshooting.md.
#
# Usage:
#   ./scripts/validate.sh            run everything
#   ./scripts/validate.sh terraform  run one section (terraform|kubernetes|docs|helm|docker)
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Tools are looked for on PATH first, then in .tools/, so this works both in CI
# (where a setup action installs them) and on a workstation where they were
# dropped into the repo.
export PATH="$REPO_ROOT/.tools:$PATH"

KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.33.0}"
CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

PASS=0
FAIL=0
SKIP=0
FAILED_CHECKS=()

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
if [[ ! -t 1 || -n "${NO_COLOR:-}" ]]; then c_red=; c_grn=; c_yel=; c_dim=; c_off=; fi

section() { printf '\n%s== %s ==%s\n' "$c_dim" "$1" "$c_off"; }

# check <name> <command...>
check() {
  local name="$1"; shift
  local out status
  out="$("$@" 2>&1)"; status=$?
  if (( status == 0 )); then
    printf '  %sPASS%s  %s\n' "$c_grn" "$c_off" "$name"
    PASS=$((PASS + 1))
  else
    printf '  %sFAIL%s  %s\n' "$c_red" "$c_off" "$name"
    printf '%s\n' "$out" | sed 's/^/        /'
    FAIL=$((FAIL + 1))
    FAILED_CHECKS+=("$name")
  fi
}

skip() {
  printf '  %sSKIP%s  %s %s(%s)%s\n' "$c_yel" "$c_off" "$1" "$c_dim" "$2" "$c_off"
  SKIP=$((SKIP + 1))
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Terraform
# ---------------------------------------------------------------------------
check_terraform() {
  section "Terraform"

  if ! have terraform; then
    skip "terraform" "terraform not installed"
    return
  fi

  check "terraform fmt (whole tree)" terraform fmt -check -recursive

  local dirs=(terraform/bootstrap terraform/envs/dev)
  while IFS= read -r d; do dirs+=("$d"); done < <(find terraform/modules -mindepth 1 -maxdepth 1 -type d | sort)

  for d in "${dirs[@]}"; do
    # -backend=false: validation must not need credentials or a state bucket.
    check "terraform init  $d" terraform -chdir="$d" init -backend=false -input=false -no-color
    check "terraform validate  $d" terraform -chdir="$d" validate -no-color
  done

  if have tflint; then
    check "tflint --recursive" tflint --recursive --no-color
  else
    skip "tflint" "not installed"
  fi

  if have trivy; then
    # HIGH and CRITICAL block. MEDIUM and LOW are reported by the CI workflow
    # but do not fail the build. Accepted findings live in .trivyignore.yaml,
    # each with a reason and an expiry date.
    # .tools and .helm hold downloaded binaries and vendored chart tarballs.
    # They are gitignored, they are not this repository's code, and scanning
    # them means reporting findings in upstream charts that nobody here can
    # fix. .terraform is the provider cache.
    check "trivy config (HIGH, CRITICAL)" \
      trivy config --quiet --ignorefile .trivyignore.yaml \
        --skip-dirs .tools --skip-dirs .helm --skip-dirs "**/.terraform" \
        --severity HIGH,CRITICAL --exit-code 1 .
  else
    skip "trivy" "not installed"
  fi

  # The vendored IAM policy has to stay valid JSON with the shape IAM expects.
  check "IAM policy JSON is well formed" \
    python3 "$REPO_ROOT/scripts/check_iam_policies.py"
}

# ---------------------------------------------------------------------------
# Kubernetes
# ---------------------------------------------------------------------------
check_kubernetes() {
  section "Kubernetes manifests"

  check "every YAML parses" python3 "$REPO_ROOT/scripts/check_yaml.py"

  if ! have kubectl; then
    skip "kustomize build" "kubectl not installed"
    skip "kubeconform" "kubectl not installed"
    return
  fi

  local built
  built="$(mktemp)"
  if check "kustomize build  kubernetes/apps/demo-app" \
       bash -c "kubectl kustomize kubernetes/apps/demo-app > '$built'"; then :; fi

  # The kustomize images transformer has to actually fire. If it silently stops
  # matching, the Deployment deploys an image called literally "demo-app" and
  # the pods sit in ImagePullBackOff pointing at Docker Hub.
  check "kustomize rewrote the app image" \
    python3 "$REPO_ROOT/scripts/check_kustomize_image.py" "$built"

  if have kubeconform; then
    check "kubeconform  rendered demo-app" \
      kubeconform -strict -summary -kubernetes-version "$KUBERNETES_VERSION" \
        -schema-location default -schema-location "$CRD_SCHEMAS" "$built"

    check "kubeconform  argocd and platform" \
      kubeconform -strict -summary -kubernetes-version "$KUBERNETES_VERSION" \
        -schema-location default -schema-location "$CRD_SCHEMAS" \
        kubernetes/argocd kubernetes/platform
  else
    skip "kubeconform" "not installed"
  fi

  check "Grafana dashboard JSON is valid and non-empty" \
    python3 "$REPO_ROOT/scripts/check_dashboard.py"

  check "sync waves are ordered and unique where it matters" \
    python3 "$REPO_ROOT/scripts/check_sync_waves.py"

  rm -f "$built"
}

# ---------------------------------------------------------------------------
# Documentation
# ---------------------------------------------------------------------------
check_docs() {
  section "Documentation"

  # A comment that sends a reader to docs/07-troubleshooting.md when no such
  # file exists is worse than no comment at all.
  check "every relative link and docs/ reference resolves" \
    python3 "$REPO_ROOT/scripts/check_docs_links.py"
}

# ---------------------------------------------------------------------------
# Helm
# ---------------------------------------------------------------------------
# Renders each chart at the EXACT pinned version using the values block lifted
# out of its Argo CD Application. This is what catches a values key that was
# renamed between chart versions, which otherwise shows up as a setting that is
# silently ignored in a running cluster.
# ---------------------------------------------------------------------------
check_helm() {
  section "Helm charts (rendered at pinned versions)"

  if ! have helm; then
    skip "helm template" "helm not installed"
    return
  fi

  check "helm template every pinned chart with its Application values" \
    bash "$REPO_ROOT/scripts/check_helm.sh"
}

# ---------------------------------------------------------------------------
# Container image
# ---------------------------------------------------------------------------
check_docker() {
  section "Container image"

  local engine=""
  for e in docker podman; do have "$e" && { engine="$e"; break; }; done

  if [[ -z "$engine" ]]; then
    skip "image build and run" "no docker or podman"
    return
  fi

  check "image builds and serves correctly ($engine)" \
    bash "$REPO_ROOT/scripts/check_image.sh" "$engine"
}

# ---------------------------------------------------------------------------

main() {
  local what="${1:-all}"

  case "$what" in
    all)        check_terraform; check_kubernetes; check_docs; check_helm; check_docker ;;
    terraform)  check_terraform ;;
    kubernetes) check_kubernetes ;;
    docs)       check_docs ;;
    helm)       check_helm ;;
    docker)     check_docker ;;
    *) echo "usage: $0 [all|terraform|kubernetes|docs|helm|docker]" >&2; exit 2 ;;
  esac

  # Counts are printed from the counters, never hardcoded. A success message
  # with a fixed number in it stops being true the first time someone adds a
  # check and forgets to update the message.
  printf '\n%s%s%s\n' "$c_dim" "────────────────────────────────────" "$c_off"
  printf '%d passed' "$PASS"
  (( SKIP > 0 )) && printf ', %d skipped' "$SKIP"
  (( FAIL > 0 )) && printf ', %s%d failed%s' "$c_red" "$FAIL" "$c_off"
  printf '\n'

  if (( FAIL > 0 )); then
    printf '\nFailed:\n'
    printf '  - %s\n' "${FAILED_CHECKS[@]}"
    exit 1
  fi

  if (( PASS == 0 )); then
    echo "Nothing ran. That is a failure, not a pass." >&2
    exit 1
  fi

  exit 0
}

main "$@"
