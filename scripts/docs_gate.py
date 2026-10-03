#!/usr/bin/env python3
"""Compose the docs/process gate: team runbooks, docs audit, ecosystem CLI docs.

This is the same composition `scripts/docs-gate.sh` documents, expressed in
Python so delivery can run it on every platform. The shell entrypoint remains the
convenience path for a Unix host, and it delegates here so the two cannot drift.

The gate runs, in order:

1. `scripts/team-docs-gate.py` with the selected change source.
2. `scripts/docs-audit.py` with the team-docs check suppressed, because step 1
   already ran it and re-running it would duplicate the same failure.
3. `scripts/ecosystem-cli-doc-gate.py --non-blocking` unless skipped.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]


def _run(command: list[str], *, environment: dict[str, str] | None = None) -> int:
    print(f"[docs-gate] {' '.join(command)}", flush=True)
    return subprocess.run(
        command, cwd=ROOT, env=environment, check=False
    ).returncode


def _upstream_base() -> str | None:
    completed = subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        return None
    base = completed.stdout.strip()
    return base or None


def docs_gate_commands(
    mode: str,
    base: str | None,
    skip_ecosystem: bool,
    python_bin: str,
) -> list[tuple[list[str], dict[str, str] | None]]:
    """Return the ordered commands and per-command environments."""
    team = [python_bin, "scripts/team-docs-gate.py"]
    if mode == "staged":
        team += ["--mode", "staged"]
    elif mode == "push":
        resolved = base or _upstream_base()
        if not resolved:
            raise ValueError(
                "push mode requires --base <ref> or a configured upstream branch"
            )
        team += ["--base", resolved]

    audit_env = dict(os.environ)
    audit_env["VITYO_SKIP_TEAM_DOC_GATE"] = "1"
    commands: list[tuple[list[str], dict[str, str] | None]] = [
        (team, None),
        ([python_bin, "scripts/docs-audit.py"], audit_env),
    ]
    if skip_ecosystem:
        print("[docs-gate] ecosystem CLI doc consistency check skipped", flush=True)
    else:
        commands.append(
            (
                [
                    python_bin,
                    "scripts/ecosystem-cli-doc-gate.py",
                    "--non-blocking",
                ],
                None,
            )
        )
    return commands


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--mode",
        choices=("worktree", "staged", "push"),
        default="worktree",
    )
    parser.add_argument("--base")
    parser.add_argument("--skip-ecosystem", action="store_true")
    parser.add_argument("--python-bin", default=sys.executable)
    args = parser.parse_args(argv)

    try:
        commands = docs_gate_commands(
            args.mode, args.base, args.skip_ecosystem, args.python_bin
        )
    except ValueError as error:
        print(f"[docs-gate] {error}", file=sys.stderr)
        return 2

    for command, environment in commands:
        code = _run(command, environment=environment)
        if code:
            return code
    print("[docs-gate] all checks passed", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
