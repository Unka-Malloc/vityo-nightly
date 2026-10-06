from __future__ import annotations

import importlib.util
import io
import json
import runpy
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = ROOT / "scripts" / "resolve-ci-refs.py"
spec = importlib.util.spec_from_file_location("resolve_ci_refs", SCRIPT_PATH)
if spec is None or spec.loader is None:
    raise RuntimeError("unable to load CI ref resolver")
resolver = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = resolver
spec.loader.exec_module(resolver)


class ResolveCIRefsTest(unittest.TestCase):
    def test_pull_request_uses_the_declared_base_and_head(self) -> None:
        refs = resolver.resolve_ci_refs(
            "pull_request",
            {
                "pull_request": {
                    "base": {"ref": "nightly", "sha": "a" * 40},
                    "head": {"sha": "b" * 40},
                }
            },
            head_sha="c" * 40,
            parent_ref="HEAD^",
        )
        self.assertEqual(refs.base_ref, "origin/nightly")
        self.assertEqual(refs.revision_range, f"{'a' * 40}..{'b' * 40}")
        self.assertEqual(
            refs.fetch_refspec,
            "+refs/heads/nightly:refs/remotes/origin/nightly",
        )

    def test_push_uses_a_real_before_revision(self) -> None:
        before = "a" * 40
        head = "b" * 40
        refs = resolver.resolve_ci_refs(
            "push",
            {"before": before},
            head_sha=head,
            parent_ref="HEAD^",
        )
        self.assertEqual(refs.base_ref, before)
        self.assertEqual(refs.revision_range, f"{before}..{head}")

    def test_first_push_uses_the_available_parent(self) -> None:
        head = "b" * 40
        refs = resolver.resolve_ci_refs(
            "push",
            {"before": resolver.ZERO_SHA},
            head_sha=head,
            parent_ref="HEAD^",
        )
        self.assertEqual(refs.base_ref, "HEAD^")
        self.assertEqual(refs.revision_range, f"HEAD^..{head}")

    def test_schedule_dispatch_and_merge_group_use_parent_without_before(self) -> None:
        head = "b" * 40
        for event_name in ("schedule", "workflow_dispatch", "merge_group"):
            with self.subTest(event=event_name):
                refs = resolver.resolve_ci_refs(
                    event_name,
                    {},
                    head_sha=head,
                    parent_ref="HEAD^",
                )
                self.assertEqual(refs.base_ref, "HEAD^")
                self.assertEqual(refs.revision_range, f"HEAD^..{head}")

    def test_root_commit_has_a_valid_empty_range(self) -> None:
        head = "b" * 40
        for event_name, event in (
            ("push", {"before": resolver.ZERO_SHA}),
            ("schedule", {}),
            ("workflow_dispatch", {}),
            ("merge_group", {}),
        ):
            with self.subTest(event=event_name):
                refs = resolver.resolve_ci_refs(
                    event_name,
                    event,
                    head_sha=head,
                    parent_ref=None,
                )
                self.assertEqual(refs.base_ref, "HEAD")
                self.assertEqual(refs.revision_range, f"HEAD..{head}")

    def test_unknown_event_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "unsupported GitHub event"):
            resolver.resolve_ci_refs(
                "deployment",
                {},
                head_sha="b" * 40,
                parent_ref="HEAD^",
            )

    def test_pull_request_requires_complete_revision_metadata(self) -> None:
        for payload in ({}, {"pull_request": {}}, {"pull_request": {"base": {}, "head": {}}}):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                resolver.resolve_ci_refs(
                    "pull_request", payload, head_sha="b" * 40, parent_ref="HEAD^"
                )

    def _invoke(self, event, *, event_name="schedule", parent_exists=True, fetch_code=0):
        with tempfile.TemporaryDirectory() as directory:
            event_path = Path(directory) / "event.json"
            output = Path(directory) / "output"
            event_path.write_text(json.dumps(event), encoding="utf-8")
            environment = {
                "GITHUB_EVENT_NAME": event_name,
                "GITHUB_SHA": "c" * 40,
                "GITHUB_EVENT_PATH": str(event_path),
                "GITHUB_OUTPUT": str(output),
            }
            stderr = io.StringIO()
            with mock.patch.dict(resolver.os.environ, environment, clear=True), mock.patch.object(
                resolver.subprocess, "run",
                side_effect=[
                    SimpleNamespace(returncode=0 if parent_exists else 1),
                    SimpleNamespace(returncode=fetch_code),
                ],
            ) as run, redirect_stderr(stderr):
                code = resolver.main()
            return code, output.read_text() if output.exists() else "", stderr.getvalue(), run.call_args_list

    def test_main_writes_event_outputs_and_fetches_only_the_pr_base(self) -> None:
        code, output, error, calls = self._invoke({})
        self.assertEqual((code, error), (0, ""))
        self.assertEqual(output, f"base_ref=HEAD^\nrange=HEAD^..{'c' * 40}\n")
        self.assertEqual(len(calls), 1)

        code, output, _, calls = self._invoke({}, parent_exists=False)
        self.assertEqual(code, 0)
        self.assertIn("base_ref=HEAD\n", output)

        payload = {"pull_request": {"base": {"ref": "nightly", "sha": "a" * 40}, "head": {"sha": "b" * 40}}}
        code, output, error, calls = self._invoke(payload, event_name="pull_request")
        self.assertEqual((code, error), (0, ""))
        self.assertIn(f"range={'a' * 40}..{'b' * 40}\n", output)
        self.assertEqual(calls[1].args[0], ["git", "fetch", "--no-tags", "origin", "+refs/heads/nightly:refs/remotes/origin/nightly"])

        code, output, error, _ = self._invoke(payload, event_name="pull_request", fetch_code=1)
        self.assertEqual((code, output), (2, ""))
        self.assertIn("base ref could not be fetched", error)

    def test_main_rejects_invalid_or_missing_metadata_without_publishing_outputs(self) -> None:
        code, output, error, _ = self._invoke([])
        self.assertEqual((code, output), (2, ""))
        self.assertIn("payload is invalid", error)
        with mock.patch.dict(resolver.os.environ, {}, clear=True), redirect_stderr(io.StringIO()):
            self.assertEqual(resolver.main(), 2)
            with self.assertRaises(SystemExit) as raised:
                runpy.run_path(str(SCRIPT_PATH), run_name="__main__")
            self.assertEqual(raised.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
