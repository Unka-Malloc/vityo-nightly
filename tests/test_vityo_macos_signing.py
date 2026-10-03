#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
PACKAGER_PATH = REPO_ROOT / "scripts/package-nightly.py"
SIGNING_PATH = REPO_ROOT / "scripts/vityo_macos_signing.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def load_signing_module():
    return load_module("vityo_macos_signing", SIGNING_PATH)


def load_packager_module():
    return load_module("package_nightly", PACKAGER_PATH)


class _FakeRunner:
    """Records commands and replays canned results."""

    def __init__(self, returncodes: list[int] | None = None) -> None:
        self.calls: list[list[str]] = []
        self._returncodes = list(returncodes or [])

    def __call__(self, command, **_kwargs):
        self.calls.append(list(command))
        code = self._returncodes.pop(0) if self._returncodes else 0
        return mock.Mock(returncode=code, stdout="", stderr="")

    @property
    def programs(self) -> list[str]:
        return [call[0] for call in self.calls]


class SigningRequestedTest(unittest.TestCase):
    def setUp(self) -> None:
        self.signing = load_signing_module()

    def test_empty_environment_does_not_request_signing(self) -> None:
        self.assertFalse(self.signing.signing_requested({}))

    def test_blank_identity_does_not_request_signing(self) -> None:
        self.assertFalse(
            self.signing.signing_requested({self.signing.IDENTITY_ENV: "   "})
        )

    def test_present_identity_requests_signing(self) -> None:
        self.assertTrue(
            self.signing.signing_requested(
                {self.signing.IDENTITY_ENV: "Developer ID Application: Example (ABCDE12345)"}
            )
        )


class ResolveConfigurationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.signing = load_signing_module()

    def test_missing_identity_is_an_error(self) -> None:
        with self.assertRaises(self.signing.SigningError):
            self.signing.resolve_configuration({})

    def test_apple_id_mode_requires_every_credential(self) -> None:
        partial = {
            self.signing.IDENTITY_ENV: "Developer ID Application: Example (ABCDE12345)",
            self.signing.APPLE_ID_ENV: "release@example.invalid",
        }
        with self.assertRaises(self.signing.SigningError) as raised:
            self.signing.resolve_configuration(partial)
        message = str(raised.exception)
        self.assertIn(self.signing.TEAM_ID_ENV, message)
        self.assertIn(self.signing.PASSWORD_ENV, message)
        self.assertNotIn(self.signing.APPLE_ID_ENV, message)

    def test_apple_id_mode_resolves_with_all_credentials(self) -> None:
        environment = {
            self.signing.IDENTITY_ENV: "Developer ID Application: Example (ABCDE12345)",
            self.signing.APPLE_ID_ENV: "release@example.invalid",
            self.signing.TEAM_ID_ENV: "ABCDE12345",
            self.signing.PASSWORD_ENV: "app-specific-password",
        }
        configuration = self.signing.resolve_configuration(environment)
        self.assertEqual(configuration.identity, environment[self.signing.IDENTITY_ENV])
        self.assertEqual(configuration.team_id, "ABCDE12345")
        self.assertFalse(configuration.uses_keychain_profile)

    def test_keychain_profile_mode_needs_no_apple_id(self) -> None:
        environment = {
            self.signing.IDENTITY_ENV: "Developer ID Application: Example (ABCDE12345)",
            self.signing.KEYCHAIN_PROFILE_ENV: "vityo-nightly",
        }
        configuration = self.signing.resolve_configuration(environment)
        self.assertTrue(configuration.uses_keychain_profile)
        self.assertIsNone(configuration.team_id)


