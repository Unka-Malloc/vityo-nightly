#!/usr/bin/env python3
"""Focused quality entry point for Vityo product lifecycles."""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time
from collections.abc import Mapping

_SCRIPTS_DIR = pathlib.Path(__file__).resolve().parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from vityo_validation_receipt import (
    SUPPORTED_HOST_PLATFORMS,
    ValidationReportError,
    build_ide_report,
    validate_full_suite_plan,
    write_report_atomic,
)


ROOT = _SCRIPTS_DIR.parent


@dataclasses.dataclass(frozen=True)
class FullSuiteEntry:
    requirement: str
    suite: str
    runner_name: str
    rust_source_roots: tuple[str, ...] = ()


FULL_IDE_PLAN = (
    FullSuiteEntry("REQ-IDE-001", "cutover", "cutover"),
    FullSuiteEntry(
        "REQ-IDE-002",
        "workspace-transactions",
        "workspace_transactions",
    ),
    FullSuiteEntry("REQ-IDE-003", "developer-loop", "developer_loop"),
    FullSuiteEntry("REQ-IDE-004", "agent-workbench", "agent_workbench"),
    FullSuiteEntry(
        "REQ-IDE-005",
        "agent-client-protocol",
        "agent_client_protocol",
    ),
    FullSuiteEntry("REQ-IDE-006", "mcp-host", "mcp_host"),
    FullSuiteEntry("REQ-IDE-007", "ide-security", "ide_security"),
    FullSuiteEntry("REQ-IDE-008", "ide-quality", "ide_quality"),
)

FULL_AGENT_PLAN = (
    FullSuiteEntry(
        "REQ-AGENT-001",
        "headless-runtime",
        "headless_runtime",
        ("src/main.rs", "src/application/"),
    ),
    FullSuiteEntry("REQ-AGENT-002", "providers", "providers", ("src/providers/",)),
    FullSuiteEntry("REQ-AGENT-003", "context", "context_engine", ("src/context/",)),
    FullSuiteEntry(
        "REQ-AGENT-004",
        "tools-mcp",
        "tools_mcp",
        ("src/tools/", "src/policy/"),
    ),
    FullSuiteEntry("REQ-AGENT-005", "agent-security", "agent_security", ("src/policy/",)),
    FullSuiteEntry("REQ-AGENT-006", "coding-loop", "coding_loop", ("src/orchestration/",)),
    FullSuiteEntry("REQ-AGENT-007", "session-recovery", "session_recovery", ("src/sessions/",)),
    FullSuiteEntry("REQ-AGENT-008", "multi-agent", "multi_agent", ("src/multi_agent/",)),
    FullSuiteEntry(
        "REQ-AGENT-009",
        "protocol-integration",
        "protocol_integration",
        ("src/protocol/", "src/hosts/"),
    ),
)
RUST_COVERAGE_OUTPUT = "build/evidence/rust-coverage"
RUST_COVERAGE_GATE = "scripts/rust-coverage-gate.py"

_IDE_FULL_REQUIRED_TOOLS = ("cargo", "dart", "flutter")


def tool(name: str) -> str:
    resolved = shutil.which(name)
    if resolved is None:
        raise RuntimeError(f"required tool is not available on PATH: {name}")
    return resolved


def run(
    command: list[str],
    cwd: pathlib.Path = ROOT,
    environment: dict[str, str] | None = None,
) -> int:
    print(
        f"[vityo-quality] {cwd.relative_to(ROOT) or '.'}: {' '.join(command)}",
        flush=True,
    )
    return subprocess.run(
        command,
        cwd=cwd,
        check=False,
        env=environment,
    ).returncode


def cutover() -> int:
    dart = tool("dart")
    flutter = tool("flutter")
    commands = (
        ([sys.executable, "scripts/check_product_line_boundaries.py"], ROOT),
        (
            [
                sys.executable,
                "tests/acceptance/product_lines/cutover_acceptance_test.py",
            ],
            ROOT,
        ),
        ([dart, "analyze"], ROOT / "packages" / "vityo_agent_protocol"),
        ([dart, "test"], ROOT / "packages" / "vityo_agent_protocol"),
        ([dart, "analyze"], ROOT / "products" / "vityo_coding_agent"),
        ([dart, "test"], ROOT / "products" / "vityo_coding_agent"),
        ([flutter, "analyze", "--no-pub"], ROOT / "products" / "vityo_app"),
        ([flutter, "test", "--no-pub", "test/vityo_app_smoke_test.dart"],
         ROOT / "products" / "vityo_app"),
    )
    for command, cwd in commands:
        result = run(command, cwd)
        if result:
            return result
    return 0


