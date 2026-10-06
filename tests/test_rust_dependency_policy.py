from __future__ import annotations

import importlib.util
import shutil
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
GATE_PATH = REPO_ROOT / "scripts" / "dependency-policy-gate.py"


def load_gate_module():
    spec = importlib.util.spec_from_file_location("dependency_policy_gate_rust", GATE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("Unable to load dependency policy gate")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


@unittest.skipUnless(shutil.which("cargo"), "Cargo is required for Cargo metadata fixtures")
class RustDependencyPolicyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.gate = load_gate_module()
        self.tempdir = tempfile.TemporaryDirectory(prefix="rust-dependency-policy-", dir=REPO_ROOT)
        self.root = Path(self.tempdir.name)
        self.agent_manifest, self.daemon_manifest = self._write_workspaces()
        (self.root / "products/vityo_app").mkdir(parents=True, exist_ok=True)
        (self.root / "products/vityo_app/pubspec.yaml").write_text(
            "dependencies:\n  crypto: ^3.0.7\n",
            encoding="utf-8",
        )
        (self.root / "prototype").mkdir()
        (self.root / "prototype/package.json").write_text("{}\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def _write_workspaces(self) -> tuple[Path, Path]:
        agent_root = self.root / "products/vityo_coding_agent"
        (agent_root / "crates/agent/src").mkdir(parents=True)
        (agent_root / "crates/agent-core/src").mkdir(parents=True)
        (agent_root / "Cargo.toml").write_text(
            "[workspace]\n"
            'members = ["crates/agent", "crates/agent-core"]\n'
            'resolver = "2"\n\n'
            "[workspace.dependencies]\n"
            'serde = "1.0"\n'
            'json-wire = { package = "serde_json", version = "1.0" }\n',
            encoding="utf-8",
        )
        (agent_root / "crates/agent/Cargo.toml").write_text(
            "[package]\nname = \"test-agent\"\nversion = \"0.1.0\"\nedition = \"2024\"\n\n"
            "[dependencies]\nserde.workspace = true\njson-wire.workspace = true\n"
            'agent-core = { path = "../agent-core" }\n\n'
            "[target.'cfg(windows)'.dependencies]\nwindows-sys = \"0.61\"\n\n"
            "[dev-dependencies]\npretty_assertions = \"1.4\"\n\n"
            "[build-dependencies]\ncc = \"1.2\"\n",
            encoding="utf-8",
        )
        (agent_root / "crates/agent/src/lib.rs").write_text("", encoding="utf-8")
        (agent_root / "crates/agent-core/Cargo.toml").write_text(
            "[package]\nname = \"agent-core\"\nversion = \"0.1.0\"\nedition = \"2024\"\n",
            encoding="utf-8",
        )
        (agent_root / "crates/agent-core/src/lib.rs").write_text("", encoding="utf-8")

        daemon_root = self.root / "products/vityo_app/native/vityod"
        (daemon_root / "src").mkdir(parents=True)
        (daemon_root / "Cargo.toml").write_text(
            "[package]\nname = \"test-daemon\"\nversion = \"0.1.0\"\nedition = \"2024\"\n\n"
            "[dependencies]\nsmallvec = \"1.13\"\n",
            encoding="utf-8",
        )
        (daemon_root / "src/main.rs").write_text("fn main() {}\n", encoding="utf-8")
        return agent_root / "Cargo.toml", daemon_root / "Cargo.toml"

    def test_workspace_metadata_covers_inherited_target_renamed_dev_and_build_deps(self) -> None:
        dependencies = self.gate.parse_cargo_workspace_dependencies(
            self.root,
            (self.agent_manifest, self.daemon_manifest),
        )

        self.assertIn("serde", dependencies)
        self.assertIn("serde_json", dependencies)
        self.assertIn("windows-sys", dependencies)
        self.assertIn("pretty_assertions", dependencies)
        self.assertIn("cc", dependencies)
        self.assertIn("smallvec", dependencies)
        self.assertNotIn("agent-core", dependencies)

        serde_json_declaration = dependencies["serde_json"][0]
        self.assertEqual(serde_json_declaration["alias"], "json-wire")
        self.assertEqual(serde_json_declaration["section"], "dependencies")
        self.assertEqual(dependencies["windows-sys"][0]["target"], "cfg(windows)")
        self.assertEqual(dependencies["pretty_assertions"][0]["section"], "dev-dependencies")
        self.assertEqual(dependencies["cc"][0]["section"], "build-dependencies")

    def test_gate_reports_unregistered_renamed_package_by_registry_name(self) -> None:
        (self.root / "DEPENDENCY-USAGE.md").write_text(
            "| Dependency | Version | License |\n|---|---|---|\n"
            "| `crypto` | ^3.0.7 | BSD-3-Clause |\n"
            "| `serde` | 1.0 | MIT OR Apache-2.0 |\n",
            encoding="utf-8",
        )

        passed, _, unregistered, details = self.gate.run_gate(
            root=self.root,
            rust_manifest_paths=(self.agent_manifest, self.daemon_manifest),
        )

        self.assertFalse(passed)
        self.assertEqual(
            unregistered,
            ["cc", "pretty_assertions", "serde_json", "smallvec", "windows-sys"],
        )
        serde_json_detail = next(item for item in details if item["package"] == "serde_json")
        self.assertEqual(serde_json_detail["declarations"][0]["alias"], "json-wire")

    def test_missing_cargo_manifest_fails_closed(self) -> None:
        with self.assertRaises(self.gate.DependencyPolicyError):
            self.gate.parse_cargo_workspace_dependencies(
                self.root,
                (self.root / "missing/Cargo.toml",),
            )


if __name__ == "__main__":
    unittest.main()