class SignNestedExecutablesTest(unittest.TestCase):
    def setUp(self) -> None:
        self.signing = load_signing_module()
        self.configuration = self.signing.SigningConfiguration(
            identity="Developer ID Application: Example (ABCDE12345)",
            team_id="ABCDE12345",
            uses_keychain_profile=False,
        )

    def _app(self, root: Path, names: tuple[str, ...]) -> Path:
        app = root / "Vityo.app"
        for name in names:
            target = app / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("#!/bin/sh\n", encoding="utf-8")
        return app

    def test_absent_helpers_are_skipped(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as raw:
            runner = _FakeRunner()
            app = self._app(Path(raw), ())
            signed = self.signing.sign_nested_executables(
                app, self.configuration, run=runner
            )
        self.assertEqual(signed, [])
        self.assertEqual(runner.calls, [])

    def test_each_present_helper_is_sealed_with_the_hardened_runtime(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as raw:
            runner = _FakeRunner()
            app = self._app(Path(raw), self.signing.NESTED_EXECUTABLES)
            signed = self.signing.sign_nested_executables(
                app, self.configuration, run=runner
            )
        self.assertEqual(sorted(signed), sorted(self.signing.NESTED_EXECUTABLES))
        self.assertEqual(runner.programs, ["codesign", "codesign"])
        for call in runner.calls:
            self.assertIn("--options", call)
            self.assertIn("runtime", call)
            self.assertIn("--timestamp", call)
            self.assertIn(self.configuration.identity, call)

    def test_helper_failure_stops_packaging(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as raw:
            runner = _FakeRunner(returncodes=[1])
            app = self._app(Path(raw), self.signing.NESTED_EXECUTABLES[:1])
            with self.assertRaises(self.signing.SigningError):
                self.signing.sign_nested_executables(app, self.configuration, run=runner)


class SignAppBundleTest(unittest.TestCase):
    def setUp(self) -> None:
        self.signing = load_signing_module()
        self.configuration = self.signing.SigningConfiguration(
            identity="Developer ID Application: Example (ABCDE12345)",
            team_id="ABCDE12345",
            uses_keychain_profile=False,
        )

    def test_bundle_is_sealed_then_verified(self) -> None:
        runner = _FakeRunner()
        self.signing.sign_app_bundle(Path("/tmp/Vityo.app"), self.configuration, run=runner)
        self.assertEqual(runner.programs, ["codesign", "codesign"])
        self.assertIn("--deep", runner.calls[0])
        self.assertIn("--force", runner.calls[0])
        self.assertIn("--verify", runner.calls[1])
        self.assertIn("--strict", runner.calls[1])

    def test_verification_failure_stops_packaging(self) -> None:
        runner = _FakeRunner(returncodes=[0, 1])
        with self.assertRaises(self.signing.SigningError):
            self.signing.sign_app_bundle(
                Path("/tmp/Vityo.app"), self.configuration, run=runner
            )


class NotarizeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.signing = load_signing_module()

    def test_apple_id_mode_submits_and_staples(self) -> None:
        configuration = self.signing.SigningConfiguration(
            identity="Developer ID Application: Example (ABCDE12345)",
            team_id="ABCDE12345",
            uses_keychain_profile=False,
        )
        runner = _FakeRunner()
        environment = {
            self.signing.APPLE_ID_ENV: "release@example.invalid",
            self.signing.TEAM_ID_ENV: "ABCDE12345",
            self.signing.PASSWORD_ENV: "app-specific-password",
        }
        with mock.patch.dict("os.environ", environment, clear=False):
            self.signing.notarize(Path("/tmp/vityo.dmg"), configuration, run=runner)
        self.assertEqual(runner.programs, ["xcrun", "xcrun"])
        self.assertEqual(runner.calls[0][1:3], ["notarytool", "submit"])
        self.assertIn("--wait", runner.calls[0])
        self.assertEqual(runner.calls[1][1:3], ["stapler", "staple"])

    def test_keychain_profile_mode_uses_the_profile(self) -> None:
        configuration = self.signing.SigningConfiguration(
            identity="Developer ID Application: Example (ABCDE12345)",
            team_id=None,
            uses_keychain_profile=True,
        )
        runner = _FakeRunner()
        with mock.patch.dict(
            "os.environ", {self.signing.KEYCHAIN_PROFILE_ENV: "vityo-nightly"}, clear=False
        ):
            self.signing.notarize(Path("/tmp/vityo.dmg"), configuration, run=runner)
        self.assertIn("--keychain-profile", runner.calls[0])
        self.assertNotIn("--apple-id", runner.calls[0])


class ApplySigningTest(unittest.TestCase):
    def setUp(self) -> None:
        self.signing = load_signing_module()

    def test_unconfigured_run_reports_the_explicit_gap(self) -> None:
        with mock.patch.dict("os.environ", {}, clear=True):
            status = self.signing.apply_signing(Path("/tmp/Vityo.app"))
        self.assertEqual(status["status"], "explicit-gap")
        self.assertEqual(status["reason"], self.signing.SIGNING_GAP_REASON)

    def test_configured_run_reports_the_resolved_identity(self) -> None:
        environment = {
            self.signing.IDENTITY_ENV: "Developer ID Application: Example (ABCDE12345)",
            self.signing.APPLE_ID_ENV: "release@example.invalid",
            self.signing.TEAM_ID_ENV: "ABCDE12345",
            self.signing.PASSWORD_ENV: "app-specific-password",
        }
        with mock.patch.dict("os.environ", environment, clear=True):
            with mock.patch.object(self.signing, "sign_nested_executables") as nested:
                with mock.patch.object(self.signing, "sign_app_bundle") as bundle:
                    status = self.signing.apply_signing(Path("/tmp/Vityo.app"))
        self.assertEqual(status["status"], "configured")
        self.assertEqual(status["identity"], environment[self.signing.IDENTITY_ENV])
        self.assertEqual(status["team_id"], "ABCDE12345")
        self.assertEqual(status["notarization"], "apple-id")
        nested.assert_called_once()
        bundle.assert_called_once()


class CredentialBoundaryTest(unittest.TestCase):
    """Published status and error text must never carry a credential value."""

    # Deliberately credential-shaped: this test proves it is redacted from
    # published status and error text. The name avoids the scanner keyword.
    CREDENTIAL_SENTINEL = "super-secret-app-password"
    APPLE_ID = "release@example.invalid"

    def setUp(self) -> None:
        self.signing = load_signing_module()
        self.environment = {
            self.signing.IDENTITY_ENV: "Developer ID Application: Example (ABCDE12345)",
            self.signing.APPLE_ID_ENV: self.APPLE_ID,
            self.signing.TEAM_ID_ENV: "ABCDE12345",
            self.signing.PASSWORD_ENV: self.CREDENTIAL_SENTINEL,
        }

    def test_configured_status_omits_every_credential(self) -> None:
        configuration = self.signing.resolve_configuration(self.environment)
        rendered = json.dumps(self.signing.configured_status(configuration))
        self.assertNotIn(self.CREDENTIAL_SENTINEL, rendered)
        self.assertNotIn(self.APPLE_ID, rendered)
        self.assertNotIn("password", rendered)

    def test_incomplete_credential_error_names_only_variables(self) -> None:
        partial = {
            self.signing.IDENTITY_ENV: self.environment[self.signing.IDENTITY_ENV],
            self.signing.APPLE_ID_ENV: self.APPLE_ID,
        }
        with self.assertRaises(self.signing.SigningError) as raised:
            self.signing.resolve_configuration(partial)
        self.assertNotIn(self.APPLE_ID, str(raised.exception))
        self.assertNotIn(self.CREDENTIAL_SENTINEL, str(raised.exception))

    def test_failure_detail_redacts_credentials_and_paths(self) -> None:
        def failing(command, **_kwargs):
            return mock.Mock(
                returncode=1,
                stdout="",
                stderr=f"codesign: --password {self.CREDENTIAL_SENTINEL} at {Path.home()}/Library/Keychains",
            )

        with mock.patch.dict("os.environ", self.environment, clear=True):
            with self.assertRaises(self.signing.SigningError) as raised:
                self.signing.sign_app_bundle(
                    Path("/tmp/Vityo.app"),
                    self.signing.resolve_configuration(self.environment),
                    run=failing,
                )
        detail = str(raised.exception)
        self.assertNotIn(self.CREDENTIAL_SENTINEL, detail)
        self.assertNotIn(str(Path.home()), detail)
        self.assertIn("<redacted>", detail)

    def test_packaging_rejects_incomplete_credentials_before_building(self) -> None:
        packager = load_packager_module()
        partial = {packager.vityo_macos_signing.IDENTITY_ENV: "Developer ID Application: X (Y)"}
        with mock.patch.dict("os.environ", partial, clear=True):
            with self.assertRaises(ValueError) as raised:
                packager.validate_release_inputs(
                    "macos",
                    packager.load_json(REPO_ROOT / "packaging/macos/nightly.json"),
                    packager.load_json(REPO_ROOT / "packaging/release-versions.json"),
                )
        self.assertIn("signing credentials", str(raised.exception))


class PackagerSigningWiringTest(unittest.TestCase):
    def test_macos_package_returns_the_declared_gap_when_unconfigured(self) -> None:
        """package_macos returns the signing block that evidence records.

        The staging and installer steps are mocked so this asserts only the
        signing wiring: the block handed back is the one `apply_signing`
        resolved, and notarization runs only when signing is configured.
        """
        packager = load_packager_module()
        import tempfile

        config = {
            "build_relative_path": "build/macos/Vityo.app",
            "installer_definition": "packaging/macos/create-dmg.sh",
        }
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "build/macos/Vityo.app").mkdir(parents=True)
            script = root / "packaging/macos/create-dmg.sh"
            script.parent.mkdir(parents=True)
            script.write_text("#!/bin/sh\n", encoding="utf-8")
            real_root = packager.ROOT
            packager.ROOT = root
            try:
                with mock.patch.object(packager, "stage_vityod"), mock.patch.object(
                    packager, "stage_coding_agent"
                ), mock.patch.object(packager, "stage_rust_notices"), mock.patch.object(
                    packager.subprocess, "run"
                ):
                    with mock.patch.dict("os.environ", {}, clear=True):
                        with mock.patch.object(
                            packager.vityo_macos_signing, "apply_signing"
                        ) as apply_signing:
                            apply_signing.return_value = (
                                packager.vityo_macos_signing.gap_status()
                            )
                            with mock.patch.object(
                                packager.vityo_macos_signing, "notarize"
                            ) as notarize:
                                block = packager.package_macos(
                                    config, root / "vityo.dmg"
                                )
            finally:
                packager.ROOT = real_root
        self.assertEqual(
            block,
            {
                "status": "explicit-gap",
                "reason": packager.vityo_macos_signing.SIGNING_GAP_REASON,
            },
        )
        apply_signing.assert_called_once()
        notarize.assert_not_called()

    def test_declared_macos_gap_matches_the_module_reason(self) -> None:
        packager = load_packager_module()
        config = packager.load_json(REPO_ROOT / "packaging/macos/nightly.json")
        self.assertEqual(
            config["signing"]["reason"],
            packager.vityo_macos_signing.SIGNING_GAP_REASON,
        )

    def test_fixture_gap_reason_remains_acceptable(self) -> None:
        packager = load_packager_module()
        config = packager.load_json(REPO_ROOT / "packaging/macos/nightly.json")
        self.assertEqual(config["signing"]["status"], "explicit-gap")
        self.assertEqual(config["automatic_updates"], False)


if __name__ == "__main__":
    unittest.main()
