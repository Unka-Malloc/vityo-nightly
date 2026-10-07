import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/environment/environment.dart';
import 'package:vityo_app/src/view_ide/flow_hero/toolchain_candidates.dart';
import 'package:vityo_app/src/view_ide/flow_hero/toolchain_store.dart';

class _LinkFileSystem extends Fake implements FileSystemManager {
  final metadataChecks = <String>[];
  @override
  Future<FileSystemEntitySnapshot> stat(String path) async =>
      FileSystemEntitySnapshot(
        path: path,
        normalizedPath: path,
        type: path == '/homebrew/bin/styio' || path == '/broken/bin/styio'
            ? VityoFileSystemEntityType.link
            : path == '/directory/bin/styio'
            ? VityoFileSystemEntityType.directory
            : VityoFileSystemEntityType.notFound,
      );
  @override
  Future<bool> isExecutable(String path) async {
    metadataChecks.add(path);
    return path == '/homebrew/bin/styio';
  }
}

class _LinkManagers extends Fake implements PlatformManagerBundle {
  _LinkManagers(this.fileSystem);
  @override
  final FileSystemManager fileSystem;
  @override
  PlatformContextSnapshot get context => PlatformContextSnapshot.compose(
    targetId: 'link-test',
    fileSystem: FileSystemFacts.linuxDebianArm(),
    shell: ShellFacts.linuxDebianArm(defaultShellPath: '/bin/sh'),
  );
}

