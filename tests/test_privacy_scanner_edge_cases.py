#!/usr/bin/env python3
"""Edge-case behaviour for the privacy scanner's failure and redaction paths.

Every credential, account name, and home path below is a clearly synthetic
fixture. The assertions only ever inspect redacted output, so no test in this
module prints or compares against a real sensitive value.
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import runpy
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "vityo_privacy.py"
ENUMERATION_ERROR = "Unable to enumerate repository candidate files."


def load_privacy_module():
    spec = importlib.util.spec_from_file_location(
        "vityo_privacy_edge_cases",
        SCRIPT_PATH,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class PrivacyScannerEdgeCaseTest(unittest.TestCase):
    def setUp(self) -> None:
        self.privacy = load_privacy_module()

    def test_git_enumeration_oserror_is_loud_for_a_git_worktree(self) -> None:
        with tempfile.TemporaryDirectory(prefix="privacy-git-") as name:
            root = Path(name)
            (root / ".git").mkdir()
            with mock.patch.object(
                self.privacy.subprocess,
                "run",
                side_effect=OSError("synthetic git failure"),
            ):
                candidates, error = self.privacy._git_candidates(root)
                files, errors = self.privacy.iter_candidate_files(root)

        self.assertEqual(candidates, [])
        self.assertEqual(error, ENUMERATION_ERROR)
        self.assertEqual(files, [])
        self.assertEqual(errors, [ENUMERATION_ERROR])

    def test_git_enumeration_oserror_without_git_walks_the_filesystem(self) -> None:
        with tempfile.TemporaryDirectory(prefix="privacy-walk-") as name:
            root = Path(name)
            (root / "src").mkdir()
            (root / "src" / "kept.txt").write_text("safe\n", encoding="utf-8")
            (root / "build").mkdir()
            (root / "build" / "generated.txt").write_text("generated\n", encoding="utf-8")
            (root / "runtime.log").write_text("log\n", encoding="utf-8")
            with mock.patch.object(
                self.privacy.subprocess,
                "run",
                side_effect=OSError("synthetic git failure"),
            ):
                candidates, error = self.privacy._git_candidates(root)
                files, errors = self.privacy.iter_candidate_files(root)
                scanned = sorted(
                    path.relative_to(root.resolve()).as_posix() for path in files
                )

        self.assertIsNone(candidates)
        self.assertIsNone(error)
        self.assertEqual(errors, [])
        self.assertEqual(scanned, ["src/kept.txt"])

    def test_failed_git_probe_and_listing_report_enumeration_errors(self) -> None:
        with tempfile.TemporaryDirectory(prefix="privacy-git-status-") as name:
            root = Path(name)
            (root / ".git").mkdir()
            failed_probe = SimpleNamespace(returncode=128, stdout="", stderr="")
            with mock.patch.object(
                self.privacy.subprocess, "run", return_value=failed_probe
            ):
                self.assertEqual(
                    self.privacy._git_candidates(root),
                    ([], ENUMERATION_ERROR),
                )

            absent_root = root / "no-git-here"
            absent_root.mkdir()
            with mock.patch.object(
                self.privacy.subprocess, "run", return_value=failed_probe
            ):
                self.assertEqual(
                    self.privacy._git_candidates(absent_root),
                    (None, None),
                )

            toplevel = SimpleNamespace(returncode=0, stdout=f"{root}\n", stderr="")
            failed_listing = SimpleNamespace(returncode=1, stdout=b"", stderr=b"")
            with mock.patch.object(
                self.privacy.subprocess,
                "run",
                side_effect=[toplevel, failed_listing],
            ):
                self.assertEqual(
                    self.privacy._git_candidates(root),
                    ([], ENUMERATION_ERROR),
                )

            with mock.patch.object(
                self.privacy.subprocess,
                "run",
                side_effect=[toplevel, OSError("synthetic listing failure")],
            ):
                self.assertEqual(
                    self.privacy._git_candidates(root),
                    ([], ENUMERATION_ERROR),
                )

    def test_unavailable_root_and_enumeration_error_short_circuit_the_scan(self) -> None:
        with tempfile.TemporaryDirectory(prefix="privacy-root-") as name:
            root = Path(name)
            self.assertEqual(
                self.privacy.iter_candidate_files(root / "absent"),
                ([], ["Privacy scan root is unavailable."]),
            )
            (root / "present.txt").write_text("safe\n", encoding="utf-8")
            with mock.patch.object(
                self.privacy,
                "_git_candidates",
                return_value=([], "synthetic enumeration failure"),
            ):
                files, errors = self.privacy.iter_candidate_files(root)

        self.assertEqual(files, [])
        self.assertEqual(errors, ["synthetic enumeration failure"])

    def test_symlinked_and_escaping_candidates_are_never_scanned(self) -> None:
        with tempfile.TemporaryDirectory(prefix="privacy-outside-") as outside_name:
            with tempfile.TemporaryDirectory(prefix="privacy-inside-") as root_name:
                outside = Path(outside_name)
                root = Path(root_name)
                (outside / "outside-secret.txt").write_text(
                    "synthetic\n", encoding="utf-8"
                )
                (root / "kept.txt").write_text("safe\n", encoding="utf-8")
                (root / "directory").mkdir()
                os.symlink(outside / "outside-secret.txt", root / "link.txt")
                os.symlink(outside, root / "linkdir")
                candidates = [
                    "kept.txt",
                    "directory",
                    "link.txt",
                    "linkdir/outside-secret.txt",
                ]
                with mock.patch.object(
                    self.privacy,
                    "_git_candidates",
                    return_value=(candidates, None),
                ):
                    files, errors = self.privacy.iter_candidate_files(root)
                    scanned = [
                        path.relative_to(root.resolve()).as_posix() for path in files
                    ]

        self.assertEqual(errors, [])
        self.assertEqual(scanned, ["kept.txt"])

    def test_sk_prefixed_placeholder_is_inert_only_when_explicitly_labelled(self) -> None:
        dummy = "sk-" + "x" * 32
        labelled = self.privacy.scan_text(
            "synthetic.env",
            f"OPENAI_API_KEY={dummy}  # synthetic fixture",
        )
        self.assertEqual(len(labelled), 1)
        self.assertEqual(labelled[0].classification, "false_positive")
        self.assertEqual(labelled[0].category, "inert credential placeholder")
        self.assertEqual(labelled[0].context, "[credential redacted]")
        self.assertNotIn(dummy, json.dumps(labelled[0].to_json()))

        exposed = self.privacy.scan_text("synthetic.env", f"OPENAI_API_KEY={dummy}")
        self.assertEqual(len(exposed), 1)
        self.assertEqual(exposed[0].classification, "confirmed_exposure")
        self.assertEqual(exposed[0].category, "credential-like value")
        self.assertEqual(exposed[0].context, "[sensitive value redacted]")
        self.assertNotIn(dummy, json.dumps(exposed[0].to_json()))
        self.assertFalse(
            self.privacy.PrivacyReport(Path("."), 1, tuple(exposed)).ok,
        )

    def test_unreadable_and_undecodable_candidates_are_skipped_safely(self) -> None:
        with tempfile.TemporaryDirectory(prefix="privacy-scan-") as name:
            root = Path(name)
            (root / "plain.txt").write_text("clean\n", encoding="utf-8")
            (root / "binary.txt").write_bytes(b"\xff\xfe\xfd not utf-8")
            (root / "denied.txt").write_text("synthetic\n", encoding="utf-8")
            candidates = ["plain.txt", "binary.txt", "denied.txt"]
            original_read_bytes = Path.read_bytes

            def guarded_read_bytes(path: Path) -> bytes:
                if path.name == "denied.txt":
                    raise OSError("synthetic read failure")
                return original_read_bytes(path)

            with mock.patch.object(
                self.privacy, "_git_candidates", return_value=(candidates, None)
            ), mock.patch.object(Path, "read_bytes", new=guarded_read_bytes):
                report = self.privacy.scan_repository(root)

        self.assertEqual(report.scanned_files, 1)
        self.assertEqual(report.findings, ())
        self.assertEqual(report.errors, ("A repository candidate could not be read.",))
        self.assertFalse(report.ok)
        self.assertEqual(
            self.privacy.format_summary(report),
            "A repository candidate could not be read.",
        )

    def test_cli_writes_a_relative_report_inside_the_repository(self) -> None:
        with tempfile.TemporaryDirectory(prefix="privacy-cli-ok-") as name:
            root = Path(name).resolve()
            report = self.privacy.PrivacyReport(root, 2, ())
            stdout = io.StringIO()
            stderr = io.StringIO()
            with mock.patch.object(self.privacy, "REPO_ROOT", root), mock.patch.object(
                self.privacy, "scan_repository", return_value=report
            ), redirect_stdout(stdout), redirect_stderr(stderr):
                code = self.privacy.main(["--report", "evidence/privacy.json"])
            destination = root / "evidence" / "privacy.json"
            payload = json.loads(destination.read_text(encoding="utf-8"))

        self.assertEqual(code, 0)
        self.assertEqual(stderr.getvalue(), "")
        self.assertEqual(
            stdout.getvalue().strip(),
            "[privacy] OK: scanned 2 candidate text file(s); no findings",
        )
        self.assertEqual(
            payload,
            {"ok": True, "scanned_files": 2, "findings": [], "errors": []},
        )

    def test_cli_refuses_report_destinations_outside_the_repository(self) -> None:
        with tempfile.TemporaryDirectory(prefix="privacy-cli-escape-") as name:
            root = Path(name).resolve()
            outside = root.parent / f"{root.name}-escape.json"
            report = self.privacy.PrivacyReport(root, 1, ())
            stderr = io.StringIO()
            with mock.patch.object(self.privacy, "REPO_ROOT", root), mock.patch.object(
                self.privacy, "scan_repository", return_value=report
            ), mock.patch.object(self.privacy, "_write_report") as write, (
                redirect_stderr(stderr)
            ), redirect_stdout(io.StringIO()):
                code = self.privacy.main(["--report", str(outside)])

        self.assertEqual(code, 2)
        write.assert_not_called()
        self.assertIn(
            "report destination must stay inside the repository",
            stderr.getvalue(),
        )
        self.assertFalse(outside.exists())

    def test_cli_reports_an_unwritable_destination_without_details(self) -> None:
        with tempfile.TemporaryDirectory(prefix="privacy-cli-write-") as name:
            root = Path(name).resolve()
            blocked = root / "privacy.json"
            blocked.mkdir()
            report = self.privacy.PrivacyReport(root, 1, ())
            stderr = io.StringIO()
            with mock.patch.object(self.privacy, "REPO_ROOT", root), mock.patch.object(
                self.privacy, "scan_repository", return_value=report
            ), redirect_stderr(stderr), redirect_stdout(io.StringIO()):
                code = self.privacy.main(["--report", "privacy.json"])

        self.assertEqual(code, 2)
        self.assertIn("unable to write the redacted report", stderr.getvalue())
        self.assertNotIn(str(blocked), stderr.getvalue())

    def test_cli_fails_loudly_when_candidate_enumeration_fails(self) -> None:
        with tempfile.TemporaryDirectory(prefix="privacy-cli-errors-") as name:
            root = Path(name).resolve()
            report = self.privacy.PrivacyReport(root, 0, (), (ENUMERATION_ERROR,))
            stderr = io.StringIO()
            with mock.patch.object(self.privacy, "REPO_ROOT", root), mock.patch.object(
                self.privacy, "scan_repository", return_value=report
            ), redirect_stderr(stderr), redirect_stdout(io.StringIO()):
                code = self.privacy.main([])

        self.assertEqual(code, 1)
        self.assertIn(
            "[privacy] FAILED: candidate enumeration/read error",
            stderr.getvalue(),
        )
        self.assertIn(f"  - {ENUMERATION_ERROR}", stderr.getvalue())

    def test_module_entrypoint_fails_when_git_enumeration_fails(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()
        failed_probe = SimpleNamespace(returncode=128, stdout="", stderr="")
        with mock.patch.object(sys, "argv", ["vityo_privacy.py"]), mock.patch.object(
            self.privacy.subprocess, "run", return_value=failed_probe
        ), redirect_stdout(stdout), redirect_stderr(stderr):
            with self.assertRaises(SystemExit) as exit_error:
                runpy.run_path(str(SCRIPT_PATH), run_name="__main__")

        self.assertEqual(exit_error.exception.code, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn(
            "[privacy] FAILED: candidate enumeration/read error",
            stderr.getvalue(),
        )


if __name__ == "__main__":
    unittest.main()
