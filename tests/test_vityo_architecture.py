#!/usr/bin/env python3
from __future__ import annotations

import copy
import importlib.util
import io
import json
import sys
import tempfile
import threading
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from urllib.error import HTTPError
from urllib.request import urlopen
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
GENERATOR_PATH = REPO_ROOT / "scripts" / "vityo_architecture.py"


def load_generator():
    spec = importlib.util.spec_from_file_location("vityo_architecture", GENERATOR_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {GENERATOR_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def minimal_model(boundaries: list[dict[str, object]] | None = None) -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "title": "Fixture architecture",
        "subtitle": "Source-backed fixture",
        "lanes": [{"id": "client", "title": "Client", "description": "Client owner."}],
        "nodes": [
            {
                "id": "editor",
                "lane": "client",
                "label": "Editor",
                "status": "current",
                "summary": "Owns source.",
                "detail": "The source remains authoritative.",
                "sources": ["editor_source"],
            },
            {
                "id": "agent",
                "lane": "client",
                "label": "Agent",
                "status": "target",
                "summary": "Uses a bounded operation.",
                "detail": "The operation stays authorized.",
                "sources": ["editor_source"],
            },
        ],
        "edges": [
            {
                "id": "editor_to_agent",
                "from": "editor",
                "to": "agent",
                "label": "typed operation",
                "status": "target",
            }
        ],
        "sourceAnchors": [
            {"id": "editor_source", "path": "lib/editor.dart", "contains": ["class Editor"]}
        ],
        "dependencyBoundaries": boundaries or [],
    }


def write_fixture(root: Path, model: dict[str, object]) -> None:
    write(root / "lib/editor.dart", "class Editor {}\n")
    write(root / "README.md", "Private fixture file must not be served.\n")
    write(
        root / "docs/design/Vityo-System-Architecture.md",
        "# Architecture\n\n<!-- VITYO_ARCHITECTURE:START -->\nold\n"
        "<!-- VITYO_ARCHITECTURE:END -->\n",
    )
    write(
        root / "docs/design/architecture-views/system-architecture.json",
        json.dumps(model, indent=2) + "\n",
    )


class VityoArchitectureGeneratorTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.generator = load_generator()

    def test_generation_uses_one_model_and_detects_output_drift(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vityo-architecture-") as temp:
            root = Path(temp)
            model = minimal_model()
            write_fixture(root, model)

            loaded = self.generator.load_model(root)
            self.generator.write_outputs(root, loaded)
            self.generator.check_outputs(root, loaded)

            changed = copy.deepcopy(loaded)
            changed["nodes"][0]["label"] = "Updated editor"
            with self.assertRaisesRegex(self.generator.ArchitectureError, "generated architecture output is stale"):
                self.generator.check_outputs(root, changed)

            self.generator.write_outputs(root, changed)
            self.generator.check_outputs(root, changed)
            self.assertIn("Updated editor", (root / "docs/design/architecture-views/system-architecture.html").read_text())
            self.assertIn("Updated editor", (root / "docs/design/Vityo-System-Architecture.md").read_text())

    def test_model_rejects_duplicate_ids_unknown_edges_and_missing_source_anchors(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vityo-architecture-") as temp:
            root = Path(temp)
            write_fixture(root, minimal_model())

            duplicate = minimal_model()
            duplicate["nodes"].append(copy.deepcopy(duplicate["nodes"][0]))
            with self.assertRaisesRegex(self.generator.ArchitectureError, "duplicate node id"):
                self.generator.validate_model(root, duplicate)

            unknown_edge = minimal_model()
            unknown_edge["edges"][0]["to"] = "missing"
            with self.assertRaisesRegex(self.generator.ArchitectureError, "unknown node"):
                self.generator.validate_model(root, unknown_edge)

            missing_anchor = minimal_model()
            missing_anchor["sourceAnchors"][0]["contains"] = ["class RemovedEditor"]
            with self.assertRaisesRegex(self.generator.ArchitectureError, "source anchor changed"):
                self.generator.validate_model(root, missing_anchor)

    def test_loader_and_validator_reject_malformed_models_and_unsafe_paths(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vityo-architecture-") as temp:
            root = Path(temp)
            write_fixture(root, minimal_model())
            model_path = root / "docs/design/architecture-views/system-architecture.json"

            for content, message in (
                ("{invalid", "cannot read architecture model"),
                ("[]", "root must be an object"),
            ):
                with self.subTest(content=content):
                    write(model_path, content)
                    with self.assertRaisesRegex(self.generator.ArchitectureError, message):
                        self.generator.load_model(root)

            write_fixture(root, minimal_model())
            model_cases = (
                (lambda value: value.update(schemaVersion=2), "unsupported architecture model schemaVersion"),
                (lambda value: value.update(title="  "), "title must be a non-empty string"),
                (lambda value: value.update(lanes=None), "must be arrays"),
                (lambda value: value["lanes"][0].update(description=""), "description must be a non-empty string"),
                (lambda value: value["nodes"][0].update(lane="missing"), "unknown lane"),
                (lambda value: value["nodes"][0].update(status="unknown"), "unsupported status"),
                (lambda value: value["nodes"][0].update(summary=""), "summary must be a non-empty string"),
                (lambda value: value["nodes"][0].update(sources=["missing"]), "unknown source anchor"),
                (lambda value: value["edges"][0].update(status="unknown"), "unsupported status"),
                (lambda value: value["edges"][0].update(label=""), "label must be a non-empty string"),
                (lambda value: value["sourceAnchors"][0].update(path="../outside.dart"), "unsafe repository path"),
                (lambda value: value["sourceAnchors"][0].update(path="missing.dart"), "source anchor file is missing"),
                (lambda value: value["sourceAnchors"][0].update(contains=[]), "must name at least one source token"),
                (lambda value: value["sourceAnchors"][0].update(contains=[""]), "token must be a non-empty string"),
            )
            for mutate, message in model_cases:
                with self.subTest(message=message):
                    model = minimal_model()
                    mutate(model)
                    with self.assertRaisesRegex(self.generator.ArchitectureError, message):
                        self.generator.validate_model(root, model)

            outside = root.parent / f"{root.name}-outside.dart"
            outside.write_text("class Editor {}\n", encoding="utf-8")
            try:
                (root / "outside-link.dart").symlink_to(outside)
                symlinked = minimal_model()
                symlinked["sourceAnchors"][0]["path"] = "outside-link.dart"
                with self.assertRaisesRegex(self.generator.ArchitectureError, "escapes checkout"):
                    self.generator.validate_model(root, symlinked)
            finally:
                outside.unlink(missing_ok=True)

            original_read_text = Path.read_text

            def read_text(path: Path, *args: object, **kwargs: object) -> str:
                if path.name == "editor.dart":
                    raise UnicodeDecodeError("utf-8", b"\xff", 0, 1, "invalid")
                return original_read_text(path, *args, **kwargs)

            with mock.patch.object(Path, "read_text", autospec=True, side_effect=read_text):
                with self.assertRaisesRegex(self.generator.ArchitectureError, "cannot read source anchor"):
                    self.generator.validate_model(root, minimal_model())

    def test_dependency_boundary_failures_cover_missing_and_aliased_inputs(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vityo-architecture-") as temp:
            root = Path(temp)

            missing_dart_root = {
                "id": "dart_missing",
                "kind": "dart-imports",
                "roots": ["missing"],
                "forbiddenPackages": [],
                "forbiddenRelativeRoots": [],
            }
            write_fixture(root, minimal_model([missing_dart_root]))
            with self.assertRaisesRegex(self.generator.ArchitectureError, "root is missing"):
                self.generator.load_model(root)

            relative_boundary = {
                "id": "dart_relative",
                "kind": "dart-imports",
                "roots": ["lib"],
                "forbiddenPackages": [],
                "forbiddenRelativeRoots": ["private"],
            }
            write_fixture(root, minimal_model([relative_boundary]))
            write(root / "private/runtime.dart", "class PrivateRuntime {}\n")
            write(root / "lib/editor.dart", "import '../private/runtime.dart';\nclass Editor {}\n")
            with self.assertRaisesRegex(self.generator.ArchitectureError, "relative import"):
                self.generator.load_model(root)

            pub_boundary = {
                "id": "pub_alias",
                "kind": "pub-dependencies",
                "manifests": ["pubspec.yaml"],
                "forbiddenPackages": ["forbidden_runtime"],
            }
            write_fixture(root, minimal_model([pub_boundary]))
            with self.assertRaisesRegex(self.generator.ArchitectureError, "manifest is missing"):
                self.generator.load_model(root)
            write(root / "pubspec.yaml", "dependencies:\n  local_alias:\n    package: forbidden_runtime\n")
            with self.assertRaisesRegex(self.generator.ArchitectureError, "forbidden_runtime"):
                self.generator.load_model(root)

            cargo_boundary = {
                "id": "cargo_alias",
                "kind": "cargo-dependencies",
                "manifests": ["Cargo.toml"],
                "forbiddenPackages": ["forbidden_runtime"],
            }
            write_fixture(root, minimal_model([cargo_boundary]))
            with self.assertRaisesRegex(self.generator.ArchitectureError, "Cargo manifest is missing"):
                self.generator.load_model(root)
            write(root / "Cargo.toml", "[dependencies\ninvalid = true\n")
            with self.assertRaisesRegex(self.generator.ArchitectureError, "cannot parse Cargo manifest"):
                self.generator.load_model(root)
            write(
                root / "Cargo.toml",
                '[dependencies]\nrenamed = { package = "forbidden-runtime", version = "1" }\n',
            )
            with self.assertRaisesRegex(self.generator.ArchitectureError, "forbidden_runtime"):
                self.generator.load_model(root)

    def test_markdown_and_generated_output_failures_are_reported(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vityo-architecture-") as temp:
            root = Path(temp)
            model = minimal_model()
            write_fixture(root, model)
            markdown = root / "docs/design/Vityo-System-Architecture.md"

            markdown.unlink()
            with self.assertRaisesRegex(self.generator.ArchitectureError, "Markdown is missing"):
                self.generator.generated_outputs(root, model)

            write(markdown, "# missing markers\n")
            with self.assertRaisesRegex(self.generator.ArchitectureError, "one generated diagram marker pair"):
                self.generator.generated_outputs(root, model)

            write(markdown, "<!-- VITYO_ARCHITECTURE:END -->\n<!-- VITYO_ARCHITECTURE:START -->\n")
            with self.assertRaisesRegex(self.generator.ArchitectureError, "markers are reversed"):
                self.generator.generated_outputs(root, model)

            write_fixture(root, model)
            self.generator.write_outputs(root, model)
            html_output = root / "docs/design/architecture-views/system-architecture.html"
            html_output.unlink()
            with self.assertRaisesRegex(self.generator.ArchitectureError, "generated architecture output is missing"):
                self.generator.check_outputs(root, model)

            self.generator.write_outputs(root, model)
            html_output.write_text("stale output", encoding="utf-8")
            with self.assertRaisesRegex(self.generator.ArchitectureError, "generated architecture output is stale"):
                self.generator.check_outputs(root, model)

    def test_cli_handles_success_bad_arguments_and_sanitized_failures(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vityo-architecture-") as temp:
            root = Path(temp)
            write_fixture(root, minimal_model())
            output = io.StringIO()
            with mock.patch.object(self.generator, "REPOSITORY_ROOT", root):
                with redirect_stdout(output):
                    self.assertEqual(self.generator.main(["--write"]), 0)
                    self.assertIn("architecture outputs updated", output.getvalue())

                    output.seek(0)
                    output.truncate(0)
                    self.assertEqual(self.generator.main(["--write"]), 0)
                    self.assertIn("already current", output.getvalue())

                    output.seek(0)
                    output.truncate(0)
                    self.assertEqual(self.generator.main(["--check"]), 0)
                    self.assertIn("outputs are current", output.getvalue())

                    output.seek(0)
                    output.truncate(0)
                    self.assertEqual(self.generator.main(["--fragment"]), 0)
                    self.assertIn("vityo-system-architecture", output.getvalue())

                for arguments in (
                    [],
                    ["--check", "--write"],
                    ["--watch", "--check"],
                    ["--serve", "--port", "65536"],
                ):
                    with self.subTest(arguments=arguments), redirect_stderr(io.StringIO()):
                        with self.assertRaises(SystemExit) as error:
                            self.generator.main(arguments)
                        self.assertEqual(error.exception.code, 2)

                error_output = io.StringIO()
                with redirect_stderr(error_output):
                    with mock.patch.object(
                        self.generator,
                        "load_model",
                        side_effect=self.generator.ArchitectureError("invalid fixture model"),
                    ):
                        self.assertEqual(self.generator.main(["--check"]), 1)
                self.assertIn("architecture check failed: invalid fixture model", error_output.getvalue())

                error_output = io.StringIO()
                with redirect_stderr(error_output):
                    with mock.patch.object(self.generator, "load_model", return_value=minimal_model()):
                        with mock.patch.object(
                            self.generator,
                            "check_outputs",
                            side_effect=OSError("synthetic private path"),
                        ):
                            self.assertEqual(self.generator.main(["--check"]), 1)
                self.assertIn("architecture command failed: OSError", error_output.getvalue())
                self.assertNotIn("synthetic private path", error_output.getvalue())

    def test_cli_serve_cleans_up_after_shutdown_and_http_rejects_invalid_model(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vityo-architecture-") as temp:
            root = Path(temp)
            write_fixture(root, minimal_model())

            class FakeServer:
                server_port = 43210

                def serve_forever(self) -> None:
                    raise KeyboardInterrupt

                def server_close(self) -> None:
                    self.closed = True

            fake_server = FakeServer()
            fake_server.closed = False
            output = io.StringIO()
            with mock.patch.object(self.generator, "load_model", return_value=minimal_model()):
                with mock.patch.object(self.generator, "write_outputs"):
                    with mock.patch.object(self.generator, "ThreadingHTTPServer", return_value=fake_server):
                        with redirect_stdout(output):
                            self.generator.serve(root, 0, watch=True)
            self.assertTrue(fake_server.closed)
            self.assertIn("http://127.0.0.1:43210/", output.getvalue())
            self.assertIn("Watch mode is enabled", output.getvalue())

            write_fixture(root, minimal_model())
            server = self.generator.ThreadingHTTPServer(
                ("127.0.0.1", 0), self.generator._handler(root, watch=False)
            )
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = f"http://127.0.0.1:{server.server_port}"
            try:
                write(
                    root / "docs/design/architecture-views/system-architecture.json",
                    "{invalid model",
                )
                with self.assertRaises(HTTPError) as error:
                    urlopen(f"{base}/", timeout=3)
                self.assertEqual(error.exception.code, 503)
                self.assertEqual(error.exception.read().decode(), "architecture model is invalid\n")
                error.exception.close()
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=3)

    def test_dependency_boundaries_reject_runtime_import_and_manifest_edges(self) -> None:
        cases = (
            (
                {
                    "id": "dart_boundary",
                    "kind": "dart-imports",
                    "roots": ["products/vityo_app/lib"],
                    "forbiddenPackages": ["vityo_coding_agent"],
                    "forbiddenRelativeRoots": ["products/vityo_coding_agent"],
                },
                "products/vityo_app/lib/main.dart",
                "import 'package:vityo_coding_agent/runtime.dart';\n",
                "violated by products/vityo_app/lib/main.dart",
            ),
            (
                {
                    "id": "pub_boundary",
                    "kind": "pub-dependencies",
                    "manifests": ["products/vityo_app/pubspec.yaml"],
                    "forbiddenPackages": ["vityo_coding_agent"],
                },
                "products/vityo_app/pubspec.yaml",
                "dependencies:\n  vityo_coding_agent:\n    path: ../vityo_coding_agent\n",
                "vityo_coding_agent",
            ),
            (
                {
                    "id": "cargo_boundary",
                    "kind": "cargo-dependencies",
                    "manifests": ["products/vityo_coding_agent/Cargo.toml"],
                    "forbiddenPackages": ["vityo_app"],
                },
                "products/vityo_coding_agent/Cargo.toml",
                '[package]\nname = "vityo_coding_agent"\nversion = "0.1.0"\n\n'
                '[dependencies]\nvityo-app = "0.1"\n',
                "vityo_app",
            ),
        )
        for boundary, path, content, message in cases:
            with self.subTest(boundary=boundary["id"]), tempfile.TemporaryDirectory(
                prefix="vityo-architecture-"
            ) as temp:
                root = Path(temp)
                write_fixture(root, minimal_model([boundary]))
                write(root / path, content)
                with self.assertRaisesRegex(self.generator.ArchitectureError, message):
                    self.generator.load_model(root)

    def test_boundary_model_rejects_duplicate_or_malformed_boundary(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vityo-architecture-") as temp:
            root = Path(temp)
            write_fixture(root, minimal_model())
            duplicate = minimal_model(
                [
                    {
                        "id": "same",
                        "kind": "pub-dependencies",
                        "manifests": ["pubspec.yaml"],
                        "forbiddenPackages": [],
                    },
                    {
                        "id": "same",
                        "kind": "pub-dependencies",
                        "manifests": ["pubspec.yaml"],
                        "forbiddenPackages": [],
                    },
                ]
            )
            with self.assertRaisesRegex(self.generator.ArchitectureError, "duplicate dependency boundary id"):
                self.generator.validate_model(root, duplicate)

            malformed = minimal_model(
                [
                    {
                        "id": "bad",
                        "kind": "cargo-dependencies",
                        "manifests": "Cargo.toml",
                        "forbiddenPackages": [],
                    }
                ]
            )
            with self.assertRaisesRegex(self.generator.ArchitectureError, "manifests must be an array"):
                self.generator.validate_model(root, malformed)

    def test_overview_edges_are_optional_but_remain_in_node_details(self) -> None:
        model = minimal_model()
        model["edges"][0]["overview"] = False
        fragment = self.generator.render_fragment(model)
        edge_payload = fragment.partition("const edges = ")[2].partition(";const ns =")[0]

        self.assertEqual(json.loads(edge_payload), [])
        self.assertIn("typed operation", fragment)
        self.assertIn("Connected operations", fragment)

        with tempfile.TemporaryDirectory(prefix="vityo-architecture-") as temp:
            root = Path(temp)
            write_fixture(root, minimal_model())
            malformed = minimal_model()
            malformed["edges"][0]["overview"] = "hidden"
            with self.assertRaisesRegex(self.generator.ArchitectureError, "overview must be a boolean"):
                self.generator.validate_model(root, malformed)

    def test_fragment_is_theme_aware_and_contains_no_fetch_or_document_wrapper(self) -> None:
        fragment = self.generator.render_fragment(minimal_model())

        self.assertIn('<section id="vityo-system-architecture"', fragment)
        self.assertIn("var(--foreground", fragment)
        self.assertIn("var(--card", fragment)
        self.assertIn("var(--border", fragment)
        self.assertIn("@media (max-width: 64rem)", fragment)
        self.assertIn("data-vya-edges", fragment)
        self.assertIn("marker-end", fragment)
        self.assertIn("Connected operations", fragment)
        self.assertIn("color-mix(in srgb, var(--muted-foreground)", fragment)
        self.assertIn("vya-node-detail .vya-node-caption", fragment)
        self.assertIn("index * 3.2", fragment)
        self.assertIn("padding-inline-start: 3.5rem", fragment)
        self.assertIn("ResizeObserver", fragment)
        self.assertNotIn("<html", fragment.lower())
        self.assertNotIn("<head>", fragment.lower())
        self.assertNotIn("<body>", fragment.lower())
        self.assertNotIn("fetch(", fragment)
        self.assertNotIn("XMLHttpRequest", fragment)

    def test_local_server_serves_only_explicit_architecture_resources(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vityo-architecture-") as temp:
            root = Path(temp)
            write_fixture(root, minimal_model())
            server = self.generator.ThreadingHTTPServer(
                ("127.0.0.1", 0), self.generator._handler(root, watch=False)
            )
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = f"http://127.0.0.1:{server.server_port}"
            try:
                with urlopen(f"{base}/", timeout=3) as response:
                    self.assertEqual(response.status, 200)
                    self.assertIn("Fixture architecture", response.read().decode())
                with urlopen(f"{base}/system-architecture.json", timeout=3) as response:
                    self.assertEqual(response.status, 200)
                    self.assertEqual(json.loads(response.read()), minimal_model())
                with urlopen(f"{base}/favicon.ico", timeout=3) as response:
                    self.assertEqual(response.status, 204)
                for path in ("/README.md", "/%2e%2e/README.md"):
                    with self.subTest(path=path), self.assertRaises(HTTPError) as error:
                        urlopen(f"{base}{path}", timeout=3)
                    self.assertEqual(error.exception.code, 404)
                    error.exception.close()
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=3)

    def test_viewer_writes_generated_files_only_after_a_model_change(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vityo-architecture-") as temp:
            root = Path(temp)
            model = minimal_model()
            write_fixture(root, model)
            server = self.generator.ThreadingHTTPServer(
                ("127.0.0.1", 0), self.generator._handler(root, watch=False)
            )
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = f"http://127.0.0.1:{server.server_port}"
            original_write = self.generator.write_outputs
            try:
                with mock.patch.object(
                    self.generator, "write_outputs", wraps=original_write
                ) as write_outputs:
                    for path in ("/", "/system-architecture.json", "/"):
                        with urlopen(f"{base}{path}", timeout=3) as response:
                            response.read()
                    self.assertEqual(write_outputs.call_count, 0)

                    model["subtitle"] = "Changed source-backed fixture"
                    write(
                        root / "docs/design/architecture-views/system-architecture.json",
                        json.dumps(model, indent=2) + "\n",
                    )
                    with urlopen(f"{base}/system-architecture.json", timeout=3) as response:
                        self.assertEqual(json.loads(response.read())["subtitle"], model["subtitle"])
                    with urlopen(f"{base}/", timeout=3) as response:
                        self.assertIn(model["subtitle"], response.read().decode())
                    self.assertEqual(write_outputs.call_count, 1)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=3)

    def test_viewer_ignores_browser_disconnect_during_response(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vityo-architecture-") as temp:
            root = Path(temp)
            write_fixture(root, minimal_model())
            handler_class = self.generator._handler(root, watch=False)
            handler = object.__new__(handler_class)
            handler.send_response = mock.Mock()
            handler.send_header = mock.Mock()
            handler.end_headers = mock.Mock()
            handler.wfile = mock.Mock()
            handler.wfile.write.side_effect = BrokenPipeError

            handler._send(200, "text/plain; charset=utf-8", "closed by browser")

    def test_stale_server_code_never_regenerates_outputs(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vityo-architecture-") as temp:
            root = Path(temp)
            write_fixture(root, minimal_model())
            server = self.generator.ThreadingHTTPServer(
                ("127.0.0.1", 0), self.generator._handler(root, watch=False)
            )
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = f"http://127.0.0.1:{server.server_port}"
            generator_path = Path(self.generator.__file__).resolve()
            original_stat = Path.stat

            def newer_generator_stat(path: Path, *args: object, **kwargs: object):
                result = original_stat(path, *args, **kwargs)
                if path == generator_path:
                    return SimpleNamespace(st_mtime_ns=result.st_mtime_ns + 1)
                return result

            try:
                with mock.patch.object(Path, "stat", autospec=True, side_effect=newer_generator_stat):
                    with mock.patch.object(self.generator, "write_outputs") as write_outputs:
                        with self.assertRaises(HTTPError) as error:
                            urlopen(f"{base}/", timeout=3)
                        self.assertEqual(error.exception.code, 503)
                        self.assertIn("restart the viewer", error.exception.read().decode())
                        error.exception.close()
                        with urlopen(f"{base}/system-architecture.json", timeout=3) as response:
                            self.assertEqual(json.loads(response.read()), minimal_model())
                        write_outputs.assert_not_called()
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=3)


if __name__ == "__main__":
    unittest.main()
