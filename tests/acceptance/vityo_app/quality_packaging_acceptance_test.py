"""REQ-IDE-008 package layout and installed-client startup contract."""

from __future__ import annotations

import importlib.util
import json
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
MODULE_PATH = ROOT / "packaging" / "vityo" / "desktop_delivery.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("vityo_desktop_delivery", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("desktop delivery module is unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class QualityPackagingAcceptanceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.delivery = _load_module()

    def test_repository_declares_agent_and_daemon_package_components(self) -> None:
        errors = self.delivery.validate_repository(ROOT)
        self.assertEqual(errors, [], "\n".join(errors))
        contract = self.delivery.load_delivery_contract(ROOT)
        self.assertEqual(set(contract["platforms"]), {"windows", "macos", "linux"})
        self.assertEqual(contract["product"], "vityo")
        self.assertEqual(contract["coding_agent"]["name"], "vityo-coding-agent")

        for platform in self.delivery.PLATFORMS:
            with self.subTest(platform=platform):
                manifest = json.loads(
                    (ROOT / "packaging" / platform / "nightly.json").read_text(
                        encoding="utf-8"
                    )
                )
                self.assertEqual(
                    manifest["coding_agent"]["package_relative_path"],
                    self.delivery.CODING_AGENT_PACKAGE_PATHS[platform],
                )
                self.assertEqual(
                    manifest["coding_agent"]["source_relative_path"],
                    self.delivery.CODING_AGENT_SOURCE_PATHS[platform],
                )
                self.assertEqual(
                    manifest["coding_agent"]["required_runtime_libraries"],
                    self.delivery.CODING_AGENT_RUNTIME_LIBRARIES[platform],
                )

    def test_startup_report_binds_exact_installed_candidate_and_first_frame(self) -> None:
        evidence = {
            "schema_version": 1,
            "candidate": "vityo-nightly-linux-0.1.0-nightly.1.deb",
            "platform": "linux",
            "launched": True,
            "first_frame": True,
        }
        result = self.delivery.evaluate_lane(
            platform="linux",
            host_platform="linux",
            expected_candidate=evidence["candidate"],
            evidence=evidence,
        )
        self.assertEqual(result.status, "passed")

        for change in (
            {"candidate": "different-package.deb"},
            {"platform": "windows"},
            {"first_frame": False},
            {"launched": False},
            {"workspace_opened": True},
        ):
            with self.subTest(change=change):
                mismatched = {**evidence, **change}
                result = self.delivery.evaluate_lane(
                    platform="linux",
                    host_platform="linux",
                    expected_candidate=evidence["candidate"],
                    evidence=mismatched,
                )
                self.assertEqual(result.status, "failed")

    def test_startup_report_requires_matching_host_and_closed_fields(self) -> None:
        evidence = {
            "schema_version": 1,
            "candidate": "vityo-nightly-windows-0.1.0-nightly.1.zip",
            "platform": "windows",
            "launched": True,
            "first_frame": True,
        }
        blocked = self.delivery.evaluate_lane(
            platform="windows",
            host_platform="linux",
            expected_candidate=evidence["candidate"],
            evidence=evidence,
        )
        self.assertEqual(blocked.status, "blocked")

        for extra in (
            {"capabilities": {"editor": "available"}},
            {"commit": "a" * 40},
        ):
            with self.subTest(extra=extra):
                result = self.delivery.evaluate_lane(
                    platform="windows",
                    host_platform="windows",
                    expected_candidate=evidence["candidate"],
                    evidence={**evidence, **extra},
                )
                self.assertEqual(result.status, "failed")


if __name__ == "__main__":
    unittest.main()
