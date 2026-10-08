"""Portable build/command plumbing tests; never invoke CMake or Win32 here."""
from __future__ import annotations

import importlib.util
import json
import os
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
        selector = patch.object(library, 'visual_studio_generator',
                                return_value=('Visual Studio 17 2022', r'C:\VS\2022'))
        selector.start()
        self.addCleanup(selector.stop)
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
             '-G', 'Visual Studio 17 2022', '-A', 'x64',
             r'-DCMAKE_GENERATOR_INSTANCE=C:\VS\2022'],
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


class VisualStudioSelectorTests(unittest.TestCase):
    @staticmethod
    def instance(major=18, path=r'C:\VS\18'):
        return {'installationVersion': f'{major}.1.23456.7', 'installationPath': path,
                'isComplete': True, 'isLaunchable': True}

    @staticmethod
    def capabilities(*majors):
        years = {16: 2019, 17: 2022, 18: 2026, 19: 2030}
        return {'generators': [{'name': f'Visual Studio {major} {years[major]}',
                                'platformSupport': True, 'supportedPlatforms': ['Win32', 'x64']}
                               for major in majors]}

    def test_installed_versions_use_advertised_generators_not_folder_names(self):
        for major in (16, 17, 18, 19):
            path = r'C:\Unrelated folder\Edition'
            with self.subTest(major=major):
                selected = library._select_visual_studio([self.instance(major, path)],
                                                        self.capabilities(major), path)
                self.assertEqual(selected, (self.capabilities(major)['generators'][0]['name'], path))

    def test_active_instance_case_and_slashes_are_honored_before_newest(self):
        old = self.instance(17, r'C:\Program Files\Visual Studio\2022')
        new = self.instance(18)
        self.assertEqual(library._select_visual_studio([new, old], self.capabilities(17, 18),
                         'c:/program files/visual studio/2022/'),
                         ('Visual Studio 17 2022', old['installationPath']))
        self.assertEqual(library._select_visual_studio([old, new], self.capabilities(17, 18),
                         None), ('Visual Studio 18 2026', new['installationPath']))

    def test_explicit_missing_or_unsupported_selection_cannot_fallback(self):
        instances = [self.instance(17, r'C:\VS\17'), self.instance()]
        for requested in (r'C:\VS\18', r'C:\Missing'):
            with self.subTest(requested=requested), self.assertRaises(ValueError):
                library._select_visual_studio(instances, self.capabilities(17), requested)
        self.assertEqual(library._select_visual_studio(instances, self.capabilities(17), None)[0],
                         'Visual Studio 17 2022')

    def test_capability_platform_contract_and_ambiguity(self):
        capabilities = self.capabilities(18)
        del capabilities['generators'][0]['supportedPlatforms']
        self.assertEqual(library._select_visual_studio([self.instance()], capabilities, None)[0],
                         'Visual Studio 18 2026')
        for override in ({'supportedPlatforms': ['ARM64']}, {'supportedPlatforms': 'x64'},
                         {'platformSupport': False}, {'platformSupport': 1},
                         {'name': 'Ninja'}, {'name': 'Visual Studio not-a-version'}):
            capabilities = self.capabilities(18)
            capabilities['generators'][0].update(override)
            with self.subTest(override=override), self.assertRaises(ValueError):
                library._select_visual_studio([self.instance()], capabilities, None)
        with self.assertRaisesRegex(ValueError, 'ambiguous'):
            library._select_visual_studio([self.instance()], self.capabilities(18, 18), None)

    def test_invalid_incomplete_and_malformed_metadata_is_rejected(self):
        bad_instances = [None, {}, [], [None], [{}]]
        for field, value in [('installationVersion', 'not-a-version'), ('installationVersion', 18),
                             ('installationPath', 'relative'), ('isComplete', False),
                             ('isLaunchable', False)]:
            bad_instances.append([{**self.instance(), field: value}])
        for bad in bad_instances:
            with self.subTest(instances=bad), self.assertRaises(ValueError):
                library._select_visual_studio(bad, self.capabilities(18), None)
        for bad in (None, [], {}, {'generators': None}, {'generators': [None]}):
            with self.subTest(capabilities=bad), self.assertRaises(ValueError):
                library._select_visual_studio([self.instance()], bad, None)

    def test_queries_use_installed_vswhere_component_filter_and_cmake_capabilities(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            vswhere = root / 'Microsoft Visual Studio/Installer/vswhere.exe'
            vswhere.parent.mkdir(parents=True)
            vswhere.touch()
            responses = [subprocess.CompletedProcess([], 0, json.dumps([self.instance()])),
                         subprocess.CompletedProcess([], 0, json.dumps(self.capabilities(18)))]
            with patch.dict(os.environ, {'ProgramFiles(x86)': str(root),
                                         'VSINSTALLDIR': r'C:\VS\18'}, clear=True), \
                 patch.object(library.subprocess, 'run', side_effect=responses) as run:
                self.assertEqual(library.visual_studio_generator('cmake.exe', root),
                                 ('Visual Studio 18 2026', r'C:\VS\18'))
            commands = [call.args[0] for call in run.call_args_list]
            self.assertEqual(commands[1], ['cmake.exe', '-E', 'capabilities'])
            self.assertEqual(commands[0][0], str(vswhere))
            self.assertIn('Microsoft.VisualStudio.Component.VC.Tools.x86.x64', commands[0])
            self.assertNotIn('-latest', commands[0])
            self.assertIn('-utf8', commands[0])
            for call in run.call_args_list:
                self.assertEqual(call.kwargs['timeout'], 15)
                self.assertEqual(call.kwargs['encoding'], 'utf-8-sig')
                self.assertTrue(call.kwargs['check'])
                self.assertNotIn('shell', call.kwargs)

    def test_missing_vswhere_and_bad_probe_outputs_fail_before_build(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            for env in ({}, {'ProgramFiles': str(root)}):
                with patch.dict(os.environ, env, clear=True), \
                     patch.object(library.subprocess, 'run') as run, self.assertRaises(ValueError):
                    library.visual_studio_generator('cmake', root)
                run.assert_not_called()
            vswhere = root / 'Microsoft Visual Studio/Installer/vswhere.exe'
            vswhere.parent.mkdir(parents=True)
            vswhere.touch()
            for failure in (OSError('absent'), subprocess.CalledProcessError(2, 'query'),
                            subprocess.TimeoutExpired('query', 15),
                            subprocess.CompletedProcess([], 0, '{bad-json')):
                for position in (0, 1):
                    good = subprocess.CompletedProcess([], 0, json.dumps([self.instance()]))
                    with self.subTest(position=position, failure=failure), \
                         patch.dict(os.environ, {'ProgramFiles': str(root)}, clear=True), \
                         patch.object(library.subprocess, 'run', side_effect=[good]*position + [failure]), \
                         self.assertRaisesRegex(ValueError, 'discovery failed'):
                        library.visual_studio_generator('cmake', root)

    def test_cache_must_match_generator_instance_and_x64_before_reconfigure(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = root / 'products/vityo_app/native/windows_pipe'
            source.mkdir(parents=True)
            (source / 'CMakeLists.txt').touch()
            dll = library.library_path(root)
            dll.parent.mkdir(parents=True)
            dll.touch()
            cache = dll.parent.parent / 'CMakeCache.txt'
            valid = ('CMAKE_GENERATOR:INTERNAL=Visual Studio 18 2026\n'
                     'CMAKE_GENERATOR_PLATFORM:INTERNAL=x64\n'
                     'CMAKE_GENERATOR_INSTANCE:INTERNAL=C:\\VS\\18\n')
            for contents in (valid, valid.replace('18 2026', '17 2022'),
                             valid.replace('x64', 'ARM64'), valid.replace('C:\\VS\\18', 'C:\\other'), ''):
                cache.write_text(contents)
                with patch.object(library.sys, 'platform', 'win32'), \
                     patch.object(library.shutil, 'which', return_value='cmake'), \
                     patch.object(library, 'visual_studio_generator',
                                  return_value=('Visual Studio 18 2026', r'C:\VS\18')), \
                     patch.object(library.subprocess, 'run') as run:
                    if contents == valid:
                        self.assertEqual(library.build_library(root), dll)
                        self.assertEqual(run.call_count, 2)
                    else:
                        with self.assertRaisesRegex(ValueError, 'fresh build directory'):
                            library.build_library(root)
                        run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
