from __future__ import annotations

import contextlib
import io
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = REPO_ROOT / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import vityo_privacy


class VityoPrivacyTest(unittest.TestCase):
    def _write(self, root: Path, relative: str, text: str) -> Path:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def _git(self, root: Path, *args: str) -> None:
        subprocess.run(
            ["git", *args],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )

    def test_scan_text_redacts_credentials_and_local_paths(self) -> None:
        token = "_".join(("ghp", "A" * 36))
        account = "profiletoken42"
        home_path = "/" + "home" + "/" + account + "/project"
        findings = vityo_privacy.scan_text(
            "settings.env",
            f"TOKEN={token}\nROOT={home_path}\n",
        )

        self.assertEqual(len(findings), 2)
        self.assertEqual(
            [finding.classification for finding in findings],
            ["confirmed_exposure", "confirmed_exposure"],
        )
        report_text = json.dumps([finding.to_json() for finding in findings])
        summary = vityo_privacy.format_summary(
            vityo_privacy.PrivacyReport(Path("."), 1, tuple(findings))
        )
        for sensitive_value in (token, account, home_path):
            self.assertNotIn(sensitive_value, report_text)
            self.assertNotIn(sensitive_value, summary)
        self.assertIn("settings.env:1", summary)
        self.assertIn("settings.env:2", summary)

    def test_only_exact_semantic_fixtures_are_exempt(self) -> None:
        generic_account = "example"
        generic_path = "/" + "home" + "/" + generic_account + "/project"
        generic = vityo_privacy.scan_text("example.py", "ROOT=" + generic_path)
        self.assertEqual(generic[0].classification, "false_positive")
        self.assertTrue(vityo_privacy.PrivacyReport(Path("."), 1, tuple(generic)).ok)
        windows_fixture = (
            "C:" + "\\" + "Users" + "\\" + "fixture" + "\\" + "project"
        )
        windows = vityo_privacy.scan_text("example.py", "ROOT=" + windows_fixture)
        self.assertEqual(windows[0].classification, "false_positive")

        fixture_line = (
            "Pattern-based redaction for: POSIX home paths "
            + "/"
            + "home"
            + "/sample/project"
        )
        fixture = vityo_privacy.scan_text(
            "docs/governance/SECURITY-AND-SUPPLY-CHAIN.md",
            fixture_line,
        )
        self.assertEqual(len(fixture), 1)
        self.assertEqual(fixture[0].classification, "false_positive")
        self.assertIn("specification documents", fixture[0].judgement_basis)

        same_content_elsewhere = vityo_privacy.scan_text(
            "src/unrelated.py",
            fixture_line,
        )
        self.assertEqual(
            same_content_elsewhere[0].classification,
            "confirmed_exposure",
        )
        self.assertFalse(
            vityo_privacy.PrivacyReport(
                Path("."),
                1,
                tuple(same_content_elsewhere),
            ).ok
        )

    def test_repository_fixture_exceptions_are_file_and_semantic_scoped(self) -> None:
        fixture_paths = {
            "docs/governance/SECURITY-AND-SUPPLY-CHAIN.md",
            "products/vityo_app/test/extension_marketplace_test.dart",
            "products/vityo_app/test/file_system_manager_test.dart",
            "products/vityo_app/test/foundation_test.dart",
            "products/vityo_app/test/platform_context_test.dart",
            "products/vityo_app/test/secret_redaction_test.dart",
            "products/vityo_app/test/system_compatibility_managers_test.dart",
            "products/vityo_app/test/workspace_file_index_test.dart",
        }
        for relative_path in sorted(fixture_paths):
            with self.subTest(path=relative_path):
                source = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
                findings = vityo_privacy.scan_text(relative_path, source)
                self.assertTrue(findings)
                self.assertTrue(
                    all(finding.classification == "false_positive" for finding in findings),
                    [f"{finding.path}:{finding.line}:{finding.rule}" for finding in findings],
                )

    def test_inert_api_placeholder_requires_explicit_marker(self) -> None:
        setting_name = "OPENAI" + "_API_KEY"
        dummy = "x" * 30
        line = setting_name + "='" + dummy + "' # example"
        finding = vityo_privacy.scan_text("fixture.py", line)[0]
        self.assertEqual(finding.classification, "false_positive")
        self.assertEqual(finding.category, "inert credential placeholder")

        unlabelled = vityo_privacy.scan_text(
            "fixture.py",
            setting_name + "='" + dummy + "'",
        )[0]
        self.assertEqual(unlabelled.classification, "confirmed_exposure")

    def test_candidate_inventory_scans_tracked_and_unignored_files_only(self) -> None:
        with tempfile.TemporaryDirectory(prefix="privacy-candidates-") as temp_name:
            root = Path(temp_name)
            self._git(root, "init", "-q")
            self._write(root, ".gitignore", ".env*\n")
            self._write(root, "tracked.txt", "safe\n")
            self._write(root, "unignored.txt", "safe\n")
            self._write(root, ".env", "tracked despite ignore\n")
            self._write(root, ".env.local", "ignored and untracked\n")
            self._write(root, "build/output.txt", "generated\n")
            self._write(root, "products/vityo_app/test/failures/old.txt", "preserved\n")
            self._write(root, "runtime.log", "runtime\n")
            (root / "binary.bin").write_bytes(b"ignored\x00payload")
            self._git(root, "add", ".gitignore", "tracked.txt")
            self._git(root, "add", "--force", ".env")

            candidates, errors = vityo_privacy.iter_candidate_files(root)
            candidate_names = {
                path.relative_to(root.resolve()).as_posix() for path in candidates
            }
            report = vityo_privacy.scan_repository(root)

        self.assertEqual(errors, [])
        self.assertIn("tracked.txt", candidate_names)
        self.assertIn("unignored.txt", candidate_names)
        self.assertIn(".env", candidate_names)
        self.assertNotIn(".env.local", candidate_names)
        self.assertNotIn("build/output.txt", candidate_names)
        self.assertNotIn("runtime.log", candidate_names)
        self.assertIn("binary.bin", candidate_names)
        self.assertNotIn("products/vityo_app/test/failures/old.txt", candidate_names)
        self.assertEqual(report.scanned_files, 4)
        self.assertEqual(report.findings, ())

    def test_product_gate_does_not_print_matched_credentials(self) -> None:
        token = "_".join(("ghp", "C" * 36))
        with tempfile.TemporaryDirectory(prefix="privacy-product-gate-") as temp_name:
            root = Path(temp_name).resolve()
            self._git(root, "init", "-q")
            self._write(root, "config.txt", "TOKEN=" + token + "\n")
            spec = importlib.util.spec_from_file_location(
                "vityo_product_gate_privacy_test",
                REPO_ROOT / "scripts" / "vityo-product-gate.py",
            )
            self.assertIsNotNone(spec)
            self.assertIsNotNone(spec.loader if spec is not None else None)
            assert spec is not None and spec.loader is not None
            module = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = module
            spec.loader.exec_module(module)
            output = io.StringIO()
            with patch.object(module, "REPO_ROOT", root), contextlib.redirect_stderr(output):
                passed = module.check_no_secrets_in_tracked()

        self.assertFalse(passed)
        self.assertIn("config.txt:1", output.getvalue())
        self.assertNotIn(token, output.getvalue())

    def test_cli_report_is_safe_and_fails_on_a_real_candidate(self) -> None:
        token = "_".join(("ghp", "B" * 36))
        account = "privateprofile42"
        home_path = "/" + "Users" + "/" + account + "/workspace"
        with tempfile.TemporaryDirectory(prefix="privacy-cli-") as temp_name:
            root = Path(temp_name)
            self._git(root, "init", "-q")
            self._write(root, "config.txt", f"TOKEN={token}\nROOT={home_path}\n")
            report_path = root / "evidence" / "privacy.json"
            stdout = io.StringIO()
            stderr = io.StringIO()
            with patch.object(vityo_privacy, "REPO_ROOT", root.resolve()):
                with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    code = vityo_privacy.main(["--report", str(report_path)])
            report_text = report_path.read_text(encoding="utf-8")
            output_text = stdout.getvalue() + stderr.getvalue()

        self.assertEqual(code, 1)
        self.assertIn("config.txt:1", output_text)
        self.assertIn("config.txt:2", output_text)
        self.assertNotIn(token, report_text)
        self.assertNotIn(account, report_text)
        self.assertNotIn(home_path, report_text)
        self.assertNotIn(token, output_text)
        self.assertNotIn(account, output_text)
        self.assertNotIn(home_path, output_text)


if __name__ == "__main__":
    unittest.main()
