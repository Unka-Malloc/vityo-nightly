from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / '.github/workflows/local-ci-gate.yml'
OUTPUT = Path('build/evidence/macos-generated-project-diagnostics.txt')
PATHS = (
    'products/vityo_app/macos/Podfile.lock',
    'products/vityo_app/macos/Runner.xcodeproj/project.pbxproj',
)


def diagnostic_source():
    workflow = WORKFLOW.read_text(encoding='utf-8')
    step = workflow.split('      - name: Capture macOS generated project diagnostics\n', 1)[1]
    step = step.split('      - name:', 1)[0]
    source = step.split("<<'PY_DIAGNOSTICS'\n", 1)[1].split('          PY_DIAGNOSTICS', 1)[0]
    return step, textwrap.dedent(source)


class MacOSGeneratedProjectDiagnosticsTest(unittest.TestCase):
    def run_diagnostic(self, root, run):
        previous = Path.cwd()
        try:
            os.chdir(root)
            with mock.patch('subprocess.run', side_effect=run):
                exec(compile(diagnostic_source()[1], str(WORKFLOW), 'exec'), {})
            return (root / OUTPUT).read_text(encoding='utf-8')
        finally:
            os.chdir(previous)

    def test_failure_only_artifact_and_allowlisted_read_only_diff(self):
        step, _ = diagnostic_source()
        self.assertIn('if: failure()', step)
        self.assertIn('vityo-nightly/' + OUTPUT.as_posix(), WORKFLOW.read_text())
        actual_run = subprocess.run
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return actual_run(['git', '-C', str(root), *args], check=True, capture_output=True)
            git('init', '-q')
            for path in (*PATHS, 'unrelated-private.txt'):
                destination = root / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text('before\n')
            git('add', '.')
            git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'fixture')
            for path in PATHS:
                (root / path).write_text('generated\n')
            (root / 'unrelated-private.txt').write_text('DO_NOT_CAPTURE\n')
            before = git('diff').stdout
            calls = []
            def run(command, **kwargs):
                calls.append(command)
                if command[0] == 'git':
                    return actual_run(command, **kwargs)
                return subprocess.CompletedProcess(command, 0, b'1.16.2\n', b'PRIVATE_STDERR')
            report = self.run_diagnostic(root, run)
            self.assertIn('+generated', report)
            self.assertNotIn('DO_NOT_CAPTURE', report)
            self.assertNotIn('PRIVATE_STDERR', report)
            self.assertEqual(git('diff').stdout, before)
            self.assertEqual(calls[-1][-3:], ['--', *PATHS])
            self.assertIn('--no-ext-diff', calls[-1])
            self.assertIn('--no-textconv', calls[-1])

    def test_bounded_output_and_host_path_redaction(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = f'{root}/file /Users/fixture/file {Path.home()}/file\n'.encode() + b'x' * 70000
            def run(command, **kwargs):
                self.assertEqual(kwargs['timeout'], 30)
                return subprocess.CompletedProcess(command, 0, payload, b'PRIVATE_STDERR')
            report = self.run_diagnostic(root, run)
            self.assertNotIn(str(root), report)
            self.assertNotIn('/Users/fixture', report)
            self.assertNotIn(str(Path.home()), report)
            self.assertNotIn('PRIVATE_STDERR', report)
            self.assertIn('[truncated at 65536 bytes]', report)
            self.assertLess(len(report.encode()), 4 * 66000)

    def test_missing_or_timed_out_tools_do_not_hide_other_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def run(command, **kwargs):
                if command[0] == 'pod':
                    raise FileNotFoundError('/private/host/tool')
                if command[0] == 'xcodebuild':
                    raise subprocess.TimeoutExpired(command, 30, output=b'PRIVATE_OUTPUT')
                return subprocess.CompletedProcess(command, 0, b'diagnostic\n', b'')
            report = self.run_diagnostic(root, run)
            self.assertIn('CocoaPods (FileNotFoundError)', report)
            self.assertIn('Xcode (TimeoutExpired)', report)
            self.assertIn('generated metadata diff (exit 0)', report)
            self.assertNotIn('/private/host/tool', report)
            self.assertNotIn('PRIVATE_OUTPUT', report)


if __name__ == '__main__':
    unittest.main()
