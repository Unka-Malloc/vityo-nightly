"""Portable build/command plumbing tests; never invoke CMake or Win32 here."""
from __future__ import annotations

import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT / 'scripts') not in sys.path:
    sys.path.insert(0, str(ROOT / 'scripts'))
import windows_pipe_library as library


def load_script(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / name)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class WindowsPipeLibraryTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.source = self.root / 'products/vityo_app/native/windows_pipe'
        self.source.mkdir(parents=True)
        (self.source / 'CMakeLists.txt').touch()
        self.dll = library.library_path(self.root)
        self.dll.parent.mkdir(parents=True)
        self.dll.write_bytes(b'mocked DLL')
        library._prepared_library.cache_clear()
        self.addCleanup(library._prepared_library.cache_clear)

    def test_fixed_release_path_and_compile_define_preserve_spaces(self):
        self.assertEqual(self.dll, self.root / 'build/windows-pipe-native/Release/vityo_windows_pipe.dll')
        spaced = self.root / 'spaces in directory' / library.LIBRARY_NAME
        spaced.parent.mkdir()
        spaced.write_bytes(b'fixture')
        self.assertEqual(library.dart_define(spaced), f'-DVITYO_WINDOWS_PIPE_LIBRARY={spaced}')

    def test_missing_relative_or_wrong_named_libraries_fail_closed(self):
        for value in (Path(library.LIBRARY_NAME), self.root / library.LIBRARY_NAME,
                      self.root / 'wrong.dll', self.root):
            with self.subTest(value=value), self.assertRaises(ValueError):
                library.require_library(value)
        self.assertEqual(library.require_library(self.dll), self.dll)

    def test_non_windows_build_is_not_a_native_success(self):
        with patch.object(library.sys, 'platform', 'linux'), \
             patch.object(library.subprocess, 'run') as run, \
             self.assertRaisesRegex(ValueError, 'native Windows'):
            library.build_library(self.root)
        run.assert_not_called()

    def test_source_and_cmake_are_required_before_build(self):
        for missing in ('source', 'cmake'):
            with self.subTest(missing=missing), \
                 patch.object(library.sys, 'platform', 'win32'), \
                 patch.object(library.shutil, 'which', return_value=None), \
                 patch.object(library.subprocess, 'run') as run:
                root = self.root / 'absent' if missing == 'source' else self.root
                with self.assertRaisesRegex(ValueError, 'source|CMake'):
                    library.build_library(root)
                run.assert_not_called()

    def test_build_is_explicit_msvc_x64_release_bounded_and_never_installs(self):
        with patch.object(library.sys, 'platform', 'win32'), \
             patch.object(library.shutil, 'which', return_value='verified-cmake.exe'), \
             patch.object(library.subprocess, 'run') as run:
            self.assertEqual(library.build_library(self.root), self.dll)
        build = self.root / 'build/windows-pipe-native'
        self.assertEqual([call.args[0] for call in run.call_args_list], [
            ['verified-cmake.exe', '-S', str(self.source), '-B', str(build),
             '-G', 'Visual Studio 17 2022', '-A', 'x64'],
            ['verified-cmake.exe', '--build', str(build), '--config', 'Release',
             '--target', 'vityo_windows_pipe'],
        ])
        for call in run.call_args_list:
            self.assertEqual(call.kwargs, {'cwd': self.root, 'check': True, 'timeout': 120})
            self.assertNotIn('--install', call.args[0])
            self.assertNotIn('shell', call.kwargs)

    def test_configure_build_timeout_and_missing_output_cannot_pass(self):
        for failing_call in (0, 1):
            for failure in (OSError('missing'), subprocess.CalledProcessError(7, 'cmake'),
                            subprocess.TimeoutExpired('cmake', 120)):
                with self.subTest(call=failing_call, error=type(failure).__name__), \
                     patch.object(library.sys, 'platform', 'win32'), \
                     patch.object(library.shutil, 'which', return_value='cmake'), \
                     patch.object(library.subprocess, 'run', side_effect=[None] * failing_call + [failure]), \
                     self.assertRaisesRegex(ValueError, 'build failed'):
                    library.build_library(self.root)
        self.dll.unlink()
        with patch.object(library.sys, 'platform', 'win32'), \
             patch.object(library.shutil, 'which', return_value='cmake'), \
             patch.object(library.subprocess, 'run'), \
             self.assertRaisesRegex(ValueError, 'DLL is missing'):
            library.build_library(self.root)

    def test_flutter_and_dart_commands_share_one_prepared_absolute_library(self):
        commands = [
            ['C:\\sdk\\flutter.bat', 'test', '--coverage'],
            ['flutter', 'test', '--no-pub', 'test/mcp_host'],
            ['dart', '--packages=app/.dart_tool/package_config.json', 'tool/probe.dart'],
            ['dart', 'tool/probe.dart'],
        ]
        with patch.object(library.sys, 'platform', 'win32'), \
             patch.object(library, 'build_library', return_value=self.dll) as build:
            for original in commands:
                command = library.test_command(original, root=self.root)
                flutter = 'flutter' in original[0]
                index = 2 if flutter else 1
                flag = '--dart-define=' if flutter else '-D'
                self.assertEqual(command[index], f'{flag}VITYO_WINDOWS_PIPE_LIBRARY={self.dll}')
                self.assertEqual(command[:index] + command[index + 1:], original)
            build.assert_called_once_with(self.root)

    def test_non_windows_and_non_execution_commands_do_not_build_or_change(self):
        commands = [[], ['flutter'], ['flutter', 'analyze'], ['flutter', 'build', 'windows'],
                    ['dart', 'analyze'], ['dart', 'test', 'test/agent_client'],
                    ['dart', 'run', 'tool/probe.dart'], ['dart', 'pub', 'get'], ['python', 'probe.py']]
        with patch.object(library, 'build_library') as build:
            for platform in ('linux', 'darwin', 'win32'):
                with patch.object(library.sys, 'platform', platform):
                    for command in commands:
                        self.assertEqual(library.test_command(command, root=self.root), command)
            with patch.object(library.sys, 'platform', 'linux'):
                self.assertEqual(library.test_command(['flutter', 'test'], root=self.root), ['flutter', 'test'])
            build.assert_not_called()

    def test_cached_library_is_revalidated_before_each_command(self):
        with patch.object(library.sys, 'platform', 'win32'), \
             patch.object(library, 'build_library', return_value=self.dll):
            library.test_command(['flutter', 'test'], root=self.root)
            self.dll.unlink()
            with self.assertRaisesRegex(ValueError, 'DLL is missing'):
                library.test_command(['flutter', 'test'], root=self.root)

    def test_cli_reports_actual_library_and_appends_github_output(self):
        script = load_script('build-windows-pipe-library.py')
        output = self.root / 'github-output'
        output.write_text('existing=value\n')
        stream = io.StringIO()
        with patch.object(script, 'build_library', return_value=self.dll) as build, \
             patch('sys.stdout', stream):
            self.assertEqual(script.main(['--github-output', str(output)]), 0)
            self.assertEqual(script.main([]), 0)
        self.assertEqual(output.read_text(), f'existing=value\nlibrary={self.dll}\n')
        self.assertIn(str(self.dll), stream.getvalue())
        self.assertEqual(build.call_count, 2)
        with patch.object(script, 'build_library', side_effect=ValueError('failed')), \
             patch('sys.stderr', io.StringIO()):
            self.assertEqual(script.main(['--github-output', str(output)]), 2)
        self.assertEqual(output.read_text(), f'existing=value\nlibrary={self.dll}\n')

    def test_quality_runner_wires_app_execution_without_touching_analysis_or_packages(self):
        script = load_script('vityo_quality.py')
        app = script.ROOT / 'products/vityo_app'
        with patch.object(library.sys, 'platform', 'win32'), \
             patch.object(library, 'build_library', return_value=self.dll) as build, \
             patch.object(script.subprocess, 'run') as run, patch('sys.stdout', io.StringIO()):
            script.run(['flutter', 'test', '--no-pub'], app)
            self.assertEqual(run.call_args.args[0][2], f'--dart-define=VITYO_WINDOWS_PIPE_LIBRARY={self.dll}')
            script.run(['dart', '--packages=.dart_tool/package_config.json', 'integration_test/mcp_host_test.dart'], app)
            self.assertEqual(run.call_args.args[0][1], library.dart_define(self.dll))
            script.run(['flutter', 'analyze'], app)
            self.assertEqual(run.call_args.args[0], ['flutter', 'analyze'])
            script.run(['dart', 'test'], script.ROOT / 'packages/vityo_daemon_protocol')
            self.assertEqual(run.call_args.args[0], ['dart', 'test'])
            build.assert_called_once_with(script.ROOT)

    def test_quality_runner_reports_failed_build_without_starting_tests(self):
        script = load_script('vityo_quality.py')
        with patch.object(script, 'test_command', side_effect=ValueError('build failed')), \
             patch.object(script.subprocess, 'run') as run, patch('sys.stderr', io.StringIO()):
            self.assertEqual(script.run(['flutter', 'test'], script.ROOT / 'products/vityo_app'), 2)
        run.assert_not_called()

    def test_coverage_runner_builds_and_wires_the_full_suite_or_fails_closed(self):
        script = load_script('project-coverage-gate.py')
        for manifest in ('products/vityo_app/native/vityod/Cargo.toml',
                         'products/vityo_coding_agent/Cargo.toml'):
            path = self.root / manifest
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        for failure in (False, True):
            with self.subTest(failure=failure):
                library._prepared_library.cache_clear()
                with patch.object(script, 'ROOT', self.root), \
                     patch.object(script, 'resolve_flutter_binary', return_value='flutter.bat'), \
                     patch.object(script, 'run_command', return_value=0) as run, \
                     patch.object(library.sys, 'platform', 'win32'), \
                     patch.object(library, 'build_library',
                                  side_effect=ValueError('build failed') if failure else None,
                                  return_value=self.dll) as build, patch('sys.stderr', io.StringIO()):
                    result = script.run_flutter_gate(fail_under=95,
                        flutter_dir=Path('products/vityo_app'), flutter_bin=None, report=False)
                self.assertEqual(result, 2 if failure else 0)
                build.assert_called_once_with(self.root)
                self.assertEqual(run.call_count, 2 if failure else 3)
                if not failure:
                    self.assertEqual(run.call_args.args[0], ['flutter.bat', 'test',
                        f'--dart-define=VITYO_WINDOWS_PIPE_LIBRARY={self.dll}', '--coverage'])

    def test_harness_requires_a_library_before_any_watchdog_case(self):
        script = load_script('test-windows-dart-pipe.py')
        config = self.root / 'products/vityo_app/.dart_tool/package_config.json'
        config.parent.mkdir(parents=True)
        config.write_text('{}')
        self.dll.unlink()
        from types import SimpleNamespace
        import json
        with patch.object(script, 'ROOT', self.root), \
             patch.object(script, 'os', SimpleNamespace(name='nt')), \
             patch.object(script, 'resolve_dart', return_value='dart.exe'), \
             patch.object(script, 'supervise') as supervise, patch('sys.stdout', io.StringIO()):
            output = self.root / 'report.json'
            self.assertEqual(script.main(['--output', str(output)]), 2)
        self.assertEqual(json.loads(output.read_text())['status'], 'not-run')
        supervise.assert_not_called()

    def test_pty_runner_wires_both_real_pipe_consumers(self):
        script = load_script('run-native-pty-matrix.py')
        app = self.root / 'products/vityo_app'
        with patch.object(library.sys, 'platform', 'win32'), \
             patch.object(library, 'build_library', return_value=self.dll) as build, \
             patch.object(script.shutil, 'which', return_value='flutter.bat'), \
             patch.object(script.subprocess, 'run') as run:
            script.run_matrix(flutter='flutter', app_root=app)
        self.assertEqual(run.call_count, 2)
        for call in run.call_args_list:
            self.assertEqual(call.args[0][2], f'--dart-define=VITYO_WINDOWS_PIPE_LIBRARY={self.dll}')
        build.assert_called_once_with(self.root)

    def test_ci_builds_before_watchdog_and_reuses_output_without_weakening_gates(self):
        workflow = (ROOT / '.github/workflows/local-ci-gate.yml').read_text()
        self.assertLess(workflow.index('scripts/build-windows-pipe-library.py'),
                        workflow.index('scripts/test-windows-dart-pipe.py'))
        self.assertIn('--library "${{ steps.windows_pipe_library.outputs.library }}"', workflow)
        self.assertIn('scripts/vityo.py deliver --mode ci --platform windows', workflow)
        self.assertIn('timeout-minutes: 3', workflow.split('Run bounded real Dart Windows pipe regressions', 1)[1].split('Upload real Dart', 1)[0])
        for script in ('project-coverage-gate.py', 'ecosystem-product-gate.py'):
            source = (ROOT / 'scripts' / script).read_text()
            self.assertIn('test_command([', source)
            self.assertIn('root=ROOT)', source)


if __name__ == '__main__':
    unittest.main()
