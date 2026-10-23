#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import shutil
from dataclasses import dataclass
from pathlib import Path, PurePosixPath, PureWindowsPath

ROOT = Path(__file__).resolve().parents[1]
PRODUCT_TEST = ROOT / "products/vityo_app/test/local_product_workflow_test.dart"
PRODUCT_MARKER = b"VITYO_PRODUCT_REPORT "
CONTRACT_MARKER = b"VITYO_PRODUCT_CONTRACT_REPORT "
FLUTTER_PRINT_PREFIX = b"Shell: "
GATE_ID = "vityo-desktop-product-gate"
CAPABILITY = "trusted-desktop-ide-loop"
SCENARIO = "trusted-desktop-styio-loop"
PLATFORMS = {"linux", "macos", "windows"}
MARKER_LIMIT = 65_536
PROJECTED_STRING_LIMIT = 512
FIXTURES = ROOT / "products/vityo_app/test/fixtures/task-resource"
EXPECTED_CASES = json.loads((ROOT / "toolchain/vityo-product-cases.json").read_text())["cases"]
EXPECTED_CONTRACTS = {
    "missing-styio": ("blocked", "styio_missing"),
    "incompatible-machine-contract": ("blocked", "styio_machine_contract_incompatible"),
    "compiler-execution-failure": ("failed", "compiler_execution_failed"),
    "canonical-owner-paths": ("succeeded", "owner_paths_contained"),
}



@dataclass(frozen=True)
class ProcessResult:
    returncode: int
    stdout: bytes
    stderr: bytes
    failure_category: str | None = None


def enabled(value: str | None) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes", "on"}


def running_in_ci(environment: dict[str, str] | None = None) -> bool:
    env = os.environ if environment is None else environment
    return enabled(env.get("CI")) or enabled(env.get("GITHUB_ACTIONS"))


def host_platform() -> str:
    if sys.platform == "darwin":
        return "macos"
    if sys.platform == "win32":
        return "windows"
    return "linux"


def write_product_workspace(root: Path) -> Path:
    """Copy authoritative inputs; all scenario edits use production save services."""
    (root / "src").mkdir(parents=True)
    shutil.copyfile(FIXTURES / "pafio.toml", root / "pafio.toml")
    shutil.copyfile(FIXTURES / "t13_task_history_capture.styio", root / "src/main.styio")
    return root / "pafio.toml"


def build_product_environment(*, temp_root: Path, styio_bin: Path, pafio_bin: Path,
                              lspd_bin: Path, vityod_bin: Path) -> dict[str, str]:
    workspace = temp_root / "project"
    manifest = write_product_workspace(workspace)
    return {
        **os.environ,
        "VITYO_PRODUCT_GATE": "1",
        "VITYO_PAFIO_BIN": str(pafio_bin),
        "VITYO_STYIO_BIN": str(styio_bin),
        "VITYO_STYIO_LSPD_BIN": str(lspd_bin),
        "VITYO_VITYOD_BIN": str(vityod_bin),
        "VITYO_PRODUCT_WORKSPACE_ROOT": str(workspace),
        "VITYO_PRODUCT_MANIFEST_PATH": str(manifest),
        "VITYO_PRODUCT_EVIDENCE": str(temp_root),
        "PAFIO_HOME": str(temp_root / "pafio-home"),
    }


def run_product_process(command: list[str], *, cwd: Path, env: dict[str, str]) -> ProcessResult:
    directory = Path(env["VITYO_PRODUCT_EVIDENCE"])
    record = {"argv": command, "cwd": str(cwd), "exit_code": None,
              "skips": None, "skip_evidence": "See child log; every required case must emit its admission marker."}
    try:
        with (directory / "flutter.stdout.log").open("wb") as stdout, (directory / "flutter.stderr.log").open("wb") as stderr:
            result = subprocess.run(command, cwd=cwd, env=env, stdout=stdout, stderr=stderr, check=False)
        record["exit_code"] = result.returncode
        return ProcessResult(result.returncode, (directory / "flutter.stdout.log").read_bytes(),
                             (directory / "flutter.stderr.log").read_bytes())
    finally:
        (directory / "process.json").write_text(json.dumps(record, indent=2) + "\n")


def parse_product_reports(
    data: bytes | str,
) -> tuple[list[dict[str, object]], list[dict[str, object]]]:
    encoded = data.encode("utf-8") if isinstance(data, str) else data
    products: list[dict[str, object]] = []
    contracts: list[dict[str, object]] = []
    for output_line in encoded.splitlines():
        line = (
            output_line[len(FLUTTER_PRINT_PREFIX) :]
            if output_line.startswith(FLUTTER_PRINT_PREFIX)
            else output_line
        )
        present = [
            (marker, destination)
            for marker, destination in (
                (PRODUCT_MARKER, products),
                (CONTRACT_MARKER, contracts),
            )
            if marker in line
        ]
        if not present:
            continue
        if len(present) != 1 or not line.startswith(present[0][0]):
            raise ValueError("product marker must start its own output line")
        marker, destination = present[0]
        raw_line = line[len(marker) :]
        if len(raw_line) > MARKER_LIMIT:
            raise ValueError("product marker violates its byte limit")
        raw = raw_line.strip()
        if not raw:
            raise ValueError("product marker violates its byte limit")
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_unique_json_object,
            parse_constant=_reject_json_constant,
        )
        if not isinstance(value, dict):
            raise ValueError("product marker must contain one JSON object")
        destination.append(value)
    return products, contracts


