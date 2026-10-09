#!/usr/bin/env python3
"""Check the Grafana dashboard ConfigMaps.

A dashboard reaches Grafana as a JSON string inside a ConfigMap. kubeconform
validates the ConfigMap and never looks inside the string, so a dashboard that
is malformed, empty, or wired to a datasource uid that does not exist on this
cluster passes every other check in this repo and then opens as a blank page
full of "Datasource not found".
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    print("PyYAML is required: pip install pyyaml", file=sys.stderr)
    raise SystemExit(1)

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
PLATFORM_DIR = REPO_ROOT / "kubernetes" / "platform"

# A hardcoded uid like "PBFA97CFB590B2093" is the signature of a dashboard
# exported from somebody else's Grafana. It will not resolve here.
HARDCODED_UID_RE = re.compile(r'"uid"\s*:\s*"(?!\$)[A-Za-z0-9_-]{8,}"')

errors: list[str] = []
dashboards = 0


def check_dashboard(path: pathlib.Path, key: str, raw: str) -> None:
    global dashboards
    rel = path.relative_to(REPO_ROOT)
    where = f"{rel}[{key}]"

    try:
        doc = json.loads(raw)
    except json.JSONDecodeError as exc:
        errors.append(f"{where}: not valid JSON: {exc}")
        return

    dashboards += 1

    for field in ("title", "panels"):
        if field not in doc:
            errors.append(f"{where}: dashboard has no {field!r}")

    panels = doc.get("panels") or []
    if not panels:
        errors.append(f"{where}: dashboard has zero panels, which renders as an empty page")
        return

    # Every panel needs at least one query, or it draws nothing and says
    # nothing.
    for i, panel in enumerate(panels):
        ptype = panel.get("type", "<none>")
        if ptype in ("row", "text"):
            continue
        targets = panel.get("targets") or []
        if not targets:
            errors.append(f"{where}: panel {i} ({panel.get('title')!r}) has no targets")
            continue
        for j, target in enumerate(targets):
            if not str(target.get("expr", "")).strip():
                errors.append(
                    f"{where}: panel {i} ({panel.get('title')!r}) target {j} has an empty expr"
                )

    # The datasource must be a template variable. See the module docstring.
    datasource_uids = set(HARDCODED_UID_RE.findall(raw))
    panel_uids = {
        (p.get("datasource") or {}).get("uid")
        for p in panels
        if isinstance(p.get("datasource"), dict)
    }
    for uid in panel_uids:
        if uid and not uid.startswith("$"):
            errors.append(
                f"{where}: panel datasource uid {uid!r} is hardcoded. Use a "
                f"template variable such as ${{DS_PROMETHEUS}}; a generated uid "
                f"from another cluster will not resolve here."
            )

    # Having asserted the panels, make sure the variable it uses is declared.
    declared = {v.get("name") for v in (doc.get("templating") or {}).get("list", [])}
    for uid in panel_uids:
        if uid and uid.startswith("$"):
            var = uid.strip("${}")
            if var not in declared:
                errors.append(
                    f"{where}: panels reference variable ${{{var}}} but it is "
                    f"not declared in templating.list"
                )

    print(f"  {rel}: {doc.get('title')!r}, {len(panels)} panels, uid={doc.get('uid')!r}")


def main() -> int:
    if not PLATFORM_DIR.is_dir():
        print(f"not found: {PLATFORM_DIR}", file=sys.stderr)
        return 1

    found_configmaps = 0

    for path in sorted(PLATFORM_DIR.rglob("*.yaml")):
        for doc in yaml.safe_load_all(path.read_text()):
            if not isinstance(doc, dict) or doc.get("kind") != "ConfigMap":
                continue
            labels = (doc.get("metadata") or {}).get("labels") or {}
            if labels.get("grafana_dashboard") != "1":
                continue
            found_configmaps += 1
            for key, raw in (doc.get("data") or {}).items():
                check_dashboard(path, key, raw)

    if found_configmaps == 0:
        print(
            "No ConfigMap labelled grafana_dashboard: \"1\" found. Either the "
            "dashboards moved or the label is wrong, in which case Grafana "
            "would silently load nothing. Treating as a failure.",
            file=sys.stderr,
        )
        return 1

    if errors:
        print("Problems found:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    print(f"  {dashboards} dashboard(s) checked")
    return 0


if __name__ == "__main__":
    sys.exit(main())