def headless_runtime() -> int:
    dart = tool("dart")
    product = ROOT / "products" / "vityo_coding_agent"
    commands = (
        ([sys.executable, "scripts/check_product_line_boundaries.py"], ROOT),
        ([dart, "analyze"], product),
        ([dart, "test", "test/headless"], product),
        (
            [
                dart,
                "--packages=.dart_tool/package_config.json",
                "../../tests/acceptance/vityo_coding_agent/"
                "headless_runtime_acceptance_test.dart",
            ],
            product,
        ),
    )
    for command, cwd in commands:
        result = run(command, cwd)
        if result:
            return result
    return 0


def providers() -> int:
    dart = tool("dart")
    product = ROOT / "products" / "vityo_coding_agent"
    commands = (
        (
            [
                dart,
                "analyze",
                "lib/src/providers",
                "lib/src/cancellation.dart",
                "test/providers",
                "benchmark/provider_stream_benchmark.dart",
            ],
            product,
        ),
        ([dart, "test", "test/providers"], product),
        (
            [
                dart,
                "--packages=.dart_tool/package_config.json",
                "benchmark/provider_stream_benchmark.dart",
            ],
            product,
        ),
        (
            [
                dart,
                "--packages=.dart_tool/package_config.json",
                "../../tests/acceptance/vityo_coding_agent/"
                "provider_runtime_acceptance_test.dart",
            ],
            product,
        ),
    )
    for command, cwd in commands:
        result = run(command, cwd)
        if result:
            return result
    return 0


def context_engine() -> int:
    dart = tool("dart")
    product = ROOT / "products" / "vityo_coding_agent"
    commands = (
        (
            [
                dart,
                "analyze",
                "lib/src/context",
                "test/context",
                "benchmark/context_engine_benchmark.dart",
            ],
            product,
        ),
        ([dart, "test", "test/context"], product),
        (
            [
                dart,
                "--packages=.dart_tool/package_config.json",
                "benchmark/context_engine_benchmark.dart",
            ],
            product,
        ),
        (
            [
                dart,
                "--packages=.dart_tool/package_config.json",
                "../../tests/acceptance/vityo_coding_agent/"
                "context_engine_acceptance_test.dart",
            ],
            product,
        ),
    )
    for command, cwd in commands:
        result = run(command, cwd)
        if result:
            return result
    return 0


def tools_mcp() -> int:
    dart = tool("dart")
    product = ROOT / "products" / "vityo_coding_agent"
    commands = (
        (
            [
                dart,
                "analyze",
                "lib/src/tools",
                "lib/src/policy",
                "test/tools",
            ],
            product,
        ),
        ([dart, "test", "test/tools"], product),
        (
            [
                dart,
                "--packages=.dart_tool/package_config.json",
                "../../tests/acceptance/vityo_coding_agent/"
                "tool_policy_acceptance_test.dart",
            ],
            product,
        ),
    )
    for command, cwd in commands:
        result = run(command, cwd)
        if result:
            return result
    return 0


def agent_security() -> int:
    dart = tool("dart")
    product = ROOT / "products" / "vityo_coding_agent"
    commands = (
        (
            [
                dart,
                "analyze",
                "lib/src/policy",
                "lib/src/tools/tool_executor.dart",
                "test/security",
            ],
            product,
        ),
        ([dart, "test", "test/security"], product),
    )
    for command, cwd in commands:
        result = run(command, cwd)
        if result:
            return result
    return 0


def coding_loop() -> int:
    dart = tool("dart")
    product = ROOT / "products" / "vityo_coding_agent"
    commands = (
        (
            [
                dart,
                "analyze",
                "lib/src/orchestration",
                "test/orchestration",
            ],
            product,
        ),
        ([dart, "test", "test/orchestration"], product),
        (
            [
                dart,
                "--packages=.dart_tool/package_config.json",
                "../../tests/acceptance/vityo_coding_agent/"
                "coding_loop_acceptance_test.dart",
            ],
            product,
        ),
    )
    for command, cwd in commands:
        result = run(command, cwd)
        if result:
            return result
    return 0


