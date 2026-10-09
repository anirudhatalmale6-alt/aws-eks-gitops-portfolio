#!/usr/bin/env bash
#
# Install the pinned tool versions into .tools/
#
# Pinned, not "latest", so that `make validate` gives the same answer on your
# laptop as it does in CI as it does in six months. A linter that silently
# upgrades itself turns a green build into a red one with no commit to blame.
#
# Every download is checksum-verified against the publisher's OWN checksum file,
# fetched at run time. That is deliberately different from pasting hashes in
# here: a hardcoded hash is correct until the version is bumped and then it is
# a lie that someone has to chase. This way the pin lives in one place, the
# version variable, and the integrity check still happens.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$REPO_ROOT/.tools"

TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.16.5}"
TFLINT_VERSION="${TFLINT_VERSION:-0.64.0}"
TRIVY_VERSION="${TRIVY_VERSION:-0.75.0}"
KUBECTL_VERSION="${KUBECTL_VERSION:-1.33.4}"
HELM_VERSION="${HELM_VERSION:-3.16.4}"
KUBECONFORM_VERSION="${KUBECONFORM_VERSION:-0.8.0}"

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$TOOLS_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say() { printf '  %s\n' "$*"; }

# verify <file> <expected sha256>
verify() {
  local file="$1" expected="$2" actual
  actual="$(sha256sum "$file" | cut -d' ' -f1)"
  if [[ "$actual" != "$expected" ]]; then
    echo "CHECKSUM MISMATCH for $(basename "$file")" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
}

installed() {  # installed <binary> <version string to look for>
  local bin="$TOOLS_DIR/$1"
  [[ -x "$bin" ]] && "$bin" version 2>/dev/null | grep -qF "$2"
}

echo "Installing into $TOOLS_DIR ($OS/$ARCH)"

# --- terraform -------------------------------------------------------------
if installed terraform "v${TERRAFORM_VERSION}"; then
  say "terraform ${TERRAFORM_VERSION} already present"
else
  say "terraform ${TERRAFORM_VERSION}"
  base="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}"
  file="terraform_${TERRAFORM_VERSION}_${OS}_${ARCH}.zip"
  curl -fsSL -o "$WORK/$file" "$base/$file"
  curl -fsSL -o "$WORK/tf.sums" "$base/terraform_${TERRAFORM_VERSION}_SHA256SUMS"
  verify "$WORK/$file" "$(grep " $file\$" "$WORK/tf.sums" | cut -d' ' -f1)"
  unzip -oq "$WORK/$file" -d "$TOOLS_DIR" terraform
fi

# --- tflint ----------------------------------------------------------------
if installed tflint "${TFLINT_VERSION}"; then
  say "tflint ${TFLINT_VERSION} already present"
else
  say "tflint ${TFLINT_VERSION}"
  base="https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}"
  file="tflint_${OS}_${ARCH}.zip"
  curl -fsSL -o "$WORK/$file" "$base/$file"
  curl -fsSL -o "$WORK/tflint.sums" "$base/checksums.txt"
  verify "$WORK/$file" "$(grep " $file\$" "$WORK/tflint.sums" | cut -d' ' -f1)"
  unzip -oq "$WORK/$file" -d "$TOOLS_DIR" tflint
fi

# --- trivy -----------------------------------------------------------------
if [[ -x "$TOOLS_DIR/trivy" ]] && "$TOOLS_DIR/trivy" --version 2>/dev/null | grep -qF "${TRIVY_VERSION}"; then
  say "trivy ${TRIVY_VERSION} already present"
