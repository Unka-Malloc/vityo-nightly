#!/usr/bin/env python3
"""Unit tests for scripts/vityod-desktop-matrix-gate.py."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import runpy
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
GATE_PATH = REPO_ROOT / "scripts" / "vityod-desktop-matrix-gate.py"
PLATFORMS = ("linux", "macos", "windows")
TARGETS = {
    "linux": "x86_64-unknown-linux-gnu",
    "macos": "native-apple-darwin",
    "windows": "x86_64-pc-windows-msvc",
}
FINGERPRINT = "a" * 64
HEALTH_OK = {"component": "vityod", "status": "ready", "protocolVersion": 1}


def load_gate_module():
    spec = importlib.util.spec_from_file_location("vityod_desktop_matrix_gate", GATE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {GATE_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def write_json(path: Path, payload: object) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


def daemon_frame(
    payload: object | None = None,
    *,
    version: int = 1,
    kind: int = 1,
    length: int | None = None,
    raw_body: bytes | None = None,
) -> bytes:
    body = (
        raw_body
        if raw_body is not None
        else json.dumps(
            {"method": "handshake.negotiate.result"} if payload is None else payload
        ).encode("utf-8")
    )
    header = struct.pack(
        ">HBBIQI4x",
        version,
        kind,
        0,
        0,
        1,
        len(body) if length is None else length,
    )
    return header + body


class FakeByteSource:
    """Shared bookkeeping for the fake socket and the fake buffered pipe."""

    def __init__(self, data: bytes = b"", *, chunk: int | None = None) -> None:
        self.data = data
        self.chunk = chunk
        self.sent = b""
        self.flush_count = 0
        self.timeouts: list[int] = []
        self.endpoints: list[str] = []
        self.exited = False

    def _consume(self, size: int) -> bytes:
        if not self.data:
            return b""
        take = min(size, self.chunk) if self.chunk else size
        piece, self.data = self.data[:take], self.data[take:]
        return piece

    def read(self, size: int) -> bytes:
        return self._consume(size)

    def flush(self) -> None:
        self.flush_count += 1

    def settimeout(self, value: int) -> None:
        self.timeouts.append(value)

    def connect(self, endpoint: str) -> None:
        self.endpoints.append(endpoint)

    def __enter__(self) -> FakeByteSource:
        return self

    def __exit__(self, *exc_info: object) -> bool:
        self.exited = True
        return False


class FakeStream(FakeByteSource):
    """Socket-like stream exposing recv/sendall."""

    def recv(self, size: int) -> bytes:
        return self._consume(size)

    def sendall(self, data: bytes) -> None:
        self.sent += data


class FakePipe(FakeByteSource):
    """File-like stream exposing read/write without recv or sendall."""

    def write(self, data: bytes) -> int:
        self.sent += data
        return len(data)


class FakeTemporaryDirectory:
    def __init__(self, path: Path) -> None:
        self.path = str(path)

    def __enter__(self) -> str:
        return self.path

    def __exit__(self, *exc_info: object) -> bool:
        return False


class VityodDesktopMatrixGateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.gate = load_gate_module()
        self.temporary = tempfile.TemporaryDirectory(prefix="vityod-matrix-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        root_patcher = mock.patch.object(self.gate, "ROOT", self.root)
        root_patcher.start()
        self.addCleanup(root_patcher.stop)

    # ---------------------------------------------------------------- helpers

    def package_component(self, platform: str = "linux", **overrides: object) -> dict[str, object]:
        component: dict[str, object] = {
            "target": TARGETS[platform],
            "package_relative_path": "components/vityod",
            "required_runtime_libraries": ["glibc"],
        }
        component.update(overrides)
        return component

    def write_package(self, platform: str = "linux", component: object = None) -> Path:
        manifest: dict[str, object] = {
            "schema_version": 1,
            "platform": platform,
            "product": "vityo",
        }
        if component is not False:
            manifest["vityod"] = (
                self.package_component(platform) if component is None else component
            )
        return write_json(self.root / "packaging" / platform / "nightly.json", manifest)

    def fixture_payload(self, platform: str = "linux", **overrides: object) -> dict[str, object]:
        payload: dict[str, object] = {
            "schema_version": 1,
            "component": "vityod",
            "daemon_version": "0.0.0-fixture",
            "target": TARGETS[platform],
            "protocol_min": 1,
            "protocol_max": 1,
            "executable_sha256": "0" * 64,
            "build_source_fingerprint": "0" * 64,
            "required_runtime_libraries": ["glibc"],
            "package_relative_path": "components/vityod",
            "fixture_only": True,
            "native_launch": False,
            "blocked_reason": "Native launch needs a matching release host.",
        }
        payload.update(overrides)
        return payload

    def write_fixture(self, platform: str = "linux", **overrides: object) -> Path:
        return write_json(
            self.root
            / "packaging"
            / "vityo"
            / "fixtures"
            / "vityod"
            / platform
            / "component-manifest.json",
            self.fixture_payload(platform, **overrides),
        )

    def write_contract(self, name: object = "vityod") -> Path:
        return write_json(
            self.root / "packaging" / "vityo" / "desktop-delivery.json",
            {"schema_version": 1, "product": "vityo", "component": {"name": name}},
        )

    def write_application(
        self,
        platform: str = "linux",
        *,
        binary: bytes | None = b"vityod-binary",
        identity: object = None,
        manifests: int = 1,
        component: object = None,
    ) -> Path:
        application = self.root / "application"
        if component is not False:
            self.write_package(platform, component=component)
        binary_path = application / "components" / "vityod"
        binary_path.parent.mkdir(parents=True, exist_ok=True)
        if binary is not None:
            binary_path.write_bytes(binary)
        payload: dict[str, object] = {
            "schema_version": 1,
            "component": "vityod",
            "daemon_version": "0.9.0",
            "target": TARGETS[platform],
            "protocol_min": 1,
            "protocol_max": 1,
            "executable_sha256": hashlib.sha256(binary or b"").hexdigest(),
            "build_source_fingerprint": FINGERPRINT,
            "required_runtime_libraries": ["glibc"],
            "package_relative_path": "components/vityod",
        }
        if identity is not None:
            payload.update(identity)  # type: ignore[arg-type]
        for index in range(manifests):
            destination = (
                application / "vityod-component.json"
                if index == 0
                else application / f"nested-{index}" / "vityod-component.json"
            )
            write_json(destination, payload)
        return application

    def probe_tempdir(self, path: Path):
        return mock.patch.object(
            self.gate.tempfile,
            "TemporaryDirectory",
            return_value=FakeTemporaryDirectory(path),
        )

    def validate_native(
        self,
        platform: str = "linux",
        *,
        health: object = None,
        probe: tuple[bool, str] = (True, "two authenticated client handshakes completed"),
        application: Path | None = None,
    ) -> tuple[list[str], mock.Mock, mock.Mock]:
        completed = SimpleNamespace(
            returncode=0,
            stdout=json.dumps(HEALTH_OK if health is None else health),
        )
        with mock.patch.object(self.gate.subprocess, "run", return_value=completed) as run:
            with mock.patch.object(self.gate, "_probe_reconnect", return_value=probe) as probe_mock:
                errors = self.gate.validate_native_component(
                    platform,
                    application if application is not None else self.root / "application",
                )
        return errors, run, probe_mock

    # ------------------------------------------------------------- load_object

    def test_load_object_requires_a_json_object_under_the_repository_root(self) -> None:
        path = self.root / "packaging" / "value.json"
        write_json(path, [1, 2, 3])
        with self.assertRaisesRegex(ValueError, "must contain an object"):
            self.gate.load_object(path)

        write_json(path, {"ok": True})
        self.assertEqual(self.gate.load_object(path), {"ok": True})

    # ---------------------------------------------------------- fixture lane

    def test_fixture_lane_accepts_a_consistent_package_fixture(self) -> None:
        for platform in PLATFORMS:
            with self.subTest(platform=platform):
                self.write_package(platform)
                self.write_fixture(platform)
                self.assertEqual(self.gate.validate_fixture(platform), [])

    def test_fixture_lane_rejects_a_package_without_a_vityod_component(self) -> None:
        self.write_package("linux", component=False)
        self.write_fixture("linux")
        self.assertEqual(
            self.gate.validate_fixture("linux"),
            ["linux: package manifest has no vityod component"],
        )

    def test_fixture_lane_reports_every_fixture_contract_violation(self) -> None:
        self.write_package("linux")
        self.write_fixture(
            "linux",
            schema_version=2,
            fixture_only=False,
            target="aarch64-unknown-linux-gnu",
            package_relative_path="components/other",
            required_runtime_libraries=["musl"],
            protocol_min=0,
            protocol_max=2,
            executable_sha256="z" * 64,
            build_source_fingerprint="abc",
            component="vityo-coding-agent",
            native_launch=True,
            blocked_reason="   ",
        )

        errors = self.gate.validate_fixture("linux")

        self.assertEqual(len(errors), 10)
        for expected in (
            "fixture identity is invalid",
            "fixture target does not match package contract",
            "fixture package_relative_path does not match package contract",
            "fixture runtime libraries do not match package contract",
            "fixture protocol range is invalid",
            "fixture executable_sha256 is invalid",
            "fixture build_source_fingerprint is invalid",
            "fixture component must be vityod",
            "fixture must not claim native launch",
            "fixture-only evidence needs a blocked reason",
        ):
            with self.subTest(expected=expected):
                self.assertIn(f"linux: {expected}", errors)

    # ----------------------------------------------------------- native lane

    def test_native_lane_requires_a_package_vityod_component(self) -> None:
        self.write_package("linux", component=False)
        application = self.write_application("linux", component=False)
        self.assertEqual(
            self.gate.validate_native_component("linux", application),
            ["linux: package manifest has no vityod component"],
        )

    def test_native_lane_requires_exactly_one_component_manifest(self) -> None:
        for manifests in (0, 2):
            with self.subTest(manifests=manifests):
                application = self.write_application("linux", manifests=manifests)
                self.assertEqual(
                    self.gate.validate_native_component("linux", application),
                    ["linux: package must contain exactly one component manifest"],
                )

    def test_native_lane_requires_the_declared_executable(self) -> None:
        application = self.write_application("linux", binary=None)
        self.assertEqual(
            self.gate.validate_native_component("linux", application),
            ["linux: declared vityod executable is missing"],
        )

    def test_native_lane_accepts_a_bound_component_and_health_probe(self) -> None:
        application = self.write_application("linux")
        errors, run, probe = self.validate_native("linux", application=application)

        self.assertEqual(errors, [])
        self.assertEqual(
            run.call_args,
            mock.call(
                [application / "components" / "vityod", "--health"],
                check=False,
                capture_output=True,
                text=True,
                timeout=5,
            ),
        )
        probe.assert_called_once_with(application / "components" / "vityod")

    def test_native_lane_reports_every_component_identity_drift(self) -> None:
        for key, value in (
            ("schema_version", 2),
            ("component", "vityo-coding-agent"),
            ("protocol_min", 2),
            ("protocol_max", 0),
            ("package_relative_path", "components/other"),
            ("required_runtime_libraries", ["musl"]),
            ("executable_sha256", "0" * 64),
        ):
            with self.subTest(key=key):
                application = self.write_application("linux", identity={key: value})
                errors, _, _ = self.validate_native("linux", application=application)
                self.assertIn(
                    f"linux: component {key} does not match the package",
                    errors,
                )
                self.assertNotIn("linux: component target does not match the package", errors)

    def test_native_lane_accepts_a_platform_suffixed_apple_target(self) -> None:
        application = self.write_application(
            "macos",
            identity={"target": "aarch64-apple-darwin"},
        )
        errors, _, _ = self.validate_native("macos", application=application)
        self.assertEqual(errors, [])

    def test_native_lane_rejects_foreign_targets_versions_and_fingerprints(self) -> None:
        cases = (
            ({"target": "aarch64-unknown-linux-gnu"}, "component target does not match the package"),
            ({"target": "x86_64-apple-darwin"}, "component target does not match the package"),
            ({"daemon_version": "0.9.0 beta"}, "daemon version is invalid"),
            ({"daemon_version": ""}, "daemon version is invalid"),
            ({"build_source_fingerprint": "abc"}, "daemon source fingerprint is invalid"),
            ({"build_source_fingerprint": "Z" * 64}, "daemon source fingerprint is invalid"),
        )
        for identity, message in cases:
            with self.subTest(identity=identity):
                application = self.write_application("linux", identity=identity)
                errors, _, _ = self.validate_native("linux", application=application)
                self.assertIn(f"linux: {message}", errors)

    def test_native_lane_fails_closed_on_health_and_reconnect_probe_failures(self) -> None:
        def health(**overrides: object) -> dict[str, object]:
            return {
                "returncode": 0,
                "stdout": json.dumps({**HEALTH_OK, **overrides}),
            }

        cases = (
            ({"returncode": 3, "stdout": json.dumps(HEALTH_OK)}, "packaged daemon health check failed"),
            ({"returncode": 0, "stdout": "not-json"}, "packaged daemon health check failed"),
            (health(component="vityo-coding-agent"), "packaged daemon health check failed"),
            (health(status="starting"), "packaged daemon health check failed"),
            (health(protocolVersion=2), "packaged daemon health check failed"),
        )
        for completed, message in cases:
            with self.subTest(completed=completed):
                application = self.write_application("linux")
                with mock.patch.object(
                    self.gate.subprocess,
                    "run",
                    return_value=SimpleNamespace(**completed),
                ):
                    with mock.patch.object(
                        self.gate, "_probe_reconnect", return_value=(True, "ok")
                    ):
                        errors = self.gate.validate_native_component("linux", application)
                self.assertIn(f"linux: {message}", errors)

        application = self.write_application("linux")
        errors, _, _ = self.validate_native(
            "linux",
            application=application,
            probe=(False, "packaged daemon endpoint did not become ready"),
        )
        self.assertEqual(errors, ["linux: packaged daemon endpoint did not become ready"])

    # ------------------------------------------------------ read/exact frames

    def test_read_exact_streams_chunks_and_fails_closed_on_eof(self) -> None:
        self.assertEqual(self.gate._read_exact(FakeStream(b"abcdefgh", chunk=3), 5), b"abcde")
        self.assertEqual(self.gate._read_exact(FakePipe(b"abcdefgh", chunk=4), 6), b"abcdef")
        self.assertEqual(self.gate._read_exact(FakeStream(b"ignored"), 0), b"")

        for connection in (FakeStream(b"ab"), FakePipe(b"ab", chunk=1)):
            with self.subTest(connection=type(connection).__name__):
                with self.assertRaisesRegex(RuntimeError, "daemon closed the reconnect probe"):
                    self.gate._read_exact(connection, 4)

    def test_handshake_payload_declares_capabilities_and_a_bounded_deadline(self) -> None:
        before = int(time.time() * 1000)
        raw = self.gate._handshake_payload("client-7")
        after = int(time.time() * 1000)
        payload = json.loads(raw)

        self.assertEqual(payload["protocolVersion"], 1)
        self.assertEqual(payload["method"], "handshake.negotiate")
        self.assertEqual(payload["requestId"], "client-7-request")
        self.assertEqual(payload["clientInstanceId"], "client-7")
        self.assertEqual(payload["idempotencyKey"], "client-7-handshake")
        self.assertEqual(payload["capabilities"], [])
        self.assertEqual(
            payload["params"],
            {"requiredCapabilities": ["event.resume", "workspace.snapshot"]},
        )
        self.assertGreaterEqual(payload["deadlineUnixMillis"], before + 5000)
        self.assertLessEqual(payload["deadlineUnixMillis"], after + 5000)
        self.assertNotIn(b" ", raw)

    def test_exchange_handshake_frames_the_request_and_accepts_the_result(self) -> None:
        connection = FakeStream(daemon_frame(), chunk=3)
        self.assertIsNone(self.gate._exchange_handshake(connection, "package-probe-1"))

        header, body = connection.sent[:24], connection.sent[24:]
        version, kind, flags, stream, sequence, length = struct.unpack(
            ">HBBIQI4x", header
        )
        self.assertEqual((version, kind), (1, 1))
        self.assertEqual((flags, stream, sequence, length), (0, 0, 1, len(body)))
        self.assertEqual(json.loads(body)["clientInstanceId"], "package-probe-1")

    def test_exchange_handshake_uses_the_write_path_without_sendall(self) -> None:
        connection = FakePipe(daemon_frame(), chunk=5)
        self.assertIsNone(self.gate._exchange_handshake(connection, "package-probe-2"))

        self.assertEqual(connection.flush_count, 1)
        self.assertIn(b'"clientInstanceId":"package-probe-2"', connection.sent)

    def test_exchange_handshake_rejects_corrupt_and_rejected_frames(self) -> None:
        for corrupt in (
            daemon_frame(version=2),
            daemon_frame(kind=0),
            daemon_frame(length=1024 * 1024 + 1),
        ):
            with self.subTest(corrupt=corrupt[:24]):
                with self.assertRaisesRegex(RuntimeError, "invalid handshake frame"):
                    self.gate._exchange_handshake(FakeStream(corrupt), "package-probe-1")

        with self.assertRaisesRegex(RuntimeError, "daemon rejected the packaged handshake"):
            self.gate._exchange_handshake(
                FakeStream(daemon_frame({"method": "handshake.negotiate.error"})),
                "package-probe-1",
            )

        with self.assertRaises(json.JSONDecodeError):
            self.gate._exchange_handshake(
                FakeStream(daemon_frame(raw_body=b"{not-json")),
                "package-probe-1",
            )

    # ------------------------------------------------------------- handshakes

    def test_handshake_uses_a_unix_socket_on_posix_hosts(self) -> None:
        connection = FakeStream(daemon_frame())
        endpoint = str(self.root / "service.sock")
        unix_family = getattr(self.gate.socket, "AF_UNIX", mock.sentinel.unix_family)
        with mock.patch.object(
            self.gate.socket, "AF_UNIX", unix_family, create=True
        ), mock.patch.object(
            self.gate, "os", SimpleNamespace(name="posix", getpid=os.getpid)
        ):
            with mock.patch.object(
                self.gate.socket, "socket", return_value=connection
            ) as socket_factory:
                self.assertIsNone(self.gate._handshake(endpoint, "package-probe-1"))

        socket_factory.assert_called_once_with(
            unix_family, self.gate.socket.SOCK_STREAM
        )
        self.assertEqual(connection.timeouts, [5])
        self.assertEqual(connection.endpoints, [endpoint])
        self.assertTrue(connection.exited)
        self.assertIn(b'"clientInstanceId":"package-probe-1"', connection.sent)

    def test_handshake_uses_a_named_pipe_file_on_windows_hosts(self) -> None:
        endpoint = self.root / "pipe.bin"
        # The probe writes its framed request at offset zero, so the canned
        # daemon response must start after the frame header plus the request.
        request_size = 24 + len(self.gate._handshake_payload("package-probe-1"))
        endpoint.write_bytes(b"\x00" * request_size + daemon_frame())

        with mock.patch.object(
            self.gate, "os", SimpleNamespace(name="nt", getpid=os.getpid)
        ):
            self.assertIsNone(self.gate._handshake(str(endpoint), "package-probe-1"))

        written = endpoint.read_bytes()[:request_size]
        self.assertEqual(
            struct.unpack(">HBBIQI4x", written[:24]),
            (1, 1, 0, 0, 1, request_size - 24),
        )
        self.assertEqual(
            json.loads(written[24:])["idempotencyKey"],
            "package-probe-1-handshake",
        )

    # -------------------------------------------------------- reconnect probe

    def test_probe_reconnect_completes_two_handshakes_on_posix(self) -> None:
        socket_dir = self.root / "probe"
        socket_dir.mkdir()
        (socket_dir / "service.sock").write_text("", encoding="utf-8")
        process = mock.Mock()
        process.poll.return_value = None
        process.wait.return_value = 0
        binary = self.root / "vityod"
        endpoint = str(socket_dir / "service.sock")

        with self.probe_tempdir(socket_dir):
            with mock.patch.object(
                self.gate, "os", SimpleNamespace(name="posix", getpid=os.getpid)
            ):
                with mock.patch.object(
                    self.gate.subprocess, "Popen", return_value=process
                ) as popen:
                    with mock.patch.object(self.gate, "_handshake") as handshake:
                        result = self.gate._probe_reconnect(binary)

        self.assertEqual(result, (True, "two authenticated client handshakes completed"))
        self.assertEqual(
            [call.args for call in handshake.call_args_list],
            [(endpoint, "package-probe-1"), (endpoint, "package-probe-2")],
        )
        self.assertEqual(
            popen.call_args,
            mock.call(
                [binary, "--serve", "--endpoint", endpoint],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ),
        )
        process.terminate.assert_called_once_with()
        process.wait.assert_called_once_with(timeout=3)
        process.kill.assert_not_called()

    def test_probe_reconnect_times_out_when_the_endpoint_never_appears(self) -> None:
        socket_dir = self.root / "probe-missing"
        socket_dir.mkdir()
        process = mock.Mock()
        process.poll.return_value = None
        process.wait.return_value = 0

        with self.probe_tempdir(socket_dir):
            with mock.patch.object(
                self.gate.subprocess, "Popen", return_value=process
            ):
                with mock.patch.object(
                    self.gate.time, "monotonic", side_effect=[0.0, 1.0, 10.0]
                ):
                    with mock.patch.object(self.gate.time, "sleep") as sleep:
                        result = self.gate._probe_reconnect(self.root / "vityod")

        self.assertEqual(
            result, (False, "packaged daemon endpoint did not become ready")
        )
        sleep.assert_called_once_with(0.025)
        process.terminate.assert_called_once_with()

    def test_probe_reconnect_reports_a_daemon_that_exits_before_validation(self) -> None:
        socket_dir = self.root / "probe-exited"
        socket_dir.mkdir()
        process = mock.Mock()
        process.poll.return_value = 3
        process.wait.return_value = 0

        with self.probe_tempdir(socket_dir):
            with mock.patch.object(
                self.gate.subprocess, "Popen", return_value=process
            ):
                with mock.patch.object(self.gate, "_handshake") as handshake:
                    result = self.gate._probe_reconnect(self.root / "vityod")

        self.assertEqual(
            result, (False, "packaged daemon exited before reconnect validation")
        )
        handshake.assert_not_called()

    def test_probe_reconnect_surfaces_handshake_errors(self) -> None:
        socket_dir = self.root / "probe-errors"
        socket_dir.mkdir()
        (socket_dir / "service.sock").write_text("", encoding="utf-8")
        process = mock.Mock()
        process.poll.return_value = None
        process.wait.return_value = 0

        for error in (
            OSError("connection refused"),
            RuntimeError("daemon closed the reconnect probe"),
            ValueError("daemon rejected the packaged handshake"),
            json.JSONDecodeError("bad frame", "{}", 0),
        ):
            with self.subTest(error=type(error).__name__):
                with mock.patch.object(
                    self.gate.tempfile,
                    "TemporaryDirectory",
                    return_value=FakeTemporaryDirectory(socket_dir),
                ):
                    with mock.patch.object(
                        self.gate, "os", SimpleNamespace(name="posix", getpid=os.getpid)
                    ):
                        with mock.patch.object(
                            self.gate.subprocess, "Popen", return_value=process
                        ):
                            with mock.patch.object(
                                self.gate, "_handshake", side_effect=error
                            ):
                                result = self.gate._probe_reconnect(
                                    self.root / "vityod"
                                )
                self.assertEqual(result, (False, str(error)))
        process.terminate.assert_called()

    def test_probe_reconnect_kills_a_daemon_that_ignores_terminate(self) -> None:
        socket_dir = self.root / "probe-kill"
        socket_dir.mkdir()
        (socket_dir / "service.sock").write_text("", encoding="utf-8")
        process = mock.Mock()
        process.poll.return_value = None
        process.wait.side_effect = [
            subprocess.TimeoutExpired(cmd="vityod", timeout=3),
            0,
        ]

        with self.probe_tempdir(socket_dir):
            with mock.patch.object(self.gate.subprocess, "Popen", return_value=process):
                with mock.patch.object(self.gate, "_handshake"):
                    result = self.gate._probe_reconnect(self.root / "vityod")

        self.assertEqual(result, (True, "two authenticated client handshakes completed"))
        process.terminate.assert_called_once_with()
        process.kill.assert_called_once_with()
        self.assertEqual(process.wait.call_args_list, [mock.call(timeout=3)] * 2)

    def test_probe_reconnect_retries_the_named_pipe_handshake_on_windows(self) -> None:
        pipe_dir = self.root / "probe-pipe"
        pipe_dir.mkdir()
        process = mock.Mock()
        process.poll.return_value = None
        process.wait.return_value = 0
        binary = self.root / "vityod.exe"

        with self.probe_tempdir(pipe_dir):
            with mock.patch.object(
                self.gate, "os", SimpleNamespace(name="nt", getpid=os.getpid)
            ):
                with mock.patch.object(self.gate.secrets, "token_hex", return_value="abcdef"):
                    with mock.patch.object(self.gate.time, "sleep") as sleep:
                        with mock.patch.object(
                            self.gate.subprocess, "Popen", return_value=process
                        ) as popen:
                            with mock.patch.object(
                                self.gate,
                                "_handshake",
                                side_effect=[OSError("pipe not ready"), None, None],
                            ) as handshake:
                                result = self.gate._probe_reconnect(binary)

        endpoint = rf"\\.\pipe\vityod-package-{os.getpid()}-abcdef"
        self.assertEqual(result, (True, "two authenticated client handshakes completed"))
        self.assertEqual(
            popen.call_args.args[0], [binary, "--serve", "--endpoint", endpoint]
        )
        sleep.assert_called_once_with(0.025)
        self.assertEqual(handshake.call_args_list[-1], mock.call(endpoint, "package-probe-2"))

    def test_probe_reconnect_reports_named_pipe_exit_and_readiness_failures(self) -> None:
        pipe_dir = self.root / "probe-pipe-failures"
        pipe_dir.mkdir()
        exited = mock.Mock()
        exited.poll.return_value = 1
        exited.wait.return_value = 0

        with self.probe_tempdir(pipe_dir):
            with mock.patch.object(
                self.gate, "os", SimpleNamespace(name="nt", getpid=os.getpid)
            ):
                with mock.patch.object(self.gate.subprocess, "Popen", return_value=exited):
                    with mock.patch.object(self.gate, "_handshake") as handshake:
                        result = self.gate._probe_reconnect(self.root / "vityod.exe")

        self.assertEqual(result, (False, "packaged daemon exited before reconnect validation"))
        handshake.assert_not_called()

        running = mock.Mock()
        running.poll.return_value = None
        running.wait.return_value = 0
        with self.probe_tempdir(pipe_dir):
            with mock.patch.object(
                self.gate, "os", SimpleNamespace(name="nt", getpid=os.getpid)
            ):
                with mock.patch.object(self.gate.subprocess, "Popen", return_value=running):
                    with mock.patch.object(
                        self.gate.time, "monotonic", side_effect=[0.0, 1.0, 10.0]
                    ):
                        with mock.patch.object(self.gate.time, "sleep") as sleep:
                            with mock.patch.object(
                                self.gate,
                                "_handshake",
                                side_effect=[OSError("pipe not ready"), OSError("pipe not ready")],
                            ):
                                result = self.gate._probe_reconnect(
                                    self.root / "vityod.exe"
                                )

        self.assertEqual(result, (False, "packaged daemon endpoint did not become ready"))
        sleep.assert_called_once_with(0.025)

    # ------------------------------------------------------------------ main

    def test_main_requires_exactly_one_lane_selection(self) -> None:
        for argv in (
            ["--fixtures-only", "--platform", "linux"],
            ["--fixtures-only", "--application-root", "application"],
            [],
        ):
            with self.subTest(argv=argv):
                stderr = io.StringIO()
                with mock.patch.object(sys, "argv", [str(GATE_PATH), *argv]):
                    with redirect_stderr(stderr):
                        with self.assertRaises(SystemExit) as raised:
                            self.gate.main()
                self.assertEqual(raised.exception.code, 2)
                self.assertIn("usage:", stderr.getvalue())

    def test_main_fixtures_only_reports_one_lane_per_platform(self) -> None:
        self.write_contract()
        for platform in PLATFORMS:
            self.write_package(platform)
            self.write_fixture(platform)

        stdout = io.StringIO()
        with mock.patch.object(sys, "argv", [str(GATE_PATH), "--fixtures-only"]):
            with redirect_stdout(stdout):
                code = self.gate.main()

        self.assertEqual(code, 0)
        self.assertEqual(
            json.loads(stdout.getvalue()),
            {
                "ok": True,
                "mode": "fixtures-only",
                "lanes": [
                    {"platform": platform, "status": "fixture-only"}
                    for platform in PLATFORMS
                ],
                "errors": [],
            },
        )

    def test_main_fixtures_only_fails_closed_on_any_fixture_error(self) -> None:
        self.write_contract()
        for platform in PLATFORMS:
            self.write_package(platform)
            self.write_fixture(platform)
        self.write_fixture("macos", blocked_reason="  ")

        stdout = io.StringIO()
        with mock.patch.object(sys, "argv", [str(GATE_PATH), "--fixtures-only"]):
            with redirect_stdout(stdout):
                code = self.gate.main()

        payload = json.loads(stdout.getvalue())
        self.assertEqual(code, 1)
        self.assertFalse(payload["ok"])
        self.assertEqual(
            payload["errors"],
            ["macos: fixture-only evidence needs a blocked reason"],
        )
        self.assertEqual(len(payload["lanes"]), 3)

    def test_main_rejects_a_foreign_desktop_delivery_component(self) -> None:
        for name in ("vityo-coding-agent", None):
            with self.subTest(name=name):
                write_json(
                    self.root / "packaging" / "vityo" / "desktop-delivery.json",
                    {"schema_version": 1} if name is None else {"component": {"name": name}},
                )
                for platform in PLATFORMS:
                    self.write_package(platform)
                    self.write_fixture(platform)

                stdout = io.StringIO()
                with mock.patch.object(sys, "argv", [str(GATE_PATH), "--fixtures-only"]):
                    with redirect_stdout(stdout):
                        code = self.gate.main()

                payload = json.loads(stdout.getvalue())
                self.assertEqual(code, 1)
                self.assertEqual(
                    payload["errors"][0],
                    "desktop delivery component must be vityod",
                )

    def test_main_native_lane_requires_a_matching_host(self) -> None:
        self.write_contract()
        for host, platform in (("linux", "macos"), ("sunos5", "linux")):
            with self.subTest(host=host):
                stdout = io.StringIO()
                with mock.patch.object(
                    sys,
                    "argv",
                    [
                        str(GATE_PATH),
                        "--platform",
                        platform,
                        "--application-root",
                        str(self.root / "application"),
                    ],
                ):
                    with mock.patch.object(self.gate.sys, "platform", host):
                        with mock.patch.object(
                            self.gate, "validate_native_component"
                        ) as validate:
                            with redirect_stdout(stdout):
                                code = self.gate.main()

                validate.assert_not_called()
                payload = json.loads(stdout.getvalue())
                self.assertEqual(code, 1)
                self.assertEqual(payload["mode"], "native")
                self.assertEqual(
                    payload["errors"],
                    [f"{platform}: native evidence requires a matching host"],
                )
                self.assertEqual(
                    payload["lanes"],
                    [{"platform": platform, "status": "failed"}],
                )

    def test_main_native_lane_reports_passed_and_failed_lanes(self) -> None:
        self.write_contract()
        application = self.root / "application"
        application.mkdir()
        for host, platform, errors, code_expected, status in (
            ("darwin", "macos", [], 0, "passed"),
            ("linux", "linux", ["linux: packaged daemon health check failed"], 1, "failed"),
        ):
            with self.subTest(platform=platform):
                stdout = io.StringIO()
                with mock.patch.object(
                    sys,
                    "argv",
                    [
                        str(GATE_PATH),
                        "--platform",
                        platform,
                        "--application-root",
                        str(application),
                    ],
                ):
                    with mock.patch.object(self.gate.sys, "platform", host):
                        with mock.patch.object(
                            self.gate, "validate_native_component", return_value=errors
                        ) as validate:
                            with redirect_stdout(stdout):
                                code = self.gate.main()

                validate.assert_called_once_with(platform, application.resolve())
                payload = json.loads(stdout.getvalue())
                self.assertEqual(code, code_expected)
                self.assertEqual(payload["ok"], not errors)
                self.assertEqual(payload["errors"], errors)
                self.assertEqual(
                    payload["lanes"],
                    [{"platform": platform, "status": status}],
                )

    def test_main_fixtures_only_accepts_the_repository_packaging_contract(self) -> None:
        stdout = io.StringIO()
        with mock.patch.object(self.gate, "ROOT", REPO_ROOT):
            with mock.patch.object(sys, "argv", [str(GATE_PATH), "--fixtures-only"]):
                with redirect_stdout(stdout):
                    code = self.gate.main()

        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["errors"], [])
        self.assertEqual(code, 0)
        self.assertEqual(
            payload["lanes"],
            [
                {"platform": platform, "status": "fixture-only"}
                for platform in PLATFORMS
            ],
        )

    def test_script_entrypoint_exits_with_the_parser_error_code(self) -> None:
        stderr = io.StringIO()
        with mock.patch.object(
            sys, "argv", [str(GATE_PATH), "--fixtures-only", "--platform", "linux"]
        ):
            with redirect_stderr(stderr):
                with self.assertRaises(SystemExit) as raised:
                    runpy.run_path(str(GATE_PATH), run_name="__main__")

        self.assertEqual(raised.exception.code, 2)
        self.assertIn(
            "--fixtures-only cannot be combined with a native lane",
            stderr.getvalue(),
        )


if __name__ == "__main__":
    unittest.main()