def session_recovery() -> int:
    dart = tool("dart")
    product = ROOT / "products" / "vityo_coding_agent"
    commands = (
        (
            [
                dart,
                "analyze",
                "lib/src/sessions",
                "test/sessions",
                "integration_test/session_recovery_test.dart",
            ],
            product,
        ),
        ([dart, "test", "test/sessions"], product),
        (
            [
                dart,
                "--packages=.dart_tool/package_config.json",
                "integration_test/session_recovery_test.dart",
            ],
            product,
        ),
        (
            [
                dart,
                "--packages=.dart_tool/package_config.json",
                "../../tests/acceptance/vityo_coding_agent/"
                "session_recovery_acceptance_test.dart",
            ],
            product,
        ),
    )
    for command, cwd in commands:
        result = run(command, cwd)
        if result:
            return result
    return 0


def multi_agent() -> int:
    dart = tool("dart")
    product = ROOT / "products" / "vityo_coding_agent"
    commands = (
        (
            [
                dart,
                "analyze",
                "lib/src/multi_agent",
                "test/multi_agent",
                "integration_test/multi_agent_worktree_test.dart",
            ],
            product,
        ),
        ([dart, "test", "test/multi_agent"], product),
        (
            [
                dart,
                "--packages=.dart_tool/package_config.json",
                "integration_test/multi_agent_worktree_test.dart",
            ],
            product,
        ),
        (
            [
                dart,
                "--packages=.dart_tool/package_config.json",
                "../../tests/acceptance/vityo_coding_agent/"
                "multi_agent_acceptance_test.dart",
            ],
            product,
        ),
    )
    for command, cwd in commands:
        result = run(command, cwd)
        if result:
            return result
    return 0


def protocol_integration() -> int:
    dart = tool("dart")
    product = ROOT / "products" / "vityo_coding_agent"
    commands = (
        (
            [
                dart,
                "analyze",
                "lib/src/protocol",
                "bin/vityo_coding_agent.dart",
                "benchmark/release_evaluation.dart",
                "integration_test/protocol_integration_test.dart",
            ],
            product,
        ),
        (
            [
                dart,
                "--packages=.dart_tool/package_config.json",
                "integration_test/protocol_integration_test.dart",
            ],
            product,
        ),
        (
            [
                dart,
                "--packages=.dart_tool/package_config.json",
                "benchmark/release_evaluation.dart",
            ],
            product,
        ),
        (
            [
                dart,
                "--packages=.dart_tool/package_config.json",
                "../../tests/acceptance/vityo_coding_agent/"
                "protocol_release_acceptance_test.dart",
            ],
            product,
        ),
    )
    for command, cwd in commands:
        result = run(command, cwd)
        if result:
            return result
    return 0


def workspace_transactions() -> int:
    dart = tool("dart")
    product = ROOT / "products" / "vityo_app"
    commands = (
        ([sys.executable, "scripts/check_product_line_boundaries.py"], ROOT),
        ([sys.executable, "scripts/check_architecture_boundaries.py"], ROOT),
        ([dart, "analyze", "lib"], product),
        (
            [
                dart,
                "test",
                "test/workspace/workspace_transaction_service_test.dart",
            ],
            product,
        ),
        (
            [
                dart,
                "--packages=.dart_tool/package_config.json",
                "integration_test/standalone_smoke_test.dart",
            ],
            product,
        ),
        (
            [
                dart,
                "--packages=.dart_tool/package_config.json",
                "../../tests/acceptance/vityo_app/"
                "workspace_transactions_acceptance_test.dart",
            ],
            product,
        ),
    )
    for command, cwd in commands:
        result = run(command, cwd)
        if result:
            return result
    return 0


def developer_loop() -> int:
    dart = tool("dart")
    product = ROOT / "products" / "vityo_app"
    commands = (
        ([sys.executable, "scripts/check_product_line_boundaries.py"], ROOT),
        ([sys.executable, "scripts/check_architecture_boundaries.py"], ROOT),
        (
            [
                dart,
                "analyze",
                "lib/src/ide",
                "test/developer_loop",
                "integration_test/developer_loop_test.dart",
            ],
            product,
        ),
        (
            [
                dart,
                "test",
                "test/developer_loop/developer_loop_service_test.dart",
            ],
            product,
        ),
        (
            [
                dart,
                "--packages=.dart_tool/package_config.json",
                "integration_test/developer_loop_test.dart",
            ],
            product,
        ),
        (
            [
                dart,
                "--packages=.dart_tool/package_config.json",
                "../../tests/acceptance/vityo_app/"
                "developer_loop_acceptance_test.dart",
            ],
            product,
        ),
    )
    for command, cwd in commands:
        result = run(command, cwd)
        if result:
            return result
    return 0