else
  say "trivy ${TRIVY_VERSION}"
  case "$ARCH" in amd64) tarch="64bit" ;; arm64) tarch="ARM64" ;; esac
  case "$OS" in linux) tos="Linux" ;; darwin) tos="macOS" ;; esac
  base="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}"
  file="trivy_${TRIVY_VERSION}_${tos}-${tarch}.tar.gz"
  curl -fsSL -o "$WORK/$file" "$base/$file"
  curl -fsSL -o "$WORK/trivy.sums" "$base/trivy_${TRIVY_VERSION}_checksums.txt"
  verify "$WORK/$file" "$(grep " $file\$" "$WORK/trivy.sums" | cut -d' ' -f1)"
  tar -xzf "$WORK/$file" -C "$TOOLS_DIR" trivy
fi

# --- kubectl ---------------------------------------------------------------
if installed kubectl "v${KUBECTL_VERSION}"; then
  say "kubectl ${KUBECTL_VERSION} already present"
else
  say "kubectl ${KUBECTL_VERSION}"
  base="https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/${OS}/${ARCH}"
  curl -fsSL -o "$WORK/kubectl" "$base/kubectl"
  verify "$WORK/kubectl" "$(curl -fsSL "$base/kubectl.sha256")"
  install -m 0755 "$WORK/kubectl" "$TOOLS_DIR/kubectl"
fi

# --- helm ------------------------------------------------------------------
if installed helm "v${HELM_VERSION}"; then
  say "helm ${HELM_VERSION} already present"
else
  say "helm ${HELM_VERSION}"
  file="helm-v${HELM_VERSION}-${OS}-${ARCH}.tar.gz"
  curl -fsSL -o "$WORK/$file" "https://get.helm.sh/$file"
  verify "$WORK/$file" "$(curl -fsSL "https://get.helm.sh/${file}.sha256sum" | cut -d' ' -f1)"
  tar -xzf "$WORK/$file" -C "$WORK"
  install -m 0755 "$WORK/${OS}-${ARCH}/helm" "$TOOLS_DIR/helm"
fi

# --- kubeconform -----------------------------------------------------------
if [[ -x "$TOOLS_DIR/kubeconform" ]] && "$TOOLS_DIR/kubeconform" -v 2>/dev/null | grep -qF "${KUBECONFORM_VERSION}"; then
  say "kubeconform ${KUBECONFORM_VERSION} already present"
else
  say "kubeconform ${KUBECONFORM_VERSION}"
  base="https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}"
  file="kubeconform-${OS}-${ARCH}.tar.gz"
  curl -fsSL -o "$WORK/$file" "$base/$file"
  curl -fsSL -o "$WORK/kc.sums" "$base/CHECKSUMS"
  verify "$WORK/$file" "$(grep " $file\$" "$WORK/kc.sums" | cut -d' ' -f1)"
  tar -xzf "$WORK/$file" -C "$TOOLS_DIR" kubeconform
fi

# --- tflint plugins --------------------------------------------------------
# The AWS ruleset is what validates instance types and IAM shapes against the
# real AWS surface. Without it tflint only catches style problems.
say "tflint plugins"
( cd "$REPO_ROOT" && "$TOOLS_DIR/tflint" --init >/dev/null 2>&1 ) || true

echo
echo "Installed:"
# Each of these six wants a different version flag, so they are spelled out
# rather than guessed at with a fallback chain that prints usage text on a miss.
printf '  %-13s %s\n' terraform   "$("$TOOLS_DIR/terraform" version | head -1)"
printf '  %-13s %s\n' tflint      "$("$TOOLS_DIR/tflint" --version | head -1)"
printf '  %-13s %s\n' trivy       "$("$TOOLS_DIR/trivy" --version | grep -m1 '^Version:')"
printf '  %-13s %s\n' kubectl     "$("$TOOLS_DIR/kubectl" version --client=true | head -1)"
printf '  %-13s %s\n' helm        "$("$TOOLS_DIR/helm" version --short)"
printf '  %-13s %s\n' kubeconform "$("$TOOLS_DIR/kubeconform" -v)"
echo
echo "They are on PATH for every make target. For your own shell:"
echo "  export PATH=\"$TOOLS_DIR:\$PATH\""
