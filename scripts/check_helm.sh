#!/usr/bin/env bash
#
# Render every pinned Helm chart with the values block from its Argo CD
# Application, then ASSERT the values actually took effect.
#
# The assertions are the point. An unknown key in a Helm values file is not an
# error: none of the three charts here ships a values.schema.json, so Helm
# merges whatever you give it and the templates ignore anything they do not
# recognise. Checked directly while writing this, by rendering each chart with a
# deliberately invented key; all three exited 0.
#
# So "helm template succeeded" proves almost nothing. A values key renamed in a
# chart upgrade would still render cleanly and would still produce a cluster
# where the setting you believed you applied is simply absent. The only way to
# know is to look for the setting in the rendered output, which is what the
# expect/refute lines below do.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

export HELM_CACHE_HOME="${HELM_CACHE_HOME:-$REPO_ROOT/.helm/cache}"
export HELM_CONFIG_HOME="${HELM_CONFIG_HOME:-$REPO_ROOT/.helm/config}"
export HELM_DATA_HOME="${HELM_DATA_HOME:-$REPO_ROOT/.helm/data}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

rc=0
assertions=0

# expect <file> <label> <extended regex>
expect() {
  assertions=$((assertions + 1))
  if grep -qE "$3" "$1"; then
    echo "       ok    $2"
  else
    echo "       FAIL  $2  (expected to find /$3/ in rendered output)"
    rc=1
  fi
}

# refute <file> <label> <extended regex>
refute() {
  assertions=$((assertions + 1))
  if grep -qE "$3" "$1"; then
    echo "       FAIL  $2  (did NOT expect /$3/ in rendered output)"
    rc=1
  else
    echo "       ok    $2"
  fi
}

# count_is <file> <label> <expected count> <extended regex>
count_is() {
  assertions=$((assertions + 1))
  local n
  n="$(grep -cE "$4" "$1" || true)"
  if [[ "$n" == "$3" ]]; then
    echo "       ok    $2 (found $n)"
  else
    echo "       FAIL  $2  (expected $3 occurrences of /$4/, found $n)"
    rc=1
  fi
}

# Pull chart, version, repo and the values block out of each Application.
python3 - "$WORK" <<'PY'
import os, sys, glob, yaml

work = sys.argv[1]
found = 0

for path in sorted(glob.glob("kubernetes/argocd/applications/*.yaml")):
    for doc in yaml.safe_load_all(open(path)):
        if not doc or doc.get("kind") != "Application":
            continue
        src = doc["spec"]["source"]
        chart = src.get("chart")
        if not chart:
            continue  # git-sourced Application, nothing to render
        name = doc["metadata"]["name"]
        values = src.get("helm", {}).get("values", "")
        # Placeholders become syntactically valid dummies. What is being
        # checked is the shape of the values, not their content.
        for a, b in [
            ("CLUSTER_NAME_PLACEHOLDER", "validate-cluster"),
            ("AWS_REGION_PLACEHOLDER", "us-east-1"),
            ("VPC_ID_PLACEHOLDER", "vpc-0123456789abcdef0"),
            ("ALB_CONTROLLER_ROLE_ARN_PLACEHOLDER", "arn:aws:iam::000000000000:role/validate"),
            ("GIT_REPO_URL_PLACEHOLDER", "https://github.com/example/example.git"),
        ]:
            values = values.replace(a, b)
        with open(os.path.join(work, f"{name}.values.yaml"), "w") as fh:
            fh.write(values)
        with open(os.path.join(work, f"{name}.meta"), "w") as fh:
            fh.write(f"{src['repoURL']}\n{chart}\n{src['targetRevision']}\n")
        found += 1

if found == 0:
    sys.exit(
        "No chart-sourced Applications found. Either the path moved or this "
        "parse is wrong; either way it is a failure, not a pass."
    )
print(f"  {found} chart-sourced Application(s)")
PY

while IFS= read -r meta; do
  repo="$(sed -n 1p "$meta")"
  helm repo add "repo-$(printf '%s' "$repo" | md5sum | cut -c1-8)" "$repo" >/dev/null 2>&1 || true
done < <(find "$WORK" -name '*.meta')