def agent_client_protocol() -> int:
    dart = tool("dart")
    protocol = ROOT / "packages" / "vityo_agent_protocol"
    product = ROOT / "products" / "vityo_app"
    commands = (
        ([dart, "analyze"], protocol, None),
        ([dart, "test"], protocol, None),
        (
            [
                dart,
                "analyze",
                "lib/src/ide/agent_client",
                "test/agent_client",
                "integration_test/agent_client_protocol_test.dart",
            ],
            product,
            None,
        ),
        (
            [dart, "test", "test/agent_client/agent_client_contract_test.dart"],
            product,
            None,
        ),
        (
            [
                dart,
                "--packages=.dart_tool/package_config.json",
                "integration_test/agent_client_protocol_test.dart",
            ],
            product,
            None,
        ),
        (
            [
                dart,
                "--packages=.dart_tool/package_config.json",
                "../../tests/acceptance/vityo_app/"
                "agent_client_protocol_acceptance_test.dart",
            ],
            product,
            {
                **os.environ,
                "VITYO_ACCEPTANCE_PRIVATE": "present",
            },
        ),
    )
    for command, cwd, environment in commands:
        result = run(command, cwd, environment)
        if result:
            return result
    return 0


def mcp_host() -> int:
    dart = tool("dart")
    product = ROOT / "products" / "vityo_app"
    commands = (
        (
            [
                dart,
                "analyze",
                "lib/src/ide/agent_client/mcp",
                "test/mcp_host",
                "integration_test/mcp_host_test.dart",
            ],
            product,
        ),
        ([dart, "test", "test/mcp_host"], product),
        (
            [
                dart,
                "--packages=.dart_tool/package_config.json",
                "integration_test/mcp_host_test.dart",
            ],
            product,
        ),
    )
    for command, cwd in commands:
        result = run(command, cwd)
        if result:
            return result
    return 0


def ide_security() -> int:
    dart = tool("dart")
    product = ROOT / "products" / "vityo_app"
    commands = (
        (
            [
                dart,
                "analyze",
                "lib/src/ide/agent_client/mcp",
                "test/mcp_host/mcp_host_security_test.dart",
            ],
            product,
        ),
        (
            [dart, "test", "test/mcp_host/mcp_host_security_test.dart"],
            product,
        ),
    )
    for command, cwd in commands:
        result = run(command, cwd)
        if result:
            return result
    return 0


def agent_workbench() -> int:
    dart = tool("dart")
    flutter = tool("flutter")
    product = ROOT / "products" / "vityo_app"
    commands = (
        (
            [
                flutter,
                "analyze",
                "--no-pub",
                "lib/src/ide/workbench/agent_collaboration",
                "lib/src/presentation/agent_workbench",
                "test/agent_workbench",
                "integration_test/agent_workbench_test.dart",
            ],
            product,
        ),
        (
            [
                flutter,
                "test",
                "--no-pub",
                "test/agent_workbench",
            ],
            product,
        ),
        (
            [
                dart,
                "--packages=.dart_tool/package_config.json",
                "integration_test/agent_workbench_test.dart",
            ],
            product,
        ),
        (
            [
                flutter,
                "test",
                "--no-pub",
                "../../tests/acceptance/vityo_app/"
                "agent_workbench_acceptance_test.dart",
            ],
            product,
        ),
    )
    for command, cwd in commands:
        result = run(command, cwd)
        if result:
            return result
    return 0


def _native_desktop_test_command(flutter: str) -> list[str]:
    return [
        flutter,
        "test",
        "--no-pub",
        "-d",
        _host_platform(),
        "integration_test/vityod_reconnect_test.dart",
    ]


def native_desktop() -> int:
    if _host_platform() not in {"linux", "macos"}:
        raise RuntimeError("desktop reconnect integration requires Linux or macOS")
    flutter = tool("flutter")
    return run(
        _native_desktop_test_command(flutter),
        ROOT / "products" / "vityo_app",
    )


def _macos_native_ui_test_paths(product: pathlib.Path) -> tuple[pathlib.Path, ...]:
    integration_tests = product / "integration_test"
    discovered = tuple(sorted(integration_tests.glob("*_native_ui_test.dart")))
    platform_specific = (
        integration_tests / "editor_native_input_test.dart",
        integration_tests / "platform_secure_credential_storage_test.dart",
        integration_tests / "workbench_visual_capture_test.dart",
    )
    return (*discovered, *platform_specific)


