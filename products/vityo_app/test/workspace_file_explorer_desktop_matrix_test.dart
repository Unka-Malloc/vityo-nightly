import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/ide/workspace/workspace.dart';
import 'package:vityo_app/src/view_ide/environment/environment.dart';

void main() {
  final fixtures = <_DesktopExplorerFixture>[
    _DesktopExplorerFixture(
      label: 'linux',
      facts: FileSystemFacts.linuxDebianArm(),
      rootPath: '/workspace/fixture',
      readmePath: '/workspace/fixture/README.md',
      mainPath: '/workspace/fixture/src/main.styio',
      createdPath: '/workspace/fixture/src/created.styio',
      ignoredPath: '/workspace/fixture/build/generated.styio',
      outsidePath: '/Workspace/fixture/private.styio',
    ),
    _DesktopExplorerFixture(
      label: 'windows',
      facts: FileSystemFacts.windowsX64(),
      rootPath: r'C:\workspace\fixture',
      readmePath: r'C:\workspace\fixture\README.md',
      mainPath: r'C:\workspace\fixture\src\main.styio',
      createdPath: r'C:\workspace\fixture\src\created.styio',
      ignoredPath: r'C:\workspace\fixture\build\generated.styio',
      outsidePath: r'D:\private\outside.styio',
    ),
  ];

  for (final fixture in fixtures) {
    test(
      '${fixture.label} discovery and watcher keep workspace-relative facts',
      () async {
        final events = StreamController<FileSystemManagerEvent>();
        final manager = _DesktopExplorerFileSystemManager(
          facts: fixture.facts,
          entries: <FileSystemEntitySnapshot>[
            _file(fixture.readmePath),
            _file(fixture.mainPath),
            _file(fixture.ignoredPath),
            _file(fixture.outsidePath),
          ],
          events: events.stream,
        );
        addTearDown(events.close);

        final discovery = await WorkspaceFileExplorerFileSystemDiscoveryBinding(
          fileSystemManager: manager,
          rootPath: fixture.rootPath,
        ).discover();
        final watcher = WorkspaceFileExplorerFileSystemWatcherBinding(
          fileSystemManager: manager,
          plan: WorkspaceFileExplorerWatchPlan(
            rootPath: fixture.rootPath,
            caseSensitivePaths: manager.compatibility.caseSensitive,
          ),
          baseFilePaths: discovery.filePaths,
          clock: () => DateTime.utc(2026, 8, 31),
        );
        final snapshots = <WorkspaceFileExplorerWatchSnapshot>[];
        final completed = Completer<void>();
        final subscription = watcher.watch().listen(
          snapshots.add,
          onDone: completed.complete,
        );
        addTearDown(subscription.cancel);
        await Future<void>.delayed(Duration.zero);
        events.add(
          FileSystemManagerEvent(
            kind: FileSystemManagerEventKind.created,
            path: fixture.createdPath,
            normalizedPath: fixture.createdPath,
          ),
        );
        events.add(
          FileSystemManagerEvent(
            kind: FileSystemManagerEventKind.created,
            path: fixture.outsidePath,
            normalizedPath: fixture.outsidePath,
          ),
        );
        await events.close();
        await completed.future;

        expect(manager.listedRecursive, isTrue);
        expect(manager.watchedRecursive, isTrue);
        expect(discovery.filePaths, <String>['README.md', 'src/main.styio']);
        expect(discovery.ignoredPaths, <String>[
          fixture.outsidePath.replaceAll('\\', '/'),
          'build/generated.styio',
        ]);
        expect(snapshots.last.filePaths, <String>[
          'README.md',
          'src/created.styio',
          'src/main.styio',
        ]);
        expect(snapshots.last.telemetry.totalEventCount, 1);
        expect(snapshots.last.telemetry.batchCount, 1);
        expect(snapshots.last.plan.active, isTrue);
      },
    );
  }
}

FileSystemEntitySnapshot _file(String path) {
  return FileSystemEntitySnapshot(
    path: path,
    normalizedPath: path,
    type: VityoFileSystemEntityType.file,
  );
}

class _DesktopExplorerFixture {
  const _DesktopExplorerFixture({
    required this.label,
    required this.facts,
    required this.rootPath,
    required this.readmePath,
    required this.mainPath,
    required this.createdPath,
    required this.ignoredPath,
    required this.outsidePath,
  });

  final String label;
  final FileSystemFacts facts;
  final String rootPath;
  final String readmePath;
  final String mainPath;
  final String createdPath;
  final String ignoredPath;
  final String outsidePath;
}

class _DesktopExplorerFileSystemManager extends UnsupportedFileSystemManager {
  _DesktopExplorerFileSystemManager({
    required super.facts,
    required this.entries,
    required this.events,
  });

  final List<FileSystemEntitySnapshot> entries;
  final Stream<FileSystemManagerEvent> events;
  bool listedRecursive = false;
  bool watchedRecursive = false;

  @override
  Future<List<FileSystemEntitySnapshot>> list(
    String path, {
    bool recursive = false,
  }) async {
    listedRecursive = recursive;
    return entries;
  }

  @override
  Stream<FileSystemManagerEvent> watch(String path, {bool recursive = false}) {
    watchedRecursive = recursive;
    return events;
  }
}
