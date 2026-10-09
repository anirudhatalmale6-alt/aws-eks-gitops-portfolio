#!/usr/bin/env python3
"""Parse every YAML file under kubernetes/ and check a few repo-wide invariants.

kubeconform validates each object against its schema. It cannot tell you that a
placeholder was never substituted, or that an Application points at a chart
version expressed as a range. Those are the checks here.
"""

from __future__ import annotations

import pathlib
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    print("PyYAML is required: pip install pyyaml", file=sys.stderr)
    raise SystemExit(1)

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
KUBE_DIR = REPO_ROOT / "kubernetes"

# Placeholders are expected in the committed manifests; scripts/render-manifests.sh
# replaces them from the terraform outputs. This is the full list, and it is
# used to check that nothing ELSE that looks like a placeholder has crept in.
KNOWN_PLACEHOLDERS = {
    "GIT_REPO_URL_PLACEHOLDER",
    "CLUSTER_NAME_PLACEHOLDER",
    "AWS_REGION_PLACEHOLDER",
    "VPC_ID_PLACEHOLDER",
    "ALB_CONTROLLER_ROLE_ARN_PLACEHOLDER",
    "ECR_REPOSITORY_URL_PLACEHOLDER",
}

# Not Kubernetes API objects: kustomize reads these at build time.
KUSTOMIZE_KINDS = {"Kustomization", "Component"}

PLACEHOLDER_RE = re.compile(r"\b[A-Z][A-Z0-9_]*_PLACEHOLDER\b")
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")

errors: list[str] = []
docs_seen = 0
files_seen = 0


def check_file(path: pathlib.Path) -> None:
    global docs_seen, files_seen

    text = path.read_text()
    rel = path.relative_to(REPO_ROOT)

    try:
        docs = [d for d in yaml.safe_load_all(text) if d is not None]
    except yaml.YAMLError as exc:
        errors.append(f"{rel}: YAML parse error: {exc}")
        return

    files_seen += 1
    docs_seen += len(docs)

    if not docs:
        errors.append(f"{rel}: contains no YAML documents")
        return

    for found in PLACEHOLDER_RE.findall(text):
        if found not in KNOWN_PLACEHOLDERS:
            errors.append(
                f"{rel}: unknown placeholder {found!r}. Add it to "
                f"KNOWN_PLACEHOLDERS here AND to scripts/render-manifests.sh, "
                f"or it will reach the cluster unsubstituted."
            )

    for doc in docs:
        if not isinstance(doc, dict):
            continue

        kind = doc.get("kind")
        meta = doc.get("metadata") or {}

        if kind and "apiVersion" not in doc:
            errors.append(f"{rel}: {kind} has no apiVersion")

        # Kustomize's own config objects are build-time inputs, not Kubernetes
        # API objects, and carry no metadata.name.
        if kind and kind not in KUSTOMIZE_KINDS and not meta.get("name"):
            errors.append(f"{rel}: {kind} has no metadata.name")

        if kind == "Application":
            check_application(rel, doc)


def check_application(rel: pathlib.Path, doc: dict) -> None:
    name = doc.get("metadata", {}).get("name", "<unnamed>")
    spec = doc.get("spec") or {}
    source = spec.get("source") or {}

    if not spec.get("project"):
        errors.append(f"{rel}: Application {name} has no project, so it falls back to 'default', which permits any repo and any namespace")
    elif spec["project"] == "default":
        errors.append(f"{rel}: Application {name} uses the 'default' AppProject, which has no restrictions at all")

    target = str(source.get("targetRevision", ""))

    if source.get("chart"):
        # A Helm chart version must be an exact release. Argo CD accepts a
        # semver RANGE here, and then a cluster component upgrades itself on
        # some future refresh with no commit anywhere. That is not GitOps.
        if not SEMVER_RE.match(target):
            errors.append(
                f"{rel}: Application {name} pins chart "
                f"{source['chart']} to {target!r}. Use an exact version like "
                f"'3.6.0'; a range lets the cluster change without a commit."
            )
    else:
        if not target:
            errors.append(f"{rel}: Application {name} has no targetRevision")

    if not spec.get("destination", {}).get("server"):
        errors.append(f"{rel}: Application {name} has no destination.server")

    # Any Application with automated sync must have the finalizer, or deleting
    # it orphans everything it created.
    automated = (spec.get("syncPolicy") or {}).get("automated")
    finalizers = doc.get("metadata", {}).get("finalizers") or []
    if automated and "resources-finalizer.argocd.argoproj.io" not in finalizers:
        errors.append(
            f"{rel}: Application {name} syncs automatically but has no "
            f"resources-finalizer.argocd.argoproj.io, so deleting it would "
            f"leave its resources running in the cluster unmanaged."
        )


def main() -> int:
    if not KUBE_DIR.is_dir():
        print(f"not found: {KUBE_DIR}", file=sys.stderr)
        return 1

    paths = sorted(KUBE_DIR.rglob("*.yaml")) + sorted(KUBE_DIR.rglob("*.yml"))
    if not paths:
        print(f"no YAML files under {KUBE_DIR}", file=sys.stderr)
        return 1

    for path in paths:
        check_file(path)

    if errors:
        print("Problems found:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    print(f"  {docs_seen} document(s) in {files_seen} file(s) parsed and checked")
    return 0


if __name__ == "__main__":
    sys.exit(main())
