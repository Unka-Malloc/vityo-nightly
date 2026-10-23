from __future__ import annotations

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
APP_ROOT = REPO_ROOT / "products" / "vityo_app"


class SecureCredentialPlatformContractTest(unittest.TestCase):
    def _read(self, relative_path: str) -> str:
        return (REPO_ROOT / relative_path).read_text(encoding="utf-8")

    def test_linux_registers_libsecret_plugin_and_build_dependency(self) -> None:
        registrant = self._read(
            "products/vityo_app/linux/flutter/generated_plugin_registrant.cc"
        )
        cmake = self._read(
            "products/vityo_app/linux/flutter/generated_plugins.cmake"
        )
        self.assertIn("flutter_secure_storage_linux", registrant)
        self.assertIn("flutter_secure_storage_linux", cmake)
        self.assertIn("libsecret-1-dev", self._read("scripts/bootstrap-dev-env.sh"))
        self.assertIn("libsecret-1-dev", self._read("docker/dev-env.Dockerfile"))
        self.assertIn(
            "libsecret-1-dev", self._read(".github/workflows/local-ci-gate.yml")
        )

    def test_windows_registers_plugin_and_atl_build_component(self) -> None:
        registrant = self._read(
            "products/vityo_app/windows/flutter/generated_plugin_registrant.cc"
        )
        cmake = self._read(
            "products/vityo_app/windows/flutter/generated_plugins.cmake"
        )
        self.assertIn("flutter_secure_storage_windows", registrant)
        self.assertIn("flutter_secure_storage_windows", cmake)
        self.assertIn(
            "Microsoft.VisualStudio.Component.VC.ATL",
            self._read("scripts/bootstrap-dev-env-windows.ps1"),
        )

    def test_android_uses_supported_sdk_and_excludes_credential_backup(self) -> None:
        gradle = (APP_ROOT / "android/app/build.gradle.kts").read_text(
            encoding="utf-8"
        )
        manifest = (APP_ROOT / "android/app/src/main/AndroidManifest.xml").read_text(
            encoding="utf-8"
        )
        self.assertIn("maxOf(23, flutter.minSdkVersion)", gradle)
        self.assertIn('android:allowBackup="false"', manifest)

    def test_apple_runners_register_plugin_with_target_specific_keychain_policy(
        self,
    ) -> None:
        macos_registrant = (
            APP_ROOT / "macos/Flutter/GeneratedPluginRegistrant.swift"
        ).read_text(encoding="utf-8")
        ios_registrant = (APP_ROOT / "ios/Runner/GeneratedPluginRegistrant.m").read_text(
            encoding="utf-8"
        )
        ios_entitlements = (APP_ROOT / "ios/Runner/Runner.entitlements").read_text(
            encoding="utf-8"
        )
        secure_backend = (
            APP_ROOT
            / "lib/src/view_ide/environment/configuration/platform_secure_credential_storage.dart"
        ).read_text(encoding="utf-8")
        self.assertIn("flutter_secure_storage_darwin", macos_registrant)
        self.assertIn("flutter_secure_storage_darwin", ios_registrant)
        self.assertIn("keychain-access-groups", ios_entitlements)
        self.assertIn("usesDataProtectionKeychain: false", secure_backend)


if __name__ == "__main__":
    unittest.main()
