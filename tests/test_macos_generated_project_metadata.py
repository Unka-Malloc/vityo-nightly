from __future__ import annotations

import hashlib
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
MACOS = ROOT / 'products/vityo_app/macos'


class MacOSGeneratedProjectMetadataTest(unittest.TestCase):
    def test_lockfile_covers_registered_flutter_plugins(self):
        registrant = (MACOS / 'Flutter/GeneratedPluginRegistrant.swift').read_text()
        plugins = set(re.findall(r'^import (\w+)$', registrant, re.MULTILINE)) - {
            'FlutterMacOS', 'Foundation',
        }
        lock = (MACOS / 'Podfile.lock').read_text()
        dependencies = lock.split('DEPENDENCIES:\n', 1)[1].split('\n\n', 1)[0]
        locked = set(re.findall(r'^  - (\w+) ', dependencies, re.MULTILINE)) - {'FlutterMacOS'}
        self.assertEqual(locked, plugins)
        for plugin in plugins:
            self.assertRegex(lock, rf'(?m)^  {plugin}: [a-f0-9]{{40}}$')
            self.assertIn(f'.symlinks/plugins/{plugin}/', dependencies)
        # Text mode normalizes Windows checkout line endings before hashing.
        podfile = (MACOS / 'Podfile').read_text().encode('utf-8')
        self.assertIn(f'PODFILE CHECKSUM: {hashlib.sha1(podfile).hexdigest()}', lock)

    def test_runner_embeds_pod_frameworks(self):
        project = (MACOS / 'Runner.xcodeproj/project.pbxproj').read_text()
        phase = re.search(
            r'\t\t([A-F0-9]+) /\* \[CP\] Embed Pods Frameworks \*/ = \{(.*?)\n\t\t\};',
            project, re.DOTALL,
        )
        self.assertIsNotNone(phase)
        identifier, body = phase.groups()
        self.assertEqual(project.count(f'{identifier} /* [CP] Embed Pods Frameworks */,'), 1)
        self.assertIn('Pods-Runner-frameworks.sh', body)
        for direction in ('input', 'output'):
            self.assertIn(f'Pods-Runner-frameworks-${{CONFIGURATION}}-{direction}-files.xcfilelist', body)
        self.assertIn('showEnvVarsInLog = 0;', body)

    def test_ci_requires_the_lockfile_cocoapods_version(self):
        lock = (MACOS / 'Podfile.lock').read_text()
        version = re.search(r'^COCOAPODS: ([0-9.]+)$', lock, re.MULTILINE).group(1)
        workflow = (ROOT / '.github/workflows/local-ci-gate.yml').read_text()
        macos = workflow.split('  macos-native:', 1)[1]
        self.assertIn(f'VITYO_COCOAPODS_VERSION: "{version}"', macos)
        assertion = 'test "$(pod --version)" = "${VITYO_COCOAPODS_VERSION}"'
        self.assertIn(assertion, macos)
        self.assertLess(macos.index(assertion), macos.index('name: Restore repository dependencies'))


if __name__ == '__main__':
    unittest.main()
