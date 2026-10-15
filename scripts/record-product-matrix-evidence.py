#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import sys
import hashlib
import json
import re
import subprocess
from pathlib import Path


EXPECTED_GATE = "vityo-desktop-product-gate"
EXPECTED_CAPABILITY = "trusted-desktop-ide-loop"
EXPECTED_SCENARIO = "trusted-desktop-styio-loop"
EXPECTED_PLATFORMS = {"linux", "macos", "windows"}
EXPECTED_PTY_CAPABILITY = "desktop-native-pty"
EXPECTED_PTY_SCENARIOS = {
    "tty-identity",
    "child-observed-resize",
    "forced-process-close",
    "terminal-environment-propagation",
}
EXPECTED_PTY_PROVIDERS = {"linux": "forkpty", "macos": "forkpty", "windows": "conpty"}
COMMIT = re.compile(r"^[0-9a-f]{40}$")
DIGEST = re.compile(r"^[0-9a-f]{64}$")
MAX_JSON_INPUT_BYTES = 1_048_576
MAX_GATE_REPORT_BYTES = 65_536
MAX_CLEAN_CHECKOUT_ENTRIES = 20


def git_head(repository: Path) -> str:
    return subprocess.run(
        ["git", "-C", str(repository), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def require_clean_checkout(repository: Path, *, name: str) -> None:
    status = subprocess.run(
        ["git", "-C", str(repository), "status", "--porcelain"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    entries = [line for line in status.splitlines() if line.strip()]
    if not entries:
        return
    listed = entries[:MAX_CLEAN_CHECKOUT_ENTRIES]
    detail = "\n".join(f"  {entry}" for entry in listed)
    if len(entries) > len(listed):
        detail = f"{detail}\n  ... and {len(entries) - len(listed)} more"
    raise ValueError(
        f"{name} checkout contains uncommitted changes:\n{detail}"
    )


def load_json_object(path: Path) -> dict[str, object]:
    with path.open("rb") as stream:
        raw = stream.read(MAX_JSON_INPUT_BYTES + 1)
    if len(raw) > MAX_JSON_INPUT_BYTES:
        raise ValueError(f"{path.name} exceeds its bounded JSON input limit")
    payload = json.loads(
        raw.decode("utf-8"),
        object_pairs_hook=_unique_json_object,
        parse_constant=_reject_json_constant,
    )
    if not isinstance(payload, dict):
        raise ValueError(f"{path.name} must contain a JSON object")
    return payload


def _unique_json_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, child in pairs:
        if key in value:
            raise ValueError("JSON input contains duplicate fields")
        value[key] = child
    return value


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"JSON input contains invalid constant: {value}")


def validate_gate_report(report: dict[str, object], *, platform: str) -> None:
    if platform not in EXPECTED_PLATFORMS:
        raise ValueError("gate report platform is unsupported")
    if len(json.dumps(report, separators=(",", ":")).encode("utf-8")) > MAX_GATE_REPORT_BYTES:
        raise ValueError("gate report exceeds its bounded report limit")
    if set(report) != {
        "schema_version",
        "gate",
        "platform",
        "capability",
        "evidence_kind",
        "ok",
        "required",
        "skipped",
        "failure_category",
        "steps",
        "report",
    }:
        raise ValueError("gate report schema is not closed")
    if type(report.get("schema_version")) is not int or report["schema_version"] != 1:
        raise ValueError("gate report schema is unsupported")
    if report.get("gate") != EXPECTED_GATE:
        raise ValueError("gate report has an unexpected gate identity")
    if report.get("platform") != platform:
        raise ValueError("gate report platform does not match evidence platform")
    if report.get("capability") != EXPECTED_CAPABILITY:
        raise ValueError("gate report has an unexpected capability scope")
    if (
        report.get("evidence_kind") != "real-production-services"
        or report.get("ok") is not True
        or report.get("required") is not True
        or report.get("skipped") is not False
        or report.get("failure_category") is not None
    ):
        raise ValueError("product matrix gate did not pass")
    steps = report.get("steps")
    expected_steps = (
        "product-process",
        "real-scenario",
        "deterministic-contract-cases",
    )
    if (
        not isinstance(steps, list)
        or len(steps) != len(expected_steps)
        or any(
            not isinstance(step, dict)
            or set(step) != {"name", "ok"}
            or step.get("name") != expected_steps[index]
            or step.get("ok") is not True
            for index, step in enumerate(steps)
        )
    ):
        raise ValueError("gate report steps are incomplete")
    report_section = report.get("report")
    if not isinstance(report_section, dict) or set(report_section) != {
        "scenario_count",
        "scenarios",
        "contract_case_count",
        "contract_cases",
    }:
        raise ValueError("gate report is missing structured scenario evidence")
    scenario_count = report_section.get("scenario_count")
    scenarios = report_section.get("scenarios")
    contract_count = report_section.get("contract_case_count")
    contracts = report_section.get("contract_cases")
    if (type(scenario_count) is not int or not isinstance(scenarios, list)
            or scenario_count != len(scenarios) or type(contract_count) is not int
            or not isinstance(contracts, list) or contract_count != len(contracts)):
        raise ValueError("gate report counts do not match its cases")
    # One admission implementation owns the required cases and safe projection.
    path = Path(__file__).with_name("ecosystem-product-gate.py")
    spec = importlib.util.spec_from_file_location("vityo_product_report_contract", path)
    gate = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = gate
    spec.loader.exec_module(gate)
    gate.validate_product_reports(scenarios, contracts)


def validate_pins(
    matrix: dict[str, object], *, styio_commit: str, pafio_commit: str
) -> None:
    if set(matrix) != {"schema_version", "capability", "repositories"}:
        raise ValueError("product matrix schema is not closed")
    if type(matrix.get("schema_version")) is not int or matrix["schema_version"] != 1:
        raise ValueError("product matrix schema is unsupported")
    if matrix.get("capability") != EXPECTED_CAPABILITY:
        raise ValueError("product matrix capability is unsupported")
    repositories = matrix.get("repositories")
    if not isinstance(repositories, dict):
        raise ValueError("product matrix repository pins are missing")
    if set(repositories) != {"styio", "pafio"} or any(
        not isinstance(repositories.get(name), str)
        or COMMIT.fullmatch(str(repositories[name])) is None
        for name in ("styio", "pafio")
    ):
        raise ValueError("product matrix repository pins are not fixed commits")
    if repositories.get("styio") != styio_commit:
        raise ValueError("Styio checkout does not match the fixed product matrix")
    if repositories.get("pafio") != pafio_commit:
        raise ValueError("Pafio checkout does not match the fixed product matrix")


def validate_pty_report(
    report: dict[str, object], *, platform: str, vityo_commit: str
) -> None:
    if report.get("schemaVersion") != 1:
        raise ValueError("native PTY report schema is unsupported")
    if report.get("capability") != EXPECTED_PTY_CAPABILITY:
        raise ValueError("native PTY report has an unexpected capability scope")
    if report.get("platform") != platform:
        raise ValueError("native PTY report platform does not match evidence platform")
    if report.get("provider") != EXPECTED_PTY_PROVIDERS.get(platform):
        raise ValueError("native PTY report provider does not match the platform")
    if report.get("vityoCommit") != vityo_commit:
        raise ValueError("native PTY report does not match the Vityo commit")
    if report.get("ptyDependency") != {
        "name": "portable-pty",
        "version": "0.9.0",
        "owner": "vityod",
    }:
        raise ValueError("native PTY report does not use the fixed vityod PTY dependency")
    if report.get("ok") is not True:
        raise ValueError("native PTY matrix did not pass")
    scenarios = report.get("scenarios")
    if not isinstance(scenarios, list):
        raise ValueError("native PTY report is missing scenarios")
    passed = {
        scenario.get("id")
        for scenario in scenarios
        if isinstance(scenario, dict) and scenario.get("status") == "passed"
    }
    if passed != EXPECTED_PTY_SCENARIOS or len(scenarios) != len(EXPECTED_PTY_SCENARIOS):
        raise ValueError("native PTY report does not prove every required scenario")


def build_evidence(
    *,
    platform: str,
    vityo_commit: str,
    styio_commit: str,
    pafio_commit: str,
    gate_report: dict[str, object],
    pty_report: dict[str, object],
) -> dict[str, object]:
    report = gate_report["report"]
    assert isinstance(report, dict)
    return {
        "schemaVersion": 1,
        "platform": platform,
        "matrixStatus": "proven",
        "completionSemantics": "fixed-real-product-matrix",
        "capability": EXPECTED_CAPABILITY,
        "productCapabilityComplete": True,
        "pinnedRepositories": {
            "vityo": vityo_commit,
            "styio": styio_commit,
            "pafio": pafio_commit,
        },
        "repositoryTreeState": "clean",
        "gateEvidence": {
            "gate": gate_report["gate"],
            "scenarioCount": report["scenario_count"],
        },
        "nativePtyEvidence": {
            "capability": pty_report["capability"],
            "provider": pty_report["provider"],
            "scenarioCount": len(pty_report["scenarios"]),
            "ptyDependency": pty_report["ptyDependency"],
        },
        "message": (
            "The trusted desktop IDE loop passed against fixed real Styio and "
            "Pafio revisions on this platform."
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=("linux", "macos", "windows"), required=True)
    parser.add_argument("--vityo", type=Path, required=True)
    parser.add_argument("--styio", type=Path, required=True)
    parser.add_argument("--pafio", type=Path, required=True)
    parser.add_argument("--matrix", type=Path, required=True)
    parser.add_argument("--gate-report", type=Path, required=True)
    parser.add_argument("--pty-report", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    for name, repository in (
        ("Vityo", args.vityo),
        ("Styio", args.styio),
        ("Pafio", args.pafio),
    ):
        require_clean_checkout(repository, name=name)
    styio_commit = git_head(args.styio)
    pafio_commit = git_head(args.pafio)
    matrix = load_json_object(args.matrix)
    gate_report = load_json_object(args.gate_report)
    pty_report = load_json_object(args.pty_report)
    validate_pins(matrix, styio_commit=styio_commit, pafio_commit=pafio_commit)
    validate_gate_report(gate_report, platform=args.platform)
    vityo_commit = git_head(args.vityo)
    validate_pty_report(
        pty_report,
        platform=args.platform,
        vityo_commit=vityo_commit,
    )
    evidence = build_evidence(
        platform=args.platform,
        vityo_commit=vityo_commit,
        styio_commit=styio_commit,
        pafio_commit=pafio_commit,
        gate_report=gate_report,
        pty_report=pty_report,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(evidence, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(evidence, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