def macos_native_ui() -> int:
    if _host_platform() != "macos":
        raise RuntimeError("macOS-native IDE integration tests require a macOS host")
    flutter = tool("flutter")
    product = ROOT / "products" / "vityo_app"
    for test_path in _macos_native_ui_test_paths(product):
        result = run(
            [
                flutter,
                "test",
                "--no-pub",
                "-d",
                "macos",
                str(test_path.relative_to(product)),
            ],
            product,
        )
        if result:
            return result
    return 0


def _quality_runtime_test_command(flutter: str) -> list[str]:
    return [
        flutter,
        "test",
        "--no-pub",
        "../../tests/acceptance/vityo_app/quality_runtime_acceptance_test.dart",
    ]


def quality_runtime() -> int:
    flutter = tool("flutter")
    return run(
        _quality_runtime_test_command(flutter),
        ROOT / "products" / "vityo_app",
    )


def _recovery_isolation_command(dart: str) -> list[str]:
    return [
        dart,
        "--packages=.dart_tool/package_config.json",
        "integration_test/recovery_isolation_test.dart",
    ]


def recovery_isolation() -> int:
    dart = tool("dart")
    return run(
        _recovery_isolation_command(dart),
        ROOT / "products" / "vityo_app",
    )


def daemon_core() -> int:
    dart = tool("dart")
    daemon_protocol = ROOT / "packages" / "vityo_daemon_protocol"
    commands = (
        ([dart, "analyze"], daemon_protocol),
        ([dart, "test"], daemon_protocol),
    )
    for command, cwd in commands:
        code = run(command, cwd)
        if code:
            return code
    return 0


def ide_quality() -> int:
    code = daemon_core()
    if code:
        return code
    dart = tool("dart")
    flutter = tool("flutter")
    product = ROOT / "products" / "vityo_app"
    commands = (
        (
            _native_desktop_test_command(flutter),
            product,
        ),
        (
            [
                flutter,
                "analyze",
                "--no-pub",
                "lib/src/ide/agent_client",
                "lib/src/ide/platform",
                "lib/src/presentation/agent_workbench",
                "benchmark/agent_collaboration_benchmark.dart",
                "test/ide_quality",
                "integration_test/recovery_isolation_test.dart",
            ],
            product,
        ),
        # The formal REQ-IDE-008 lane owns the single platform-independent
        # full Flutter regression. Earlier suites remain focused and do not
        # duplicate this invocation.
        ([flutter, "test", "--no-pub"], product),
        (
            [
                dart,
                "--packages=.dart_tool/package_config.json",
                "benchmark/agent_collaboration_benchmark.dart",
            ],
            product,
        ),
        (
            _recovery_isolation_command(dart),
            product,
        ),
        (
            [
                sys.executable,
                "packaging/vityo/desktop_delivery.py",
                "--repo-root",
                ".",
            ],
            ROOT,
        ),
        (
            _quality_runtime_test_command(flutter),
            product,
        ),
        (
            [
                sys.executable,
                "tests/acceptance/vityo_app/"
                "quality_packaging_acceptance_test.py",
            ],
            ROOT,
        ),
        (
            [
                sys.executable,
                "tests/acceptance/vityo_app/"
                "vityod_packaging_acceptance_test.py",
            ],
            ROOT,
        ),
        (
            [
                sys.executable,
                "scripts/vityod-desktop-matrix-gate.py",
                "--fixtures-only",
            ],
            ROOT,
        ),
        ([sys.executable, "scripts/check_architecture_boundaries.py"], ROOT),
        ([sys.executable, "scripts/check_security_baseline.py"], ROOT),
        ([sys.executable, "scripts/docs-index.py", "--check"], ROOT),
        ([sys.executable, "tests/test_docs_tooling_coverage.py"], ROOT),
        (
            [
                sys.executable,
                "scripts/repo-hygiene-gate.py",
                "--mode",
                "tracked",
            ],
            ROOT,
        ),
    )
    for command, cwd in commands:
        result = run(command, cwd)
        if result:
            return result
    return 0


def full_suite_plan() -> list[dict[str, str]]:
    plan = [
        {
            "requirement": entry.requirement,
            "suite": entry.suite,
            "runner": entry.runner_name,
        }
        for entry in FULL_IDE_PLAN
    ]
    validate_full_suite_plan(plan)
    return plan


def _host_platform() -> str:
    return {
        "win32": "windows",
        "darwin": "macos",
        "linux": "linux",
    }.get(sys.platform, sys.platform)


def _resolve_required_tools() -> None:
    for name in _IDE_FULL_REQUIRED_TOOLS:
        if shutil.which(name) is None:
            raise ValidationReportError(
                "tool_unavailable",
                f"required tool is not available on PATH: {name}",
            )


