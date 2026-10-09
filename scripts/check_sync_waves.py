#!/usr/bin/env python3
"""Check the Argo CD sync wave ordering.

Ordering here is not cosmetic. demo-app declares a ServiceMonitor and a
PrometheusRule, which are CRDs installed by kube-prometheus-stack. Apply them in
the wrong order and the sync fails with "no matches for kind ServiceMonitor".

Argo CD usually recovers on retry, which is the dangerous part: the ordering
bug is invisible on a good day and only shows up the day the retry budget runs
out. This check makes the dependency explicit and verifiable.
"""

from __future__ import annotations

import pathlib
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    print("PyYAML is required: pip install pyyaml", file=sys.stderr)
    raise SystemExit(1)

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
APPS_DIR = REPO_ROOT / "kubernetes" / "argocd" / "applications"

WAVE_ANNOTATION = "argocd.argoproj.io/sync-wave"

# (dependent, dependency): dependent must sync in a LATER wave.
MUST_FOLLOW = [
    ("demo-app", "monitoring"),      # needs the ServiceMonitor and PrometheusRule CRDs
    ("demo-app", "aws-load-balancer-controller"),  # its Ingress needs a controller
    ("monitoring", "platform"),      # its PVCs need the gp3 StorageClass
]

errors: list[str] = []


def main() -> int:
    if not APPS_DIR.is_dir():
        print(f"not found: {APPS_DIR}", file=sys.stderr)
        return 1

    waves: dict[str, int] = {}

    for path in sorted(APPS_DIR.glob("*.yaml")):
        for doc in yaml.safe_load_all(path.read_text()):
            if not isinstance(doc, dict) or doc.get("kind") != "Application":
                continue
            meta = doc.get("metadata") or {}
            name = meta.get("name")
            annotations = meta.get("annotations") or {}

            if WAVE_ANNOTATION not in annotations:
                errors.append(
                    f"{path.name}: Application {name} has no {WAVE_ANNOTATION}. "
                    f"It defaults to wave 0 and races everything else in wave 0."
                )
                continue

            try:
                waves[name] = int(annotations[WAVE_ANNOTATION])
            except (TypeError, ValueError):
                errors.append(
                    f"{path.name}: Application {name} has a non-integer sync wave "
                    f"{annotations[WAVE_ANNOTATION]!r}"
                )

    if not waves:
        print("No Applications with sync waves found; treating as a failure.", file=sys.stderr)
        return 1

    for dependent, dependency in MUST_FOLLOW:
        if dependent not in waves:
            errors.append(f"expected an Application named {dependent!r}, found none")
            continue
        if dependency not in waves:
            errors.append(f"expected an Application named {dependency!r}, found none")
            continue
        if waves[dependent] <= waves[dependency]:
            errors.append(
                f"{dependent} (wave {waves[dependent]}) must sync AFTER "
                f"{dependency} (wave {waves[dependency]})"
            )

    for name, wave in sorted(waves.items(), key=lambda kv: kv[1]):
        print(f"  wave {wave:>4}  {name}")

    if errors:
        print("\nProblems found:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    print(f"  {len(waves)} Application(s), {len(MUST_FOLLOW)} ordering rule(s) satisfied")
    return 0


if __name__ == "__main__":
    sys.exit(main())