def validate_product_reports(scenarios: list[dict[str, object]], contracts: list[dict[str, object]]) -> None:
    seen: set[str] = set()
    for report in scenarios:
        report = _object(report, "case")
        _closed(report, {"schema_version", "scenario", "evidence_kind", "case", "outcome", "accepted"}, "case")
        name = report["case"]
        if (not _is_int(report["schema_version"], 2) or report["scenario"] != SCENARIO
            or report["evidence_kind"] != "real-production-services" or report["accepted"] is not True
            or not isinstance(name, str) or name not in EXPECTED_CASES or name in seen
            or report["outcome"] != EXPECTED_CASES[name]):
            raise ValueError("invalid, duplicate, or unexpected product case")
        seen.add(name)
    if seen != set(EXPECTED_CASES):
        raise ValueError("required product cases are missing")
    expected = EXPECTED_CONTRACTS
    contracts = [_object(report, "contract") for report in contracts]
    if len(contracts) != len(expected) or {r.get("case") for r in contracts} != set(expected):
        raise ValueError("required contract cases are missing or duplicated")
    for report in contracts:
        name = str(report["case"])
        _validate_contract(report, (name, *expected[name]))
    _validate_privacy({"scenarios": scenarios, "contract_cases": contracts})


def _validate_contract(
    report: dict[str, object], expected: tuple[str, str, str]
) -> None:
    _closed(
        report,
        {
            "schema_version",
            "scenario",
            "evidence_kind",
            "case",
            "accepted",
            "outcome",
            "error_category",
            "success_observation",
        },
        "contract report",
    )
    if (
        not _is_int(report["schema_version"], 1)
        or report["scenario"] != SCENARIO
        or report["evidence_kind"] != "deterministic-contract"
        or report["case"] != expected[0]
        or report["accepted"] is not True
        or report["outcome"] != expected[1]
        or report["error_category"] != expected[2]
        or report["success_observation"] is not False
    ):
        raise ValueError("contract report does not match its frozen case")


def _validate_privacy(value: object, parent: str = "report") -> None:
    if isinstance(value, dict):
        forbidden = {
            "stdout",
            "stderr",
            "source",
            "source_text",
            "receipt",
            "receipt_path",
            "runtime_events",
            "runtime_payload",
            "timestamp",
            "environment",
            "executable",
            "machine_identity",
            "token",
        }
        for key, child in value.items():
            normalized = str(key).lower()
            if (
                normalized in forbidden
                or "secret" in normalized
                or "password" in normalized
            ):
                raise ValueError(f"{parent} contains a forbidden evidence field")
            _validate_privacy(child, f"{parent}.{key}")
    elif isinstance(value, list):
        for child in value:
            _validate_privacy(child, parent)
    elif isinstance(value, str):
        if len(value.encode("utf-8")) > PROJECTED_STRING_LIMIT:
            raise ValueError(f"{parent} exceeds the projected string limit")
        if (
            Path(value).is_absolute()
            or PurePosixPath(value).is_absolute()
            or PureWindowsPath(value).is_absolute()
        ):
            raise ValueError(f"{parent} exposes an absolute path")


def _payload(
    *,
    platform: str,
    required: bool,
    process: ProcessResult | None,
    scenarios: list[dict[str, object]],
    contracts: list[dict[str, object]],
    failure: str | None,
    skipped: bool,
) -> dict[str, object]:
    valid = (
        process is not None
        and process.returncode == 0
        and process.failure_category is None
        and failure is None
        and len(scenarios) == len(EXPECTED_CASES)
        and len(contracts) == len(EXPECTED_CONTRACTS)
    )
    return {
        "schema_version": 1,
        "gate": GATE_ID,
        "platform": platform,
        "capability": CAPABILITY,
        "evidence_kind": "real-production-services",
        "ok": valid,
        "required": required,
        "skipped": skipped,
        "failure_category": None if valid else failure,
        "steps": [
            {
                "name": "product-process",
                "ok": bool(
                    process
                    and process.returncode == 0
                    and process.failure_category is None
                ),
            },
            {"name": "real-scenario", "ok": len(scenarios) == len(EXPECTED_CASES) and valid},
            {
                "name": "deterministic-contract-cases",
                "ok": len(contracts) == len(EXPECTED_CONTRACTS) and valid,
            },
        ],
        "report": {
            "scenario_count": len(scenarios),
            "scenarios": scenarios,
            "contract_case_count": len(contracts),
            "contract_cases": contracts,
        },
    }


