#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "vityo.py"


def load_delivery_module():
    spec = importlib.util.spec_from_file_location("vityo_delivery_policy", SCRIPT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class DeliveryGateProductPolicyTest(unittest.TestCase):
    def test_ci_test_stage_requires_real_pinned_product_tools(self) -> None:
        delivery = load_delivery_module()
        options = delivery.DeliveryOptions(
            mode="ci",
            platform="linux",
            base="nightly",
            revision_range="base..head",
        )
        with mock.patch.object(delivery, "resolve_pinned_cli", side_effect=ValueError("unavailable")), mock.patch.object(
            delivery.shutil, "which", return_value="/tools/flutter"
        ):
            self.assertEqual(delivery.run_test_stage(options), 2)

    def test_platform_workflows_use_the_unified_delivery_command(self) -> None:
        workflow = (REPO_ROOT / ".github/workflows/local-ci-gate.yml").read_text(
            encoding="utf-8"
        )
        self.assertEqual(
            workflow.count("scripts/vityo.py deliver --mode ci --platform"),
            3,
        )
        self.assertNotIn("--vityo-delivery-smoke", workflow)
        for platform in ("linux", "windows", "macos"):
            with self.subTest(platform=platform):
                self.assertIn(f"--platform {platform}", workflow)
                self.assertIn(f"startup-{platform}.json", workflow)

if __name__ == "__main__":
    unittest.main()