def _not_run_outcomes(
    failure_code: str,
    plan: tuple[FullSuiteEntry, ...] = FULL_IDE_PLAN,
) -> dict[str, dict[str, object]]:
    return {
        entry.requirement: {
            "status": "not-run",
            "suite": entry.suite,
            "runner": entry.runner_name,
            "duration_ms": 0,
            "failure_code": failure_code,
        }
        for entry in plan
    }


def _print_json(payload: Mapping[str, object]) -> None:
    print(
        json.dumps(
            payload,
            indent=2,
            sort_keys=True,
            ensure_ascii=False,
        )
    )


def _preflight_ide_full() -> dict[str, object]:
    checks: list[dict[str, object]] = []
    plan: list[dict[str, str]] = []
    failure_code: str | None = None
    platform = _host_platform()

    def record(name: str, action) -> None:
        nonlocal failure_code
        try:
            action()
            checks.append({"name": name, "status": "passed"})
        except ValidationReportError as error:
            checks.append(
                {
                    "name": name,
                    "status": "failed",
                    "failure_code": error.code,
                }
            )
            if failure_code is None:
                failure_code = error.code

    def check_requirement_mapping() -> None:
        nonlocal plan
        plan = full_suite_plan()

    def check_tools() -> None:
        _resolve_required_tools()

    def check_host() -> None:
        if platform not in SUPPORTED_HOST_PLATFORMS:
            raise ValidationReportError(
                "unsupported_host",
                "validation platform is unsupported",
            )

    record("requirement_mapping", check_requirement_mapping)
    record("tools", check_tools)
    record("host", check_host)

    if not plan:
        plan = [
            {
                "requirement": entry.requirement,
                "suite": entry.suite,
                "runner": entry.runner_name,
            }
            for entry in FULL_IDE_PLAN
        ]

    return {
        "schema_version": 1,
        "product": "vityo",
        "suite": "full",
        "mode": "preflight",
        "ready": failure_code is None,
        "platform": platform,
        "requirements": plan,
        "checks": checks,
        "failure_code": failure_code,
    }


def _write_formal_report(
    report_path: pathlib.Path,
    payload: Mapping[str, object],
) -> int:
    try:
        write_report_atomic(report_path, payload)
    except Exception:
        _print_json(
            {
                "schema_version": 1,
                "product": payload.get("product", "vityo"),
                "suite": payload.get("suite", "full"),
                "status": "failed",
                "failure_code": "report_write_failed",
            }
        )
        return 1
    return 0 if payload.get("status") == "passed" else 1


def _ide_full_formal(report_path: pathlib.Path) -> int:
    preflight = _preflight_ide_full()
    platform = str(preflight.get("platform") or _host_platform())
    if not preflight.get("ready"):
        failure_code = str(preflight.get("failure_code") or "preflight_failed")
        payload = build_ide_report(
            platform=platform,
            outcomes=_not_run_outcomes(failure_code),
            failure_code=failure_code,
        )
        return _write_formal_report(report_path, payload)

    outcomes: dict[str, dict[str, object]] = {}
    suite_failed = False
    try:
        validate_full_suite_plan(full_suite_plan())
        for entry in FULL_IDE_PLAN:
            started = time.monotonic()
            runner = globals()[entry.runner_name]
            try:
                exit_code = int(runner())
            except Exception:
                exit_code = 1
            outcome: dict[str, object] = {
                "status": "passed" if exit_code == 0 else "failed",
                "suite": entry.suite,
                "runner": entry.runner_name,
                "duration_ms": max(
                    0,
                    round((time.monotonic() - started) * 1000),
                ),
            }
            if exit_code != 0:
                suite_failed = True
                outcome["failure_code"] = "suite_failed"
            outcomes[entry.requirement] = outcome
        payload = build_ide_report(
            platform=platform,
            outcomes=outcomes,
            failure_code="suite_failed" if suite_failed else None,
        )
    except ValidationReportError as error:
        for entry in FULL_IDE_PLAN:
            outcomes.setdefault(
                entry.requirement,
                {
                    "status": "not-run",
                    "suite": entry.suite,
                    "runner": entry.runner_name,
                    "duration_ms": 0,
                    "failure_code": error.code,
                },
            )
        payload = build_ide_report(
            platform=platform,
            outcomes=outcomes,
            failure_code=error.code,
        )
    except Exception:
        for entry in FULL_IDE_PLAN:
            outcomes.setdefault(
                entry.requirement,
                {
                    "status": "not-run",
                    "suite": entry.suite,
                    "runner": entry.runner_name,
                    "duration_ms": 0,
                    "failure_code": "validation_harness_failed",
                },
            )
        payload = build_ide_report(
            platform=platform,
            outcomes=outcomes,
            failure_code="validation_harness_failed",
        )
    return _write_formal_report(report_path, payload)