helm repo update >/dev/null 2>&1

for meta in "$WORK"/*.meta; do
  name="$(basename "$meta" .meta)"
  repo="$(sed -n 1p "$meta")"
  chart="$(sed -n 2p "$meta")"
  version="$(sed -n 3p "$meta")"
  out="$WORK/$name.rendered.yaml"

  if ! helm template "$name" "$chart" \
        --repo "$repo" \
        --version "$version" \
        --values "$WORK/$name.values.yaml" \
        --namespace validate \
        --kube-version 1.33.0 \
        > "$out" 2>"$WORK/$name.err"; then
    echo "  FAIL $name  ($chart $version) did not render"
    sed 's/^/       /' "$WORK/$name.err"
    rc=1
    continue
  fi

  objects="$(grep -c '^kind:' "$out" || true)"
  if [[ "$objects" -lt 1 ]]; then
    echo "  FAIL $name: rendered zero objects"
    rc=1
    continue
  fi

  echo "  $name  ($chart $version) -> $objects objects"

  case "$name" in
    aws-load-balancer-controller)
      # Without the right cluster name the controller refuses to manage
      # anything; without region and vpcId it tries to read IMDS, which these
      # pods cannot reach because the hop limit is 1.
      expect "$out" "--cluster-name passed through"     '\-\-cluster-name=validate-cluster'
      expect "$out" "--aws-region passed through"    '\-\-aws-region=us-east-1'
      expect "$out" "--aws-vpc-id passed through"    '\-\-aws-vpc-id=vpc-0123456789abcdef0'
      # If the IRSA annotation is missing the controller starts and then fails
      # its first ELB call with AccessDenied.
      expect "$out" "IRSA role annotation on the service account" \
        'eks\.amazonaws\.com/role-arn: arn:aws:iam::000000000000:role/validate'
      expect "$out" "service account named as the trust policy expects" \
        'name: aws-load-balancer-controller'
      expect "$out" "two replicas" '^  replicas: 2$'
      ;;

    metrics-server)
      expect "$out" "two replicas" '^  replicas: 2$'
      # The flag must appear exactly once. Adding it through `args` as well as
      # the chart's defaultArgs launches the container with it twice.
      count_is "$out" "--kubelet-preferred-address-types appears exactly once" 1 \
        '\-\-kubelet-preferred-address-types='
      # Certificate verification against the kubelet stays ON. It is not needed
      # on EKS and turning it off is cargo cult.
      refute "$out" "--kubelet-insecure-tls is NOT set" '\-\-kubelet-insecure-tls'
      ;;

    monitoring)
      expect "$out" "Prometheus retention is 7d"       'retention: "7d"'
      expect "$out" "Prometheus retentionSize is 15GB" 'retentionSize: "15GB"'
      # Three volumes must land on gp3: Prometheus, Alertmanager, Grafana.
      count_is "$out" "three volumes on the gp3 storage class" 3 'storageClassName: gp3'
      # serviceMonitorSelectorNilUsesHelmValues: false renders an EMPTY
      # selector. If the chart ever renames that value, the selector comes back
      # with a release matcher and demo-app's ServiceMonitor is ignored in
      # silence. That is exactly the failure this assertion exists to catch.
      expect "$out" "Prometheus watches ServiceMonitors in all namespaces" '^  serviceMonitorSelector: \{\}$'
      expect "$out" "Prometheus watches PrometheusRules in all namespaces"  '^  ruleSelector: \{\}$'
      # The Grafana dashboard sidecar is what loads
      # kubernetes/platform/grafana-dashboard-demo-app.yaml.
      expect "$out" "Grafana dashboard sidecar label is grafana_dashboard" 'grafana_dashboard: "1"'
      # EKS manages the control plane, so these are unreachable. Left enabled
      # they alert forever and teach everyone to ignore alerts.
      refute "$out" "no kube-controller-manager scrape target" 'kube-controller-manager'
      refute "$out" "no etcd scrape target"                    'kube-etcd'
      refute "$out" "no kube-scheduler scrape target"          'kube-scheduler'
      ;;
  esac
done

echo "  $assertions assertion(s) on rendered chart output"
exit "$rc"
