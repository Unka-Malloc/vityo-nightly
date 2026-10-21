#!/usr/bin/env python3
"""Registered deterministic behavior checks; never runs the real product matrix."""
import os
import tempfile
from pathlib import Path

from baseline import ROOT, APP, run_step, write_json


def main() -> int:
    os.umask(0o077)
    evidence = ROOT / "build/task-resource-focused"
    evidence.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="host-", dir=evidence))
    commands = [
        ("analyze", ["flutter", "analyze"], APP),
        ("daemon-no-deadline", ["cargo", "test", "--locked", "--manifest-path",
            "products/vityo_app/native/vityod/Cargo.toml", "--bin", "vityod",
            "malformed_and_partial_peers"], ROOT),
        ("static-anchors", ["python3", "scripts/vityo-product-gate.py"], ROOT),
        ("report-contracts", ["python3", "-m", "unittest", "discover", "-s", "tests",
                             "-p", "test_*product*gate*.py"], ROOT),
        ("report-consumers", ["python3", "-m", "unittest", "discover", "-s", "tests",
                             "-p", "test_*product_matrix*.py"], ROOT),
        ("report-admission", ["dart", "run",
            "tests/acceptance/vityo_app/trusted_desktop_styio_loop_acceptance_test.dart"], ROOT),
        ("behavior", ["flutter", "test", "--reporter", "expanded", "--timeout", "none",
            "test/flow_hero_execution_test.dart", "test/flow_hero_route_lifecycle_test.dart",
            "test/flow_hero_workspace_operations_test.dart", "test/flow_hero_language_service_test.dart",
            "test/styio_lsp_client_test.dart", "test/lsp_styio_service_connector_lifecycle_test.dart",
            "test/local_service/vityod_client_test.dart", "test/local_service/production_service_identity_test.dart", "test/observable_snapshot_publisher_io_test.dart",
            "test/observable_runtime_intake_io_test.dart"], APP),
        ("boundary", ["flutter", "test", "--reporter", "expanded", "--timeout", "none",
            "test/local_product_workflow_test.dart", "--name",
            "missing selected|incompatible selected|compiler execution failure|current absolute owner paths"], APP),
    ]
    steps = [{"name": name, "argv": argv, "cwd": str(cwd),
              "outcome": "not executed", "exit_code": None} for name, argv, cwd in commands]
    record = {"steps": steps, "exit_code": None, "skips": []}
    code = 0
    for step in steps:
        code = run_step(step, directory, dict(os.environ))
        write_json(directory / "evidence.json", record)
        print(f"focused {step['name']}: {step['outcome']}; exit={step['exit_code']}", flush=True)
        if code:
            break
    record["exit_code"] = code
    write_json(directory / "evidence.json", record)
    write_json(evidence / "latest.json", {"evidence": str(directory / "evidence.json")})
    return code if code >= 0 else 128 - code


if __name__ == "__main__":
    raise SystemExit(main())