def ide_full(
    *,
    plan_only: bool,
    preflight: bool,
    report_path: pathlib.Path,
) -> int:
    if plan_only and preflight:
        raise ValueError("plan_only and preflight are mutually exclusive")
    plan = full_suite_plan()
    if plan_only:
        _print_json(
            {
                "schema_version": 1,
                "product": "vityo",
                "suite": "full",
                "mode": "plan_only",
                "requirements": plan,
            }
        )
        return 0
    if preflight:
        report = _preflight_ide_full()
        _print_json(report)
        return 0 if report.get("ready") else 1
    return _ide_full_formal(report_path)


def agent_rust_coverage_command(
    phase: str,
    *,
    output_dir: str = RUST_COVERAGE_OUTPUT,
) -> list[str]:
    if phase not in {"collect-only", "report-only"}:
        raise ValueError("Rust coverage phase must be collect-only or report-only")
    command = [
        sys.executable,
        RUST_COVERAGE_GATE,
        "--product",
        "coding-agent",
        f"--{phase}",
        "--output-dir",
        output_dir,
    ]
    for entry in FULL_AGENT_PLAN:
        if not entry.rust_source_roots:
            raise ValidationReportError(
                "rust_coverage_mapping_missing",
                f"{entry.requirement} has no Rust source mapping",
            )
        for source_root in entry.rust_source_roots:
            command.extend(("--require-module", f"{entry.requirement}={source_root}"))
    return command


def agent_rust_coverage_report(*, output_dir: str = RUST_COVERAGE_OUTPUT) -> int:
    return run(agent_rust_coverage_command("report-only", output_dir=output_dir))


