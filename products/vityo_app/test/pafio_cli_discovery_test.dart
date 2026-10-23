import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/bundled_toolchain_candidates.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/pafio_cli_discovery.dart';
import 'package:vityo_app/src/view_ide/environment/environment.dart';

import 'support/vityod_test_harness.dart';

void main() {
  setUpAll(() async {
    if (VityodTestHarness.isSupported) {
      _harnessInstance = await VityodTestHarness.start(
        clientId: 'pafio-discovery-test',
      );
    }
  });

  tearDownAll(() => _harnessInstance?.close());

  test(
    'VITYO_PAFIO_BIN wins when the fake binary answers --version',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_pafio_discovery_test_',
      );
      addTearDown(() => tempRoot.delete(recursive: true));
      final managers = await _managers(tempRoot);
      final overridePath = managers.fileSystem.joinPath(<String>[
        tempRoot.path,
        'custom',
        'pafio',
      ]);
      await managers.fileSystem.writeText(overridePath, '#!/bin/sh\nexit 0\n');
      await managers.fileSystem.setExecutable(overridePath);

      final resolved = await resolvePafioBinary(
        managers,
        environment: <String, String>{'VITYO_PAFIO_BIN': overridePath},
      );

      expect(resolved, overridePath);
    },
    skip: Platform.isWindows ? 'POSIX discovery fixture.' : false,
  );

  test(
    'a non-zero --version probe rejects the override',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_pafio_discovery_fallback_test_',
      );
      addTearDown(() => tempRoot.delete(recursive: true));
      final managers = await _managers(tempRoot);
      final overridePath = managers.fileSystem.joinPath(<String>[
        tempRoot.path,
        'custom',
        'pafio',
      ]);
      // Answers `--version` with a non-zero exit, so discovery must reject it.
      await managers.fileSystem.writeText(overridePath, '#!/bin/sh\nexit 3\n');
      await managers.fileSystem.setExecutable(overridePath);

      final resolved = await resolvePafioBinary(
        managers,
        environment: <String, String>{'VITYO_PAFIO_BIN': overridePath},
      );

      expect(resolved, isNot(overridePath));
    },
    skip: Platform.isWindows ? 'POSIX discovery fixture.' : false,
  );

  test(
    'an app-bundled pafio is discovered without an env override',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_pafio_bundled_test_',
      );
      addTearDown(() => tempRoot.delete(recursive: true));
      final managers = await _managers(tempRoot);
      final appExecutable = _fakeAppExecutablePath(tempRoot);
      final bundledPath = _bundledComponentPath(appExecutable, 'pafio');
      await _makeBundledPafio(managers, appExecutable);

      final resolved = await resolvePafioBinary(
        managers,
        bundledExecutablePath: appExecutable,
      );

      expect(resolved, bundledPath);
    },
    skip: Platform.isWindows ? 'POSIX discovery fixture.' : false,
  );

  test(
    'VITYO_PAFIO_BIN wins over the app-bundled component',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_pafio_bundled_override_test_',
      );
      addTearDown(() => tempRoot.delete(recursive: true));
      final managers = await _managers(tempRoot);
      final appExecutable = _fakeAppExecutablePath(tempRoot);
      await _makeBundledPafio(managers, appExecutable);
      final overridePath = managers.fileSystem.joinPath(<String>[
        tempRoot.path,
        'custom',
        'pafio',
      ]);
      await _makeVersionBinary(managers, overridePath);

      final resolved = await resolvePafioBinary(
        managers,
        environment: <String, String>{'VITYO_PAFIO_BIN': overridePath},
        bundledExecutablePath: appExecutable,
      );

      expect(resolved, overridePath);
    },
    skip: Platform.isWindows ? 'POSIX discovery fixture.' : false,
  );

  test(
    'an app-bundled pafio wins over system candidate paths',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_pafio_bundled_order_test_',
      );
      addTearDown(() => tempRoot.delete(recursive: true));
      final managers = await _managers(tempRoot);
      final appExecutable = _fakeAppExecutablePath(tempRoot);
      final bundledPath = _bundledComponentPath(appExecutable, 'pafio');
      await _makeBundledPafio(managers, appExecutable);
      final systemPath = managers.fileSystem.joinPath(<String>[
        tempRoot.path,
        'system',
        'pafio',
      ]);
      await _makeVersionBinary(managers, systemPath);

      final resolved = await resolvePafioBinary(
        managers,
        bundledExecutablePath: appExecutable,
        systemCandidatePaths: <String>[systemPath],
      );

      expect(resolved, bundledPath);
      expect(resolved, isNot(systemPath));
    },
    skip: Platform.isWindows ? 'POSIX discovery fixture.' : false,
  );

  test(
    'an extra (user-persisted) candidate is probed after the env override and '
    'before the bundled component',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_pafio_extra_order_test_',
      );
      addTearDown(() => tempRoot.delete(recursive: true));
      final managers = await _managers(tempRoot);
      final appExecutable = _fakeAppExecutablePath(tempRoot);
      final bundledPath = _bundledComponentPath(appExecutable, 'pafio');
      final extraPath = managers.fileSystem.joinPath(<String>[
        tempRoot.path,
        'persisted',
        'pafio',
      ]);
      final systemPath = managers.fileSystem.joinPath(<String>[
        tempRoot.path,
        'system',
        'pafio',
      ]);
      final envPath = managers.fileSystem.joinPath(<String>[
        tempRoot.path,
        'env',
        'pafio',
      ]);
      await _makeBundledPafio(managers, appExecutable);
      await _makeVersionBinary(managers, extraPath);
      await _makeVersionBinary(managers, systemPath);
      await _makeVersionBinary(managers, envPath);

      final withEnv = await resolvePafioBinary(
        managers,
        environment: <String, String>{'VITYO_PAFIO_BIN': envPath},
        bundledExecutablePath: appExecutable,
        systemCandidatePaths: <String>[systemPath],
        extraCandidatePaths: <String>[extraPath],
      );
      expect(withEnv, envPath, reason: 'the env override still outranks all');

      final withoutEnv = await resolvePafioBinary(
        managers,
        bundledExecutablePath: appExecutable,
        systemCandidatePaths: <String>[systemPath],
        extraCandidatePaths: <String>[extraPath],
      );
      expect(withoutEnv, extraPath);
      expect(withoutEnv, isNot(bundledPath));
      expect(withoutEnv, isNot(systemPath));
    },
    skip: Platform.isWindows ? 'POSIX discovery fixture.' : false,
  );

  test(
    'a persisted candidate that fails --version falls through to the bundled '
    'component',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_pafio_extra_fallthrough_test_',
      );
      addTearDown(() => tempRoot.delete(recursive: true));
      final managers = await _managers(tempRoot);
      final appExecutable = _fakeAppExecutablePath(tempRoot);
      final bundledPath = _bundledComponentPath(appExecutable, 'pafio');
      await _makeBundledPafio(managers, appExecutable);
      final brokenPath = managers.fileSystem.joinPath(<String>[
        tempRoot.path,
        'persisted',
        'pafio',
      ]);
      await managers.fileSystem.writeText(brokenPath, '#!/bin/sh\nexit 3\n');
      await managers.fileSystem.setExecutable(brokenPath);

      final resolved = await resolvePafioBinary(
        managers,
        bundledExecutablePath: appExecutable,
        systemCandidatePaths: const <String>[],
        extraCandidatePaths: <String>[brokenPath],
      );

      expect(resolved, bundledPath);
    },
    skip: Platform.isWindows ? 'POSIX discovery fixture.' : false,
  );

  test(
    'the bundled executable path comes from pafio-component.json',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_pafio_manifest_path_test_',
      );
      addTearDown(() => tempRoot.delete(recursive: true));
      final managers = await _managers(tempRoot);
      final appExecutable = _fakeAppExecutablePath(tempRoot);
      final packageRoot = bundledApplicationPackageRoot(
        executablePath: appExecutable,
      )!;
      final relativePath = Platform.isMacOS
          ? 'Contents/Helpers/custom-pafio'
          : 'components/custom-pafio';
      final declaredPath = '$packageRoot/$relativePath';
      await _makeVersionBinary(managers, declaredPath);
      await _writePafioManifest(
        appExecutable,
        packageRelativePath: relativePath,
      );

      final resolved = await resolvePafioBinary(
        managers,
        bundledExecutablePath: appExecutable,
      );

      expect(resolved, declaredPath);
    },
    skip: Platform.isWindows ? 'POSIX discovery fixture.' : false,
  );

  test(
    'a conventional bundled path is ignored without its component manifest',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_pafio_manifest_required_test_',
      );
      addTearDown(() => tempRoot.delete(recursive: true));
      final managers = await _managers(tempRoot);
      final appExecutable = _fakeAppExecutablePath(tempRoot);
      final conventionalPath = _bundledComponentPath(appExecutable, 'pafio');
      final systemPath = '${tempRoot.path}/system/pafio';
      await _makeVersionBinary(managers, conventionalPath);
      await _makeVersionBinary(managers, systemPath);

      final resolved = await resolvePafioBinary(
        managers,
        bundledExecutablePath: appExecutable,
        systemCandidatePaths: <String>[systemPath],
      );

      expect(resolved, systemPath);
    },
    skip: Platform.isWindows ? 'POSIX discovery fixture.' : false,
  );
}