void main() {
  test(
    'offers executable links but rejects directory and broken-link candidates',
    () async {
      final fs = _LinkFileSystem();
      final found = await discoverFlowHeroToolchainCandidates(
        kind: FlowHeroToolchainKind.styio,
        platformManagers: _LinkManagers(fs),
        environment: const {'PATH': '/homebrew/bin:/broken/bin:/directory/bin'},
        bundledExecutablePath: '/app/vityo',
        operatingSystem: 'linux',
      );
      expect(found.map((candidate) => candidate.path), ['/homebrew/bin/styio']);
      expect(fs.metadataChecks, ['/homebrew/bin/styio', '/broken/bin/styio']);
    },
  );

  Future<FlowHeroToolchainCandidateCatalog> discover({
    String os = 'linux',
    String app = '/app/vityo',
    Map<String, String> env = const {},
    String? selected,
    required Future<bool> Function(String) check,
    bool Function()? cancel,
    Duration timeout = const Duration(seconds: 3),
  }) => discoverFlowHeroToolchainCandidates(
    kind: FlowHeroToolchainKind.styio,
    operatingSystem: os,
    bundledExecutablePath: app,
    environment: env,
    selectedPath: selected,
    fileExists: check,
    isCancelled: cancel,
    timeout: timeout,
  );

  test('POSIX bundle standard PATH and normalized duplicates', () async {
    final checked = <String>[];
    final found = await discover(
      env: {'PATH': '/usr/bin:/custom/bin:/custom/./bin::relative'},
      check: (path) async {
        checked.add(path);
        return {
          '/app/components/styio',
          '/usr/bin/styio',
          '/custom/bin/styio',
        }.contains(path);
      },
    );
    expect(found.map((entry) => entry.path), [
      '/app/components/styio',
      '/usr/bin/styio',
      '/custom/bin/styio',
    ]);
    expect(found.map((entry) => entry.sourceLabel), [
      'App bundle',
      'Standard system location',
      'System PATH',
    ]);
    expect(checked.where((path) => path == '/usr/bin/styio'), hasLength(1));
    expect(checked.where((path) => path == '/custom/bin/styio'), hasLength(1));
    expect(checked.any((path) => path.startsWith('relative')), isFalse);
  });
  test(
    'Windows semicolon PATH, exe suffix, quotes and case insensitive dedup',
    () async {
      final found = await discover(
        os: 'windows',
        app: r'C:\Vityo\vityo.exe',
        env: {'Path': r'"C:\Tools";c:\tools;D:\Other;.;C:relative'},
        check: (_) async => true,
      );
      expect(found.map((entry) => entry.path), [
        r'C:\Vityo\components\styio.exe',
        r'C:\Program Files\Styio\styio.exe',
        r'C:\Tools\styio.exe',
        r'D:\Other\styio.exe',
      ]);
    },
  );
  test('Pafio manifest path is used and traversal is rejected', () async {
    for (final relative in [
      'components/pafio/bin/pafio',
      '../outside/pafio',
      '/outside/pafio',
    ]) {
      final found = await discoverFlowHeroToolchainCandidates(
        kind: FlowHeroToolchainKind.pafio,
        operatingSystem: 'linux',
        bundledExecutablePath: '/app/vityo',
        environment: const {},
        fileExists: (_) async => true,
        readManifest: (_) async =>
            '{"schema_version":1,"component":"pafio","package_relative_path":"$relative"}',
      );
      expect(
        found
            .where((candidate) => candidate.sourceLabel == 'App bundle')
            .map((candidate) => candidate.path),
        relative.startsWith('components')
            ? ['/app/components/pafio/bin/pafio']
            : isEmpty,
      );
    }
  });
  test('macOS application Helpers', () async {
    final found = await discover(
      os: 'macos',
      app: '/Applications/Vityo.app/Contents/MacOS/Vityo',
      check: (path) async => path.contains('/Contents/Helpers/'),
    );
    expect(found.single.path, '/Applications/Vityo.app/Contents/Helpers/styio');
  });
  test('missing explicit choice preserved rather than replaced', () async {
    final found = await discover(
      selected: '/missing/styio',
      check: (path) async => path == '/usr/bin/styio',
    );
    expect(found.first.path, '/missing/styio');
    expect(found.first.exists, isFalse);
    expect(found.last.path, '/usr/bin/styio');
    expect(found.last.exists, isTrue);
  });
  test('environment override keeps source and missing state', () async {
    final found = await discover(
      selected: '/saved/styio',
      env: {'VITYO_STYIO_BIN': '/env/styio'},
      check: (_) async => false,
    );
    expect(found.map((entry) => entry.path), ['/saved/styio', '/env/styio']);
    expect(found.last.sourceLabel, contains('VITYO_STYIO_BIN'));
    expect(found.last.exists, isFalse);
  });
  test('matching override deduplicates without hiding authority', () async {
    final found = await discover(
      selected: '/same/styio',
      env: {'VITYO_STYIO_BIN': '/same/styio'},
      check: (_) async => false,
    );
    expect(found, hasLength(1));
    expect(found.single.sourceLabel, contains('VITYO_STYIO_BIN'));
  });
  test('unavailable and missing paths omitted', () async {
    expect(
      await discover(check: (_) async => throw StateError('unavailable')),
      isEmpty,
    );
    expect(await discover(check: (_) async => false), isEmpty);
  });
  test('bounded count and cancellation', () async {
    var calls = 0;
    final bounded = await discover(
      env: {'PATH': List.generate(200, (i) => '/tools/$i').join(':')},
      check: (_) async {
        calls++;
        return true;
      },
    );
    expect(calls, 100);
    expect(bounded.isPartial, isTrue);
    calls = 0;
    final cancelled = await discover(
      check: (_) async {
        calls++;
        return true;
      },
      cancel: () => calls >= 1,
    );
    expect(calls, 1);
    expect(cancelled.isPartial, isTrue);
    expect(cancelled.isCancelled, isTrue);
  });
  test('hung check respects total deadline', () async {
    final timedOut = await discover(
      check: (_) => Completer<bool>().future,
      timeout: const Duration(milliseconds: 20),
    );
    expect(timedOut.isPartial, isTrue);
    expect(
      await discover(
        check: (_) => Completer<bool>().future,
        timeout: const Duration(milliseconds: 20),
      ),
      isEmpty,
    );
  });
}
