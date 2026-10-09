#!/usr/bin/env python3
"""Structural checks on the vendored IAM policy documents.

A policy that is valid JSON but the wrong shape is accepted by `terraform
validate` and rejected by IAM at apply time, after the VPC and half the cluster
already exist. These checks are the cheap version of that feedback.
"""

from __future__ import annotations

import json
import pathlib
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
POLICY_DIR = REPO_ROOT / "terraform" / "envs" / "dev" / "policies"

VALID_EFFECTS = {"Allow", "Deny"}
errors: list[str] = []
checked = 0


def check_policy(path: pathlib.Path) -> None:
    global checked

    try:
        doc = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        errors.append(f"{path.name}: not valid JSON: {exc}")
        return

    checked += 1
    name = path.name

    if doc.get("Version") != "2012-10-17":
        errors.append(
            f"{name}: Version is {doc.get('Version')!r}. IAM only accepts "
            f"'2012-10-17'; '2008-10-17' exists but silently disables policy "
            f"variables and conditions in some contexts."
        )

    statements = doc.get("Statement")
    if not isinstance(statements, list) or not statements:
        errors.append(f"{name}: Statement must be a non-empty list")
        return

    for i, st in enumerate(statements):
        where = f"{name}: Statement[{i}]"

        if st.get("Effect") not in VALID_EFFECTS:
            errors.append(f"{where}: Effect must be Allow or Deny, got {st.get('Effect')!r}")

        if "Action" not in st and "NotAction" not in st:
            errors.append(f"{where}: no Action or NotAction")

        if "Resource" not in st and "NotResource" not in st:
            errors.append(f"{where}: no Resource or NotResource")

        actions = st.get("Action", [])
        if isinstance(actions, str):
            actions = [actions]

        for action in actions:
            # A bare "*" grants the account away. It is never what was meant in
            # a vendored service policy.
            if action == "*":
                errors.append(f"{where}: Action '*' grants everything")
            # Every real IAM action is service:Operation. A missing colon is
            # usually a typo like "ec2DescribeInstances", which IAM accepts into
            # the document and then never matches, so the permission silently
            # does nothing.
            elif ":" not in action:
                errors.append(f"{where}: action {action!r} has no service prefix")

    compact_len = len(json.dumps(doc, separators=(",", ":")))
    print(f"  {name}: {len(statements)} statements, {compact_len} chars compact")

    # IAM limits: a managed policy document is capped at 6144 characters
    # excluding whitespace, and an inline role policy at 10240. Over the limit
    # the apply fails with LimitExceeded after the rest of the stack is already
    # half built, so it is worth knowing here.
    if compact_len > 10240:
        errors.append(
            f"{name}: {compact_len} characters exceeds the 10240 limit for an "
            f"inline role policy. It has to be split."
        )
    elif compact_len > 6144:
        print(
            "    note: over the 6144 character managed policy limit, so it has "
            "to be attached as a customer managed policy rather than inlined. "
            "It is; see terraform/modules/irsa."
        )


def main() -> int:
    if not POLICY_DIR.is_dir():
        print(f"policy directory not found: {POLICY_DIR}", file=sys.stderr)
        return 1

    policies = sorted(POLICY_DIR.glob("*.json"))
    if not policies:
        # A check that silently examines nothing is worse than no check.
        print(f"no policy files found in {POLICY_DIR}", file=sys.stderr)
        return 1

    for path in policies:
        check_policy(path)

    if errors:
        print("\nProblems found:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    print(f"  {checked} policy document(s) OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