VityodTestHarness? _harnessInstance;

Future<PlatformManagerBundle> _managers(Directory root) async {
  final harness = _harnessInstance;
  if (harness == null) {
    throw StateError('vityod test harness is unavailable.');
  }
  final context = PlatformContextSnapshot.compose(
    targetId: 'pafio-discovery',
    fileSystem: FileSystemFacts.linuxDebianArm(targetId: 'pafio-discovery'),
    shell: ShellFacts.linuxDebianArm(
      targetId: 'pafio-discovery',
      defaultShellPath: '/bin/sh',
    ),
  );
  return createPlatformManagerBundle(
    platformContext: context,
    vityodClient: harness.client,
    workspaceRoot: root.path,
  );
}

/// A hermetic fake app executable path whose bundle layout mirrors the host
/// platform, so bundled candidates resolve inside [root].
String _fakeAppExecutablePath(Directory root) {
  if (Platform.isMacOS) {
    return '${root.path}/Vityo.app/Contents/MacOS/vityo';
  }
  return '${root.path}/Vityo/vityo';
}

String _bundledComponentPath(String appExecutable, String componentName) {
  final appDirectory = File(appExecutable).parent;
  if (Platform.isMacOS) {
    return '${appDirectory.parent.path}/Helpers/$componentName';
  }
  return '${appDirectory.path}/components/$componentName';
}

Future<void> _makeVersionBinary(
  PlatformManagerBundle managers,
  String path,
) async {
  await managers.fileSystem.writeText(path, '#!/bin/sh\nexit 0\n');
  await managers.fileSystem.setExecutable(path);
}

Future<String> _makeBundledPafio(
  PlatformManagerBundle managers,
  String appExecutable,
) async {
  final executablePath = _bundledComponentPath(appExecutable, 'pafio');
  final relativePath = Platform.isMacOS
      ? 'Contents/Helpers/pafio'
      : 'components/pafio';
  await _makeVersionBinary(managers, executablePath);
  await _writePafioManifest(appExecutable, packageRelativePath: relativePath);
  return executablePath;
}

Future<void> _writePafioManifest(
  String appExecutable, {
  required String packageRelativePath,
}) async {
  final manifestPath = bundledPafioComponentManifestPath(
    executablePath: appExecutable,
  )!;
  final file = File(manifestPath);
  await file.parent.create(recursive: true);
  await file.writeAsString(
    jsonEncode(<String, Object?>{
      'schema_version': 1,
      'component': 'pafio',
      'package_relative_path': packageRelativePath,
    }),
  );
}
