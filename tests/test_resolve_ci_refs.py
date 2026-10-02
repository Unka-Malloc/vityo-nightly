from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


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


if __name__ == "__main__":
    unittest.main()
