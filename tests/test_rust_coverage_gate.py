#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import io
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
GATE_PATH = REPO_ROOT / "scripts" / "rust-coverage-gate.py"


def load_gate_module():
    spec = importlib.util.spec_from_file_location("rust_coverage_gate", GATE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {GATE_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def lcov_record(source: str, line_hits: list[tuple[int, int]]) -> str:
    found = len(line_hits)
    hit = sum(1 for _, count in line_hits if count > 0)
    details = "".join(f"DA:{line},{count}\n" for line, count in line_hits)
    return f"TN:\nSF:{source}\n{details}LF:{found}\nLH:{hit}\nend_of_record\n"


class RustCoverageGateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.gate = load_gate_module()
        self.temporary = tempfile.TemporaryDirectory(prefix="rust-coverage-test-")
        self.root = Path(self.temporary.name)
        self.output_dir = self.root / "build/evidence/rust-coverage"
        self.patcher = mock.patch.object(self.gate, "ROOT", self.root)
        self.patcher.start()
        for info in self.gate.PRODUCTS.values():
            manifest = self.root / info["manifest"]
            manifest.parent.mkdir(parents=True, exist_ok=True)
            manifest.write_text("[workspace]\n", encoding="utf-8")
            manifest.with_name("Cargo.lock").write_text("version = 4\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.patcher.stop()
        self.temporary.cleanup()

    def _write_report(self, product: str, body: str) -> Path:
        destination = self.gate.report_path(product, self.output_dir)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(body, encoding="utf-8")
        return destination

    def _first_party_path(self, product: str, workspace_source: str) -> str:
        root = self.gate.PRODUCTS[product]["workspace_root"]
        return f"{root.as_posix()}/{workspace_source}"

    def test_collect_builds_exact_locked_workspace_commands_and_normalizes_paths(self) -> None:
        calls: list[list[str]] = []

        def fake_run(command, *, cwd, check):
            calls.append(command)
            self.assertEqual(cwd, self.root)
            self.assertFalse(check)
            product = "coding-agent" if "products/vityo_coding_agent/Cargo.toml" in command else "vityod"
            source = "src/lib.rs" if product == "coding-agent" else "crates/vityod/src/main.rs"
            output_path = command[command.index("--output-path") + 1]
            destination = self.root / output_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(lcov_record(source, [(1, 1), (2, 0)]), encoding="utf-8")
            return SimpleNamespace(returncode=0)

        with mock.patch.object(self.gate.shutil, "which", return_value="/tool/bin/tool"):
            with mock.patch.object(self.gate.subprocess, "run", side_effect=fake_run):
                result = self.gate.run_gate(
                    product="all",
                    output_dir=self.output_dir,
                    collect=True,
                    report=False,
                    fail_under=None,
                    required_modules=[],
                )

        self.assertEqual(result, 0)
        self.assertEqual(len(calls), 2)
        for product, command in zip(self.gate.PRODUCTS, calls, strict=True):
            self.assertEqual(command[:2], ["cargo", "llvm-cov"])
            self.assertEqual(
                command[command.index("--manifest-path") + 1],
                self.gate.PRODUCTS[product]["manifest"].as_posix(),
            )
            self.assertIn("--workspace", command)
            self.assertIn("--all-targets", command)
            self.assertIn("--locked", command)
            self.assertIn("--lcov", command)
            self.assertIn("--remap-path-prefix", command)
            self.assertEqual(
                command[command.index("--output-path") + 1],
                f"build/evidence/rust-coverage/{self.gate.PRODUCTS[product]['report']}",
            )
            written = self.gate.report_path(product, self.output_dir).read_text(encoding="utf-8")
            self.assertIn(f"SF:{self.gate.PRODUCTS[product]['workspace_root']}/", written)
            self.assertNotIn(str(self.root), written)

    def test_collection_runs_only_the_selected_product_once(self) -> None:
        calls: list[list[str]] = []

        def fake_run(command, *, cwd, check):
            calls.append(command)
            destination = self.root / command[command.index("--output-path") + 1]
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(
                lcov_record("src/lib.rs", [(1, 1)]),
                encoding="utf-8",
            )
            return SimpleNamespace(returncode=0)

        with mock.patch.object(self.gate.shutil, "which", return_value="/tool/bin/tool"):
            with mock.patch.object(self.gate.subprocess, "run", side_effect=fake_run):
                result = self.gate.run_gate(
                    product="coding-agent",
                    output_dir=self.output_dir,
                    collect=True,
                    report=False,
                    fail_under=None,
                    required_modules=[],
                )

        self.assertEqual(result, 0)
        self.assertEqual(len(calls), 1)
        self.assertIn("products/vityo_coding_agent/Cargo.toml", calls[0])

    def test_collection_checks_repeated_module_roots_from_the_quality_registry(self) -> None:
        body = lcov_record("src/main.rs", [(1, 1)]) + lcov_record(
            "src/application/mod.rs", [(1, 1), (2, 0)]
        )

        def fake_run(command, *, cwd, check):
            destination = self.root / command[command.index("--output-path") + 1]
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(body, encoding="utf-8")
            return SimpleNamespace(returncode=0)

        requirements = [
            self.gate.parse_module_requirement("REQ-AGENT-001=src/main.rs"),
            self.gate.parse_module_requirement("REQ-AGENT-001=src/application/"),
        ]
        stdout = io.StringIO()
        with mock.patch.object(self.gate.shutil, "which", return_value="/tool/bin/tool"):
            with mock.patch.object(self.gate.subprocess, "run", side_effect=fake_run):
                with redirect_stdout(stdout):
                    result = self.gate.collect_product(
                        "coding-agent", self.output_dir, requirements
                    )

        self.assertEqual(result, 0)
        self.assertIn("REQ-AGENT-001: 2/3 executed lines", stdout.getvalue())

    def test_collection_rejects_zero_hit_module_but_keeps_safe_report_for_review(self) -> None:
        body = lcov_record("src/providers/mod.rs", [(1, 0), (2, 0)]) + lcov_record(
            "src/lib.rs", [(1, 1)]
        )

        def fake_run(command, *, cwd, check):
            destination = self.root / command[command.index("--output-path") + 1]
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(body, encoding="utf-8")
            return SimpleNamespace(returncode=0)

        requirements = [
            self.gate.parse_module_requirement("REQ-AGENT-002=src/providers/")
        ]
        stderr = io.StringIO()
        with mock.patch.object(self.gate.shutil, "which", return_value="/tool/bin/tool"):
            with mock.patch.object(self.gate.subprocess, "run", side_effect=fake_run):
                with redirect_stderr(stderr):
                    result = self.gate.collect_product(
                        "coding-agent", self.output_dir, requirements
                    )

        self.assertEqual(result, 2)
        self.assertIn(
            "required module REQ-AGENT-002 source root has no executed lines",
            stderr.getvalue(),
        )
        report = self.gate.report_path("coding-agent", self.output_dir).read_text(encoding="utf-8")
        self.assertIn("SF:products/vityo_coding_agent/src/providers/mod.rs", report)
        self.assertNotIn(str(self.root), report)

    def test_missing_cargo_or_llvm_cov_fails_before_running_tests(self) -> None:
        with mock.patch.object(self.gate.shutil, "which", return_value=None):
            with mock.patch.object(self.gate.subprocess, "run") as run:
                stderr = io.StringIO()
                with redirect_stderr(stderr):
                    result = self.gate.collect_product("coding-agent", self.output_dir, [])

        self.assertEqual(result, 2)
        self.assertEqual(run.call_count, 0)
        self.assertIn("cargo is required", stderr.getvalue())

        with mock.patch.object(
            self.gate.shutil,
            "which",
            side_effect=("/tool/bin/cargo", None),
        ):
            with mock.patch.object(self.gate.subprocess, "run") as run:
                stderr = io.StringIO()
                with redirect_stderr(stderr):
                    result = self.gate.collect_product("coding-agent", self.output_dir, [])

        self.assertEqual(result, 2)
        self.assertEqual(run.call_count, 0)
        self.assertIn("cargo-llvm-cov is required", stderr.getvalue())

    def test_missing_locked_workspace_inputs_fail_before_running_tests(self) -> None:
        manifest = self.root / self.gate.PRODUCTS["vityod"]["manifest"]
        manifest.with_name("Cargo.lock").unlink()
        with mock.patch.object(self.gate.shutil, "which", return_value="/tool/bin/tool"):
            with mock.patch.object(self.gate.subprocess, "run") as run:
                stderr = io.StringIO()
                with redirect_stderr(stderr):
                    result = self.gate.collect_product("vityod", self.output_dir, [])

        self.assertEqual(result, 2)
        self.assertEqual(run.call_count, 0)
        self.assertIn("manifest and lock are required", stderr.getvalue())

    def test_child_test_failure_removes_a_stale_report_and_propagates_status(self) -> None:
        previous = self._write_report(
            "coding-agent",
            lcov_record(
                self._first_party_path("coding-agent", "src/lib.rs"),
                [(1, 1)],
            ),
        )
        with mock.patch.object(self.gate.shutil, "which", return_value="/tool/bin/tool"):
            with mock.patch.object(
                self.gate.subprocess,
                "run",
                return_value=SimpleNamespace(returncode=17),
            ) as run:
                result = self.gate.collect_product("coding-agent", self.output_dir, [])

        self.assertEqual(result, 17)
        run.assert_called_once()
        self.assertFalse(previous.exists())

    def test_success_without_report_fails_instead_of_reusing_old_output(self) -> None:
        with mock.patch.object(self.gate.shutil, "which", return_value="/tool/bin/tool"):
            with mock.patch.object(
                self.gate.subprocess,
                "run",
                return_value=SimpleNamespace(returncode=0),
            ):
                stderr = io.StringIO()
                with redirect_stderr(stderr):
                    result = self.gate.collect_product("coding-agent", self.output_dir, [])

        self.assertEqual(result, 2)
        self.assertIn("LCOV output is missing or unreadable", stderr.getvalue())
        self.assertNotIn(str(self.root), stderr.getvalue())
        self.assertFalse(self.gate.report_path("coding-agent", self.output_dir).exists())

    def test_report_only_checks_each_product_separately_without_running_tests(self) -> None:
        self._write_report(
            "coding-agent",
            lcov_record(
                self._first_party_path("coding-agent", "src/lib.rs"),
                [(1, 1), (2, 1), (3, 0), (4, 0)],
            ),
        )
        self._write_report(
            "vityod",
            lcov_record(
                self._first_party_path("vityod", "crates/vityod/src/main.rs"),
                [(1, 1), (2, 0), (3, 0)],
            ),
        )
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.object(self.gate.subprocess, "run", side_effect=AssertionError("must not run tests")):
            with mock.patch.object(self.gate.shutil, "which", side_effect=AssertionError("must not inspect tools")):
                with redirect_stdout(stdout):
                    with redirect_stderr(stderr):
                        result = self.gate.run_gate(
                            product="all",
                            output_dir=self.output_dir,
                            collect=False,
                            report=True,
                            fail_under=40,
                            required_modules=[],
                        )

        # The arithmetic mean exceeds 40%, but vityod is evaluated independently.
        self.assertEqual(result, 1)
        report = stdout.getvalue()
        self.assertIn("coding-agent: 50.00% lines (2/4); 2 uncovered", report)
        self.assertIn("vityod: 33.33% lines (1/3); 2 uncovered", report)
        self.assertIn("vityod is below the requested 40% floor", stderr.getvalue())

    def test_reports_fail_for_missing_malformed_zero_and_under_floor_coverage(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            missing = self.gate.evaluate_product(
                "coding-agent", self.output_dir, fail_under=None, required_modules=[]
            )
        self.assertEqual(missing, 2)

        destination = self._write_report(
            "coding-agent",
            "TN:\nSF:products/vityo_coding_agent/src/lib.rs\nDA:1,1\nLF:2\nLH:1\nend_of_record\n",
        )
        with redirect_stderr(io.StringIO()):
            malformed = self.gate.evaluate_product(
                "coding-agent", self.output_dir, fail_under=None, required_modules=[]
            )
        self.assertEqual(malformed, 2)

        destination.write_text(
            lcov_record(
                self._first_party_path("coding-agent", "src/lib.rs"),
                [(1, 0), (2, 0)],
            ),
            encoding="utf-8",
        )
        with redirect_stderr(io.StringIO()):
            zero = self.gate.evaluate_product(
                "coding-agent", self.output_dir, fail_under=None, required_modules=[]
            )
        self.assertEqual(zero, 2)

        destination.write_text(
            lcov_record(
                self._first_party_path("coding-agent", "src/lib.rs"),
                [(1, 1), (2, 0), (3, 0), (4, 0)],
            ),
            encoding="utf-8",
        )
        with redirect_stderr(io.StringIO()):
            below = self.gate.evaluate_product(
                "coding-agent", self.output_dir, fail_under=50, required_modules=[]
            )
        self.assertEqual(below, 1)

    def test_optional_threshold_has_no_implicit_percentage_floor(self) -> None:
        self._write_report(
            "vityod",
            lcov_record(
                self._first_party_path("vityod", "crates/vityod/src/main.rs"),
                [(1, 1), *[(line, 0) for line in range(2, 102)]],
            ),
        )
        with redirect_stdout(io.StringIO()):
            result = self.gate.evaluate_product(
                "vityod", self.output_dir, fail_under=None, required_modules=[]
            )
        self.assertEqual(result, 0)

    def test_absolute_host_paths_and_out_of_product_sources_are_rejected(self) -> None:
        for source in (
            "/private/user/project/src/lib.rs",
            "C:\\Users\\person\\project\\src\\lib.rs",
            "../../outside/src/lib.rs",
            "products/vityo_app/lib/src/lib.rs",
        ):
            with self.subTest(source=source):
                with self.assertRaises(ValueError):
                    self.gate.parse_lcov(lcov_record(source, [(1, 1)]), "coding-agent")

    def test_safe_workspace_relative_paths_are_normalized_to_repo_relative_labels(self) -> None:
        parsed, normalized = self.gate.parse_lcov(
            lcov_record("src\\application\\mod.rs", [(1, 1), (2, 0)]),
            "coding-agent",
        )
        self.assertEqual(parsed.sources[0].path, "products/vityo_coding_agent/src/application/mod.rs")
        self.assertIn("SF:products/vityo_coding_agent/src/application/mod.rs", normalized)
        self.assertEqual(parsed.sources[0].uncovered_lines, (2,))

    def test_required_module_ids_and_sources_are_checked_without_duplicate_registry(self) -> None:
        report, _ = self.gate.parse_lcov(
            lcov_record(
                self._first_party_path("coding-agent", "src/main.rs"),
                [(1, 1)],
            )
            + lcov_record(
                self._first_party_path("coding-agent", "src/application/mod.rs"),
                [(1, 1), (2, 0)],
            ),
            "coding-agent",
        )
        requirements = [
            self.gate.parse_module_requirement("REQ-AGENT-001=src/main.rs"),
            self.gate.parse_module_requirement("REQ-AGENT-001=src/application/"),
        ]
        results = self.gate.validate_required_modules(report, requirements)
        self.assertEqual(results, [("REQ-AGENT-001", 2, 3, 1)])

        with self.assertRaisesRegex(ValueError, "source root is absent"):
            self.gate.validate_required_modules(
                report,
                [
                    self.gate.parse_module_requirement("REQ-AGENT-003=src/main.rs"),
                    self.gate.parse_module_requirement("REQ-AGENT-003=src/multi_agent/"),
                ],
            )

        missing = [self.gate.parse_module_requirement("REQ-AGENT-002=src/providers/")]
        with self.assertRaisesRegex(ValueError, "absent"):
            self.gate.validate_required_modules(report, missing)

        invalid = (
            "REQ-AGENT-001=../secret/",
            "REQ-AGENT-001=/private/source.rs",
            "bad id=src/application/",
        )
        for value in invalid:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    self.gate.parse_module_requirement(value)

    def test_required_module_with_no_executed_lines_fails(self) -> None:
        report, _ = self.gate.parse_lcov(
            lcov_record(
                self._first_party_path("coding-agent", "src/providers/mod.rs"),
                [(1, 0), (2, 0)],
            )
            + lcov_record(
                self._first_party_path("coding-agent", "src/lib.rs"),
                [(1, 1)],
            ),
            "coding-agent",
        )
        required = [self.gate.parse_module_requirement("REQ-AGENT-002=src/providers/")]
        with self.assertRaisesRegex(ValueError, "source root has no executed lines"):
            self.gate.validate_required_modules(report, required)

    def test_output_directory_must_be_repository_relative(self) -> None:
        for raw in (Path("../outside"), self.root / "absolute"):
            with self.subTest(raw=raw):
                with self.assertRaises(ValueError):
                    self.gate.resolve_output_dir(raw)

    def test_cli_routes_phase_product_module_roots_and_optional_threshold(self) -> None:
        with mock.patch.object(self.gate, "run_gate", return_value=0) as run_gate:
            result = self.gate.main(
                [
                    "--product",
                    "coding-agent",
                    "--output-dir",
                    "build/evidence/rust-coverage",
                    "--collect-only",
                    "--fail-under",
                    "96.5",
                    "--require-module",
                    "REQ-AGENT-001=src/main.rs",
                    "--require-module",
                    "REQ-AGENT-001=src/application/",
                ]
            )

        self.assertEqual(result, 0)
        arguments = run_gate.call_args.kwargs
        self.assertEqual(arguments["product"], "coding-agent")
        self.assertEqual(
            arguments["output_dir"],
            self.root.resolve() / "build/evidence/rust-coverage",
        )
        self.assertTrue(arguments["collect"])
        self.assertFalse(arguments["report"])
        self.assertEqual(arguments["fail_under"], 96.5)
        self.assertEqual(
            [module.source.as_posix() for module in arguments["required_modules"]],
            ["src/main.rs", "src/application"],
        )

    def test_cli_requires_exactly_one_phase(self) -> None:
        for arguments in ([], ["--collect-only", "--report-only"]):
            with self.subTest(arguments=arguments):
                stderr = io.StringIO()
                with redirect_stderr(stderr):
                    with self.assertRaises(SystemExit) as raised:
                        self.gate.main(arguments)
                self.assertEqual(raised.exception.code, 2)

    def test_cli_rejects_unsafe_output_and_malformed_module_arguments(self) -> None:
        for arguments in (
            ["--collect-only", "--output-dir", "../outside"],
            ["--report-only", "--require-module", "REQ-AGENT-001=../outside/"],
        ):
            with self.subTest(arguments=arguments):
                stderr = io.StringIO()
                with redirect_stderr(stderr):
                    with self.assertRaises(SystemExit) as raised:
                        self.gate.main(arguments)
                self.assertEqual(raised.exception.code, 2)

    def test_gate_rejects_zero_floor_and_module_roots_for_vityod(self) -> None:
        for product, threshold, modules in (
            ("vityod", 0, []),
            ("vityod", None, [self.gate.parse_module_requirement("REQ=src/main.rs")]),
        ):
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                result = self.gate.run_gate(
                    product=product,
                    output_dir=self.output_dir,
                    collect=False,
                    report=True,
                    fail_under=threshold,
                    required_modules=modules,
                )
            self.assertEqual(result, 2)

    def test_missing_output_directory_permission_fails_without_path_details(self) -> None:
        blocked = self.root / "blocked"
        blocked.write_text("file", encoding="utf-8")
        stderr = io.StringIO()
        with mock.patch.object(self.gate.shutil, "which", return_value="/tool/bin/tool"):
            with redirect_stderr(stderr):
                result = self.gate.collect_product("coding-agent", blocked / "nested", [])

        self.assertEqual(result, 2)
        self.assertIn("output directory is unavailable", stderr.getvalue())
        self.assertNotIn(str(self.root), stderr.getvalue())

    def test_subprocess_start_failure_is_reported_without_exception_paths(self) -> None:
        with mock.patch.object(self.gate.shutil, "which", return_value="/tool/bin/tool"):
            with mock.patch.object(
                self.gate.subprocess,
                "run",
                side_effect=FileNotFoundError("/private/tool/cargo"),
            ):
                stderr = io.StringIO()
                with redirect_stderr(stderr):
                    result = self.gate.collect_product("coding-agent", self.output_dir, [])

        self.assertEqual(result, 2)
        self.assertIn("cargo llvm-cov could not start", stderr.getvalue())
        self.assertNotIn(str(self.root), stderr.getvalue())
        self.assertNotIn("/private/tool", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