def main(argv: list[str] | None = None) -> int:
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=("linux", "windows", "macos"))
    parser.add_argument("--styio-bin", type=Path)
    parser.add_argument("--pafio-bin", type=Path)
    parser.add_argument("--lspd-bin", type=Path)
    parser.add_argument("--vityod-bin", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--require-real-matrix", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)

    required = args.require_real_matrix or running_in_ci()
    requested_platform = args.platform or os.environ.get("VITYO_PRODUCT_PLATFORM")
    platform = (
        requested_platform if requested_platform in PLATFORMS else host_platform()
    )
    styio = args.styio_bin or _env_path("VITYO_STYIO_BIN")
    pafio = args.pafio_bin or _env_path("VITYO_PAFIO_BIN")
    lspd = args.lspd_bin or _env_path("VITYO_STYIO_LSPD_BIN")
    vityod = args.vityod_bin or _env_path("VITYO_VITYOD_BIN")
    output = args.output or _env_path("VITYO_PRODUCT_GATE_OUTPUT")
    evidence_root = ROOT / "build/resource-integration"
    evidence_root.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="host-", dir=evidence_root))
    # Even an input refusal owns a new record; latest must not retain a prior
    # successful invocation when this one never launches the child.
    (evidence_root / "latest.json").write_text(json.dumps({"directory": str(directory)}) + "\n")
    missing = (
        requested_platform not in PLATFORMS
        or styio is None
        or not styio.is_file()
        or pafio is None
        or not pafio.is_file()
        or lspd is None or not lspd.is_file()
        or vityod is None or not vityod.is_file()
    )
    if missing:
        payload = _payload(
            platform=platform,
            required=required,
            process=None,
            scenarios=[],
            contracts=[],
            failure="matrix_inputs_unavailable",
            skipped=False,
        )
    else:
        try:
            selected = {"styio": styio, "styio_lspd": lspd, "pafio": pafio, "vityod": vityod}
            (directory / "inputs.json").write_text(json.dumps({name: {
                "path": str(path.resolve()), "size": path.stat().st_size,
                "mtime_ns": path.stat().st_mtime_ns} for name, path in selected.items()}, indent=2) + "\n")
            environment = build_product_environment(temp_root=directory,
                styio_bin=styio.resolve(), pafio_bin=pafio.resolve(),
                lspd_bin=lspd.resolve(), vityod_bin=vityod.resolve())
            process = run_product_process(
                ["flutter", "test", "--reporter", "expanded", "--timeout", "none", str(PRODUCT_TEST)],
                cwd=ROOT / "products/vityo_app", env=environment)
            failure = process.failure_category
            if failure is None and process.returncode != 0:
                failure = "product_test_failed"
            if failure is None:
                try:
                    scenarios, contracts = parse_product_reports(process.stdout)
                    validate_product_reports(scenarios, contracts)
                except (KeyError, TypeError, ValueError):
                    failure = "product_report_invalid"
                    scenarios, contracts = [], []
            else:
                scenarios, contracts = [], []
            if failure is not None:
                # Invalid, partial, stale, or failed child reports are untrusted
                # input. Never copy their fields into the machine report.
                scenarios = []
                contracts = []
            payload = _payload(
                platform=platform,
                required=required,
                process=process,
                scenarios=scenarios,
                contracts=contracts,
                failure=failure,
                skipped=False,
            )
        except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
            payload = _payload(
                platform=platform,
                required=required,
                process=None,
                scenarios=[],
                contracts=[],
                failure="product_report_invalid",
                skipped=False,
            )

    _write_payload(directory / "gate-report.json", payload)
    _write_payload(output, payload)
    print(json.dumps(payload, sort_keys=True) if args.json else _human_summary(payload))
    return 0 if payload["ok"] or (payload["skipped"] and not required) else 1


def _closed(value: dict[str, object], keys: set[str], name: str) -> None:
    if set(value) != keys:
        raise ValueError(f"{name} is not a closed schema")


def _object(value: object, name: str) -> dict[str, object]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise ValueError(f"{name} must be a JSON object")
    return value


def _array(value: object, name: str) -> list[object]:
    if not isinstance(value, list):
        raise ValueError(f"{name} must be a JSON array")
    return value


def _is_int(value: object, expected: int) -> bool:
    return type(value) is int and value == expected


def _unique_json_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, child in pairs:
        if key in value:
            raise ValueError("product marker contains duplicate JSON fields")
        value[key] = child
    return value


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"product marker contains invalid JSON constant: {value}")


def _env_path(name: str) -> Path | None:
    value = os.environ.get(name)
    return Path(value) if value else None


def _write_payload(path: Path | None, payload: dict[str, object]) -> None:
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def _human_summary(payload: dict[str, object]) -> str:
    status = "PASS" if payload["ok"] is True else "FAIL"
    return f"[{status}] {GATE_ID} ({payload['platform']})"


if __name__ == "__main__":
    raise SystemExit(main())
