#!/usr/bin/env python3
"""Check that kustomize actually rewrote the demo app's image reference.

The Deployment says `image: demo-app` and nothing else; the images transformer
in kustomization.yaml is what turns that into a real registry reference, and it
is also what CI edits when it pushes a new build.

If the transformer ever stops matching, for example because the container was
renamed, kustomize does NOT complain. It emits `image: demo-app`, Kubernetes
treats that as docker.io/library/demo-app:latest, and the pods sit in
ImagePullBackOff with an error that points at Docker Hub rather than at this
file.

Usage: check_kustomize_image.py <rendered-manifests.yaml>
"""

from __future__ import annotations

import pathlib
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    print("PyYAML is required: pip install pyyaml", file=sys.stderr)
    raise SystemExit(1)

# The placeholder the committed repo carries. render-manifests.sh replaces it
# with the real ECR URL from the terraform output, so BOTH are acceptable here:
# this check is about the transformer firing, not about deployment readiness.
PLACEHOLDER = "ECR_REPOSITORY_URL_PLACEHOLDER"
UNTRANSFORMED = "demo-app"
APP_CONTAINER = "nginx"


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2

    path = pathlib.Path(sys.argv[1])
    if not path.is_file():
        print(f"not found: {path}", file=sys.stderr)
        return 1

    deployments = [
        doc
        for doc in yaml.safe_load_all(path.read_text())
        if isinstance(doc, dict) and doc.get("kind") == "Deployment"
    ]

    if not deployments:
        print("No Deployment in the rendered output. That is a failure, not a pass.", file=sys.stderr)
        return 1

    errors: list[str] = []
    checked = 0

    for dep in deployments:
        name = dep["metadata"]["name"]
        containers = dep["spec"]["template"]["spec"]["containers"]

        app = next((c for c in containers if c["name"] == APP_CONTAINER), None)
        if app is None:
            errors.append(
                f"{name}: no container called {APP_CONTAINER!r}. If it was "
                f"renamed, the kustomize images transformer no longer matches "
                f"it either."
            )
            continue

        checked += 1
        image = app.get("image", "")

        if image == UNTRANSFORMED:
            errors.append(
                f"{name}/{APP_CONTAINER}: image is still the bare "
                f"{UNTRANSFORMED!r}. The images transformer in "
                f"kustomization.yaml did not fire; Kubernetes would try "
                f"docker.io/library/{UNTRANSFORMED}:latest."
            )
            continue

        if ":" not in image.rsplit("/", 1)[-1]:
            errors.append(
                f"{name}/{APP_CONTAINER}: image {image!r} has no tag, so it "
                f"resolves to :latest. An immutable ECR repository will not "
                f"serve that."
            )
            continue

        repo, tag = image.rsplit(":", 1)
        if tag in ("latest", ""):
            errors.append(
                f"{name}/{APP_CONTAINER}: image tag is {tag!r}. Deploys must "
                f"name an immutable tag so a rollback means something."
            )
            continue

        origin = "placeholder (repo not yet rendered)" if PLACEHOLDER in repo else "rendered registry"
        print(f"  {name}/{APP_CONTAINER}: {repo}:{tag}  [{origin}]")

        # The sidecar must stay pinned to a real upstream version.
        sidecar = next((c for c in containers if c["name"] == "metrics"), None)
        if sidecar:
            simage = sidecar.get("image", "")
            if ":" not in simage or simage.endswith(":latest"):
                errors.append(
                    f"{name}/metrics: sidecar image {simage!r} is unpinned. A "
                    f"floating sidecar tag changes the pod on every restart."
                )
            else:
                print(f"  {name}/metrics: {simage}")

    if errors:
        print("Problems found:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    if checked == 0:
        print("Nothing was checked, which is a failure.", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