def coding_agent_full(
    *,
    receipt_path: pathlib.Path,
    collect_coverage: bool = False,
    coverage_output_dir: str = RUST_COVERAGE_OUTPUT,
) -> int:
    platform = _host_platform()
    outcomes: dict[str, dict[str, object]] = {}
    for entry in FULL_AGENT_PLAN:
        started = time.monotonic()
        runner = globals().get(entry.runner_name)
        try:
            exit_code = 1 if runner is None else int(runner())
        except Exception:
            exit_code = 1
        outcome: dict[str, object] = {
            "status": "passed" if exit_code == 0 else "failed",
            "suite": entry.suite,
            "runner": entry.runner_name,
            "duration_ms": max(
                0,
                round((time.monotonic() - started) * 1000),
            ),
        }
        if exit_code != 0:
            outcome["failure_code"] = (
                "suite_runner_unavailable" if runner is None else "suite_failed"
            )
        outcomes[entry.requirement] = outcome

    all_passed = all(
        outcome["status"] == "passed" for outcome in outcomes.values()
    )
    rust_coverage: dict[str, object] | None = None
    failure_code = None if all_passed else "suite_failed"
    if collect_coverage and all_passed:
        try:
            coverage_code = run(
                agent_rust_coverage_command(
                    "collect-only",
                    output_dir=coverage_output_dir,
                )
            )
            coverage_passed = coverage_code == 0
            rust_coverage = {
                "status": "passed" if coverage_passed else "failed",
                "product": "coding-agent",
                "output_dir": coverage_output_dir,
                "exit_code": coverage_code,
            }
            if not coverage_passed:
                failure_code = "coverage_collection_failed"
        except Exception:
            rust_coverage = {
                "status": "failed",
                "product": "coding-agent",
                "output_dir": coverage_output_dir,
                "failure_code": "coverage_collection_failed",
            }
            failure_code = "coverage_collection_failed"
    elif collect_coverage:
        rust_coverage = {
            "status": "not-run",
            "product": "coding-agent",
            "output_dir": coverage_output_dir,
            "reason": "Agent requirement suites did not pass",
        }

    passed = all_passed and (
        not collect_coverage
        or (
            rust_coverage is not None
            and rust_coverage.get("status") == "passed"
        )
    )
    payload: dict[str, object] = {
        "schema_version": 1,
        "product": "vityo_coding_agent",
        "suite": "full",
        "status": "passed" if passed else "failed",
        "failure_code": None if passed else failure_code or "validation_harness_failed",
        "platform": platform,
        "requirements": outcomes,
    }
    if rust_coverage is not None:
        payload["rust_coverage"] = rust_coverage
    try:
        write_report_atomic(receipt_path, payload)
    except Exception:
        _print_json(
            {
                "schema_version": 1,
                "product": "vityo_coding_agent",
                "suite": "full",
                "status": "failed",
                "failure_code": "report_write_failed",
            }
        )
        return 1
    return 0 if passed else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--product", required=True)
    parser.add_argument("--suite", required=True)
    parser.add_argument("--plan-only", action="store_true")
    parser.add_argument("--preflight", action="store_true")
    parser.add_argument(
        "--receipt",
        type=pathlib.Path,
        default=None,
    )
    parser.add_argument("--coverage", action="store_true")
    parser.add_argument("--coverage-output-dir", default=RUST_COVERAGE_OUTPUT)
    args = parser.parse_args()
    if args.plan_only and args.preflight:
        parser.error("--plan-only and --preflight are mutually exclusive")
    if args.plan_only and (args.product, args.suite) != ("ide", "full"):
        parser.error("--plan-only is supported only for ide/full")
    if args.preflight and (args.product, args.suite) != ("ide", "full"):
        parser.error("--preflight is supported only for ide/full")
    if args.coverage and (args.product, args.suite) != ("coding-agent", "full"):
        parser.error("--coverage is supported only for coding-agent/full")
    if (args.product, args.suite) == ("ide", "cutover"):
        return cutover()
    if (args.product, args.suite) == ("coding-agent", "headless-runtime"):
        return headless_runtime()
    if (args.product, args.suite) == ("coding-agent", "providers"):
        return providers()
    if (args.product, args.suite) == ("coding-agent", "context"):
        return context_engine()
    if (args.product, args.suite) == ("coding-agent", "tools-mcp"):
        return tools_mcp()
    if (args.product, args.suite) == ("coding-agent", "agent-security"):
        return agent_security()
    if (args.product, args.suite) == ("coding-agent", "coding-loop"):
        return coding_loop()
    if (args.product, args.suite) == ("coding-agent", "session-recovery"):
        return session_recovery()
    if (args.product, args.suite) == ("coding-agent", "multi-agent"):
        return multi_agent()
    if (args.product, args.suite) == ("coding-agent", "protocol-integration"):
        return protocol_integration()
    if (args.product, args.suite) == ("coding-agent", "full"):
        report_path = args.receipt or (
            ROOT
            / "artifacts"
            / "validation"
            / "vityo-coding-agent-full.json"
        )
        return coding_agent_full(
            receipt_path=report_path.resolve(),
            collect_coverage=args.coverage,
            coverage_output_dir=args.coverage_output_dir,
        )
    if (args.product, args.suite) == ("coding-agent", "coverage-report"):
        return agent_rust_coverage_report(output_dir=args.coverage_output_dir)
    if (args.product, args.suite) == ("ide", "workspace-transactions"):
        return workspace_transactions()
    if (args.product, args.suite) == ("ide", "developer-loop"):
        return developer_loop()
    if (args.product, args.suite) == ("ide", "agent-client-protocol"):
        return agent_client_protocol()
    if (args.product, args.suite) == ("ide", "mcp-host"):
        return mcp_host()
    if (args.product, args.suite) == ("ide", "ide-security"):
        return ide_security()
    if (args.product, args.suite) == ("ide", "agent-workbench"):
        return agent_workbench()
    if (args.product, args.suite) == ("ide", "native-desktop"):
        return native_desktop()
    if (args.product, args.suite) == ("ide", "macos-native-ui"):
        return macos_native_ui()
    if (args.product, args.suite) == ("ide", "quality-runtime"):
        return quality_runtime()
    if (args.product, args.suite) == ("ide", "recovery-isolation"):
        return recovery_isolation()
    if (args.product, args.suite) == ("ide", "daemon-core"):
        return daemon_core()
    if (args.product, args.suite) == ("ide", "ide-quality"):
        return ide_quality()
    if (args.product, args.suite) == ("ide", "full"):
        report_path = args.receipt or (
            ROOT / "artifacts" / "validation" / "vityo-full.json"
        )
        return ide_full(
            plan_only=args.plan_only,
            preflight=args.preflight,
            report_path=report_path.resolve(),
        )
    parser.error(f"unsupported suite: {args.product}/{args.suite}")


if __name__ == "__main__":
    raise SystemExit(main())
