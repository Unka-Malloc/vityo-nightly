import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/environment/environment.dart';
import 'package:vityo_app/src/view_ide/toolchain/toolchain.dart';

import 'support/vityod_test_harness.dart';

void main() {
  setUpAll(() async {
    if (VityodTestHarness.isSupported) {
      _harnessInstance = await VityodTestHarness.start(
        clientId: 'lspd-discovery-test',
      );
    }
  });

  tearDownAll(() => _harnessInstance?.close());

  test(
    'styio_lspd is discovered next to the styio CLI without replacing it',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_lspd_discovery_test_',
      );
      addTearDown(() => tempRoot.delete(recursive: true));
      final managers = await _managers(tempRoot);
      final styioPath = managers.fileSystem.joinPath(<String>[
        tempRoot.path,
        'styio',
      ]);
      final lspdPath = managers.fileSystem.joinPath(<String>[
        tempRoot.path,
        'styio_lspd',
      ]);
      await _makeExecutable(managers, styioPath);
      await _makeExecutable(managers, lspdPath);

      final catalog = await createPlatformStyioLanguageToolchainCatalog(
        platformManagers: managers,
        candidatePaths: <String>[styioPath],
      );

      final active = catalog.active(ToolchainKind.languageService);
      final lspDaemon = catalog.lookup(styioLspDaemonToolchainId);
      expect(active, isNotNull);
      expect(active!.executablePath, styioPath);
      expect(lspDaemon, isNotNull);
      expect(lspDaemon!.executablePath, lspdPath);
      expect(lspDaemon.metadata['transport'], 'lsp-stdio');
    },
    skip: Platform.isWindows ? 'POSIX discovery fixture.' : false,
  );

  test(
    'a standalone styio_lspd is registered but never activated as the CLI',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_lspd_only_test_',
      );
      addTearDown(() => tempRoot.delete(recursive: true));
      final managers = await _managers(tempRoot);
      final lspdPath = managers.fileSystem.joinPath(<String>[
        tempRoot.path,
        'styio_lspd',
      ]);
      await _makeExecutable(managers, lspdPath);

      final missingStyioPath = managers.fileSystem.joinPath(<String>[
        tempRoot.path,
        'styio',
      ]);
      final catalog = await createPlatformStyioLanguageToolchainCatalog(
        platformManagers: managers,
        candidatePaths: <String>[missingStyioPath],
      );

      expect(
        catalog.active(ToolchainKind.languageService),
        isNull,
        reason: 'styio_lspd must not be activated as the styio CLI',
      );
      expect(
        catalog.lookup(styioLspDaemonToolchainId)?.executablePath,
        lspdPath,
      );
    },
    skip: Platform.isWindows ? 'POSIX discovery fixture.' : false,
  );

  test(
    'VITYO_STYIO_LSPD_BIN overrides styio_lspd discovery',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_lspd_override_test_',
      );
      addTearDown(() => tempRoot.delete(recursive: true));
      final managers = await _managers(tempRoot);
      final overridePath = managers.fileSystem.joinPath(<String>[
        tempRoot.path,
        'custom',
        'styio_lspd',
      ]);
      await managers.fileSystem.writeText(overridePath, '#!/bin/sh\n');
      await managers.fileSystem.setExecutable(overridePath);

      final catalog = await createPlatformStyioLanguageToolchainCatalog(
        platformManagers: managers,
        environment: <String, String>{'VITYO_STYIO_LSPD_BIN': overridePath},
        candidatePaths: const <String>[],
      );

      expect(
        catalog.lookup(styioLspDaemonToolchainId)?.executablePath,
        overridePath,
      );
    },
    skip: Platform.isWindows ? 'POSIX discovery fixture.' : false,
  );

  test(
    'VITYO_STYIO_BIN is preferred over the candidate paths',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_styio_override_test_',
      );
      addTearDown(() => tempRoot.delete(recursive: true));
      final managers = await _managers(tempRoot);
      final overridePath = managers.fileSystem.joinPath(<String>[
        tempRoot.path,
        'custom',
        'styio',
      ]);
      final candidatePath = managers.fileSystem.joinPath(<String>[
        tempRoot.path,
        'styio',
      ]);
      await _makeExecutable(managers, overridePath);
      await _makeExecutable(managers, candidatePath);

      final catalog = await createPlatformStyioLanguageToolchainCatalog(
        platformManagers: managers,
        environment: <String, String>{'VITYO_STYIO_BIN': overridePath},
        candidatePaths: <String>[candidatePath],
      );

      expect(
        catalog.active(ToolchainKind.languageService)?.executablePath,
        overridePath,
      );
      expect(overridePath, isNot(candidatePath));
    },
    skip: Platform.isWindows ? 'POSIX discovery fixture.' : false,
  );

  test(
    'an app-bundled styio and styio_lspd are discovered without an override',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_lspd_bundled_test_',
      );
      addTearDown(() => tempRoot.delete(recursive: true));
      final managers = await _managers(tempRoot);
      final appExecutable = _fakeAppExecutablePath(tempRoot);
      final bundledStyio = _bundledComponentPath(appExecutable, 'styio');
      final bundledLspd = _bundledComponentPath(appExecutable, 'styio_lspd');
      await _makeExecutable(managers, bundledStyio);
      await _makeExecutable(managers, bundledLspd);

      final catalog = await createPlatformStyioLanguageToolchainCatalog(
        platformManagers: managers,
        candidatePaths: const <String>[],
        bundledExecutablePath: appExecutable,
      );

      expect(
        catalog.active(ToolchainKind.languageService)?.executablePath,
        bundledStyio,
      );
      expect(
        catalog.lookup(styioLspDaemonToolchainId)?.executablePath,
        bundledLspd,
      );
    },
    skip: Platform.isWindows ? 'POSIX discovery fixture.' : false,
  );

  test(
    'VITYO_STYIO_BIN wins over the app-bundled styio',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_styio_bundled_override_test_',
      );
      addTearDown(() => tempRoot.delete(recursive: true));
      final managers = await _managers(tempRoot);
      final appExecutable = _fakeAppExecutablePath(tempRoot);
      await _makeExecutable(
        managers,
        _bundledComponentPath(appExecutable, 'styio'),
      );
      final overridePath = managers.fileSystem.joinPath(<String>[
        tempRoot.path,
        'custom',
        'styio',
      ]);
      await _makeExecutable(managers, overridePath);

      final catalog = await createPlatformStyioLanguageToolchainCatalog(
        platformManagers: managers,
        environment: <String, String>{'VITYO_STYIO_BIN': overridePath},
        candidatePaths: const <String>[],
        bundledExecutablePath: appExecutable,
      );

      expect(
        catalog.active(ToolchainKind.languageService)?.executablePath,
        overridePath,
      );
    },
    skip: Platform.isWindows ? 'POSIX discovery fixture.' : false,
  );

  test(
    'an app-bundled styio wins over candidate paths',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_styio_bundled_order_test_',
      );
      addTearDown(() => tempRoot.delete(recursive: true));
      final managers = await _managers(tempRoot);
      final appExecutable = _fakeAppExecutablePath(tempRoot);
      final bundledStyio = _bundledComponentPath(appExecutable, 'styio');
      await _makeExecutable(managers, bundledStyio);
      final candidatePath = managers.fileSystem.joinPath(<String>[
        tempRoot.path,
        'system',
        'styio',
      ]);
      await _makeExecutable(managers, candidatePath);

      final catalog = await createPlatformStyioLanguageToolchainCatalog(
        platformManagers: managers,
        candidatePaths: <String>[candidatePath],
        bundledExecutablePath: appExecutable,
      );

      final active = catalog.active(ToolchainKind.languageService);
      expect(active?.executablePath, bundledStyio);
      expect(active?.executablePath, isNot(candidatePath));
    },
    skip: Platform.isWindows ? 'POSIX discovery fixture.' : false,
  );

  for (final exists in <bool>[false, true]) {
    test('a ${exists ? 'non-executable' : 'missing'} explicit Styio selection '
        'blocks bundled and system fallback', () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_styio_invalid_selection_test_',
      );
      addTearDown(() => tempRoot.delete(recursive: true));
      final managers = await _managers(tempRoot);
      final appExecutable = _fakeAppExecutablePath(tempRoot);
      final selectedPath = '${tempRoot.path}/selected/styio';
      final systemPath = '${tempRoot.path}/system/styio';
      await _makeExecutable(
        managers,
        _bundledComponentPath(appExecutable, 'styio'),
      );
      await _makeExecutable(managers, systemPath);
      if (exists) {
        await managers.fileSystem.writeText(selectedPath, '#!/bin/sh\n');
      }

      final catalog = await createPlatformStyioLanguageToolchainCatalog(
        platformManagers: managers,
        environment: <String, String>{'VITYO_STYIO_BIN': selectedPath},
        candidatePaths: <String>[systemPath],
        bundledExecutablePath: appExecutable,
      );

      expect(catalog.active(ToolchainKind.languageService), isNull);
      expect(catalog.lookup('local-styio-language-service'), isNull);
    }, skip: Platform.isWindows ? 'POSIX discovery fixture.' : false);
  }

  test(
    'a missing explicit LSPD selection blocks bundled and adjacent fallback',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_lspd_invalid_selection_test_',
      );
      addTearDown(() => tempRoot.delete(recursive: true));
      final managers = await _managers(tempRoot);
      final appExecutable = _fakeAppExecutablePath(tempRoot);
      final styioPath = '${tempRoot.path}/system/styio';
      await _makeExecutable(managers, styioPath);
      await _makeExecutable(managers, '${tempRoot.path}/system/styio_lspd');
      await _makeExecutable(
        managers,
        _bundledComponentPath(appExecutable, 'styio_lspd'),
      );

      final catalog = await createPlatformStyioLanguageToolchainCatalog(
        platformManagers: managers,
        environment: <String, String>{
          'VITYO_STYIO_LSPD_BIN': '${tempRoot.path}/missing/styio_lspd',
        },
        candidatePaths: <String>[styioPath],
        bundledExecutablePath: appExecutable,
      );

      expect(
        catalog.active(ToolchainKind.languageService)?.executablePath,
        styioPath,
      );
      expect(catalog.lookup(styioLspDaemonToolchainId), isNull);
    },
    skip: Platform.isWindows ? 'POSIX discovery fixture.' : false,
  );

  test(
    'empty Styio and LSPD overrides permit bundled discovery',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'vityo_styio_empty_selection_test_',
      );
      addTearDown(() => tempRoot.delete(recursive: true));
      final managers = await _managers(tempRoot);
      final appExecutable = _fakeAppExecutablePath(tempRoot);
      final styioPath = _bundledComponentPath(appExecutable, 'styio');
      final lspdPath = _bundledComponentPath(appExecutable, 'styio_lspd');
      await _makeExecutable(managers, styioPath);
      await _makeExecutable(managers, lspdPath);

      final catalog = await createPlatformStyioLanguageToolchainCatalog(
        platformManagers: managers,
        environment: const <String, String>{
          'VITYO_STYIO_BIN': '',
          'VITYO_STYIO_LSPD_BIN': '',
        },
        candidatePaths: const <String>[],
        bundledExecutablePath: appExecutable,
      );

      expect(
        catalog.active(ToolchainKind.languageService)?.executablePath,
        styioPath,
      );
      expect(
        catalog.lookup(styioLspDaemonToolchainId)?.executablePath,
        lspdPath,
      );
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
    targetId: 'lspd-discovery',
    fileSystem: FileSystemFacts.linuxDebianArm(targetId: 'lspd-discovery'),
    shell: ShellFacts.linuxDebianArm(
      targetId: 'lspd-discovery',
      defaultShellPath: '/bin/sh',
    ),
  );
  return createPlatformManagerBundle(
    platformContext: context,
    vityodClient: harness.client,
    workspaceRoot: root.path,
  );
}

Future<void> _makeExecutable(
  PlatformManagerBundle managers,
  String path,
) async {
  await managers.fileSystem.writeText(path, '#!/bin/sh\n');
  await managers.fileSystem.setExecutable(path);
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
