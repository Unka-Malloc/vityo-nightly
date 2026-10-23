#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ZERO_SHA = "0" * 40


@dataclass(frozen=True)
class CIRefs:
    base_ref: str
    revision_range: str
    fetch_refspec: str | None = None


def resolve_ci_refs(
    event_name: str,
    event: dict[str, Any],
    *,
    head_sha: str,
    parent_ref: str | None,
) -> CIRefs:
    if event_name == "pull_request":
        pull_request = event.get("pull_request")
        if not isinstance(pull_request, dict):
            raise ValueError("pull request metadata is missing")
        base = pull_request.get("base")
        head = pull_request.get("head")
        if not isinstance(base, dict) or not isinstance(head, dict):
            raise ValueError("pull request revisions are missing")
        branch = base.get("ref")
        base_sha = base.get("sha")
        pr_head_sha = head.get("sha")
        if not all(isinstance(value, str) and value for value in (branch, base_sha, pr_head_sha)):
            raise ValueError("pull request revision fields are invalid")
        return CIRefs(
            base_ref=f"origin/{branch}",
            revision_range=f"{base_sha}..{pr_head_sha}",
            fetch_refspec=f"+refs/heads/{branch}:refs/remotes/origin/{branch}",
        )

    if event_name == "push":
        before = event.get("before")
        if isinstance(before, str) and before and before != ZERO_SHA:
            return CIRefs(base_ref=before, revision_range=f"{before}..{head_sha}")

    if event_name not in {"push", "merge_group", "schedule", "workflow_dispatch"}:
        raise ValueError("unsupported GitHub event")

    base_ref = parent_ref or "HEAD"
    return CIRefs(base_ref=base_ref, revision_range=f"{base_ref}..{head_sha}")


def main() -> int:
    event_name = os.environ.get("GITHUB_EVENT_NAME", "")
    head_sha = os.environ.get("GITHUB_SHA", "")
    event_path = os.environ.get("GITHUB_EVENT_PATH", "")
    output_path = os.environ.get("GITHUB_OUTPUT", "")
    if not event_name or not head_sha or not event_path or not output_path:
        print("GitHub event metadata is unavailable", file=sys.stderr)
        return 2

    try:
        event = json.loads(Path(event_path).read_text(encoding="utf-8"))
        if not isinstance(event, dict):
            raise ValueError("GitHub event payload is invalid")
        parent_result = subprocess.run(
            ["git", "rev-parse", "--verify", "HEAD^"],
            check=False,
            capture_output=True,
            text=True,
        )
        parent_ref = "HEAD^" if parent_result.returncode == 0 else None
        refs = resolve_ci_refs(
            event_name,
            event,
            head_sha=head_sha,
            parent_ref=parent_ref,
        )
        if refs.fetch_refspec is not None:
            fetched = subprocess.run(
                ["git", "fetch", "--no-tags", "origin", refs.fetch_refspec],
                check=False,
                capture_output=True,
                text=True,
            )
            if fetched.returncode != 0:
                raise RuntimeError("pull request base ref could not be fetched")
        with Path(output_path).open("a", encoding="utf-8") as output:
            output.write(f"base_ref={refs.base_ref}\n")
            output.write(f"range={refs.revision_range}\n")
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
