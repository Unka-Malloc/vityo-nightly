from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
POLICY_PATH = REPO_ROOT / "scripts" / "check_license_policy.py"


def load_policy_module():
    spec = importlib.util.spec_from_file_location("check_rust_license_policy_test", POLICY_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("Unable to load Rust license policy gate")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class RustLicensePolicyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.policy = load_policy_module()
        self.configuration = tomllib.loads(
            (REPO_ROOT / self.policy.RUST_LICENSE_CONFIG_PATH).read_text(encoding="utf-8")
        )

    def test_config_matches_native_target_matrix_from_package_manifests(self) -> None:
        self.assertEqual(self.policy._check_rust_target_scope(REPO_ROOT, self.configuration), [])

    def test_missing_or_extra_targets_fail_closed(self) -> None:
        for targets in (
            [item for item in self.configuration["targets"] if item != "aarch64-apple-darwin"],
            [*self.configuration["targets"], "wasm32-unknown-unknown"],
        ):
            with self.subTest(targets=targets):
                configuration = {**self.configuration, "targets": targets}
                self.assertEqual(
                    self.policy._check_rust_target_scope(REPO_ROOT, configuration),
                    ["cargo-about desktop targets differ from the packaged Rust target matrix"],
                )

    def test_missing_or_unmapped_manifest_target_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rust-license-targets-") as temporary:
            root = Path(temporary)
            for platform, relative_path in self.policy.RUST_PACKAGE_TARGET_MANIFESTS:
                payload = {
                    "platform": platform,
                    "vityod": {"target": "x86_64-unknown-linux-gnu"},
                    "coding_agent": {"target": "x86_64-unknown-linux-gnu"},
                }
                if platform == "windows":
                    payload["vityod"]["target"] = "mystery-windows-target"
                path = root / relative_path
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(payload), encoding="utf-8")

            errors = self.policy._check_rust_target_scope(root, self.configuration)

        self.assertEqual(
            errors,
            ["Rust package target is missing or unmapped: packaging/windows/nightly.json"],
        )

    def test_license_gate_requires_build_dev_and_transitive_checks(self) -> None:
        configuration = {**self.configuration, "ignore-dev-dependencies": True}
        with tempfile.TemporaryDirectory(prefix="rust-license-policy-") as temporary:
            root = Path(temporary)
            (root / self.policy.SECURITY_POLICY_PATH).parent.mkdir(parents=True)
            (root / self.policy.SECURITY_POLICY_PATH).write_text(
                "- Permissible licenses: " + ", ".join(configuration["accepted"]) + "\n",
                encoding="utf-8",
            )
            config_path = root / self.policy.RUST_LICENSE_CONFIG_PATH
            config_path.parent.mkdir(parents=True, exist_ok=True)
            config_path.write_text(
                "accepted = [" + ", ".join(json.dumps(item) for item in configuration["accepted"]) + "]\n"
                + "targets = [" + ", ".join(json.dumps(item) for item in configuration["targets"]) + "]\n"
                + "ignore-build-dependencies = false\n"
                + "ignore-dev-dependencies = true\n"
                + "ignore-transitive-dependencies = false\n"
                + "private = { ignore = true }\n",
                encoding="utf-8",
            )
            for platform, relative_path in self.policy.RUST_PACKAGE_TARGET_MANIFESTS:
                target = {
                    "linux": "x86_64-unknown-linux-gnu",
                    "windows": "x86_64-pc-windows-msvc",
                    "macos": "native-apple-darwin",
                }[platform]
                package = {"platform": platform, "vityod": {"target": target}, "coding_agent": {"target": target}}
                path = root / relative_path
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(package), encoding="utf-8")

            errors = self.policy._check_rust_license_allowlist(root)

        self.assertEqual(errors, ["cargo-about must include build, development, and transitive dependencies"])


if __name__ == "__main__":
    unittest.main()
