import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/ide/agent_client/agent_client_models.dart';
import 'package:vityo_app/src/view_render/flow_hero/agent_bridge.dart';
import 'package:vityo_app/src/view_render/flow_hero/controller.dart';
import 'package:vityo_app/src/view_render/flow_hero/engine/machine.dart';
import 'package:vityo_app/src/view_ide/flow_hero/execution_service.dart';
import 'package:vityo_app/src/view_render/flow_hero/flow_hero.dart';
import 'package:vityo_app/src/view_ide/flow_hero/language_service.dart';
import 'package:vityo_app/src/view_render/flow_hero/palette.dart';
import 'package:vityo_app/src/view_render/flow_hero/settings_panel.dart';
import 'package:vityo_app/src/view_ide/flow_hero/toolchain_store.dart';
import 'package:vityo_app/src/view_render/flow_hero/workspace_drawer.dart';
import 'package:vityo_app/src/view_ide/flow_hero/workspace_file_index.dart';
import 'package:vityo_app/src/view_ide/flow_hero/workspace_store.dart';

import 'support/test_file_system_manager.dart';

class _FakeWorkspaceStore implements FlowHeroWorkspaceStore {
  _FakeWorkspaceStore({this.stored});

  String? stored;
  int saves = 0;

  @override
  bool get persistent => true;

  @override
  Future<String?> load() async => stored;

  @override
  Future<void> save(String path) async {
    stored = path.trim();
    saves++;
  }
}

class _FakeIndex implements FlowHeroWorkspaceFileIndex {
  _FakeIndex(this.files);

  final List<String> files;

  @override
  Future<List<String>> listFiles() async => files;
}

/// A minimal real execution route: the controller only needs a live source it
/// can attach and dispose during a workspace switch.
class _FakeExecutionSource implements FlowHeroExecutionSource {
  @override
  FlowHeroExecutionMode get mode => FlowHeroExecutionMode.unavailable;

  @override
  bool get live => false;

  @override
  String get statusLine => 'pafio run/test';

  @override
  String get unavailableReason => '未发现 pafio';

  @override
  Future<FlowHeroExecutionOutcome> execute(
    FlowHeroExecutionKind kind, {
    VoidCallback? onStarted,
  }) => Future<FlowHeroExecutionOutcome>.error(StateError('unused'));

  @override
  Future<bool> cancel() async => false;

  @override
  Future<void> dispose() async {}
}

void main() {
  group('workspace store', () {
    test('the memory store is honest about being session-scoped', () async {
      final store = FlowHeroMemoryWorkspaceStore();
      expect(store.persistent, isFalse);
      expect(await store.load(), isNull);
      await store.save('  /tmp/ws  ');
      expect(await store.load(), '/tmp/ws');
    });

    test('the file store round-trips through the home-relative path', () async {
      final Directory home = Directory.systemTemp.createTempSync(
        'flow_hero_workspace_',
      );
      addTearDown(() {
        if (home.existsSync()) home.deleteSync(recursive: true);
      });
      final TestFileSystemManager fileSystem =
          TestFileSystemManager.linuxDebianArm();
      final String path = fileSystem.joinPath(<String>[
        home.path,
        ...kFlowHeroWorkspaceStorePathSegments,
      ]);
      final store = FlowHeroFileWorkspaceStore(
        fileSystem: fileSystem,
        path: path,
      );

      expect(store.persistent, isTrue);
      expect(await store.load(), isNull, reason: 'nothing stored yet');

      await store.save('/tmp/flow-hero-ws');
      expect(await store.load(), '/tmp/flow-hero-ws');
    });

    test('an unknown schema is rejected instead of guessed', () async {
      final Directory home = Directory.systemTemp.createTempSync(
        'flow_hero_workspace_',
      );
      addTearDown(() {
        if (home.existsSync()) home.deleteSync(recursive: true);
      });
      final TestFileSystemManager fileSystem =
          TestFileSystemManager.linuxDebianArm();
      final String path = fileSystem.joinPath(<String>[
        home.path,
        ...kFlowHeroWorkspaceStorePathSegments,
      ]);
      await fileSystem.writeText(
        path,
        '{"version": 99, "rootPath": "/tmp/ws"}\n',
      );

      final store = FlowHeroFileWorkspaceStore(
        fileSystem: fileSystem,
        path: path,
      );
      expect(await store.load(), isNull);
    });

    test('a wrong-typed root path is rejected', () async {
      final Directory home = Directory.systemTemp.createTempSync(
        'flow_hero_workspace_',
      );
      addTearDown(() {
        if (home.existsSync()) home.deleteSync(recursive: true);
      });
      final TestFileSystemManager fileSystem =
          TestFileSystemManager.linuxDebianArm();
      final String path = fileSystem.joinPath(<String>[
        home.path,
        ...kFlowHeroWorkspaceStorePathSegments,
      ]);
      await fileSystem.writeText(path, '{"version": 1, "rootPath": 7}\n');

      final store = FlowHeroFileWorkspaceStore(
        fileSystem: fileSystem,
        path: path,
      );
      expect(await store.load(), isNull);
    });

    test('boot never throws and returns a store', () async {
      final store = await FlowHeroWorkspaceStoreBoot.boot();
      expect(store, isNotNull);
    });
  });

  group('workspace root priority', () {
    test('a selection outranks the build-time workspace', () {
      expect(
        resolveFlowHeroWorkspaceRoot(selected: '/chosen', configured: '/flag'),
        '/chosen',
      );
      expect(
        resolveFlowHeroWorkspaceRoot(selected: '  ', configured: '/flag'),
        '/flag',
      );
      expect(
        resolveFlowHeroWorkspaceRoot(selected: '', configured: '  '),
        isEmpty,
      );
    });
  });

  group('controller workspace selection', () {
    late List<String> indexRoots;

    setUp(() => indexRoots = <String>[]);

    FlowHeroWorkspaceFileIndex factory(String root) {
      indexRoots.add(root);
      return _FakeIndex(<String>['$root/a.styio']);
    }

    test('demo behaviour is unchanged while no workspace is selected', () {
      final controller = FlowHeroController(
        workspaceStore: _FakeWorkspaceStore(),
      );
      addTearDown(controller.dispose);

      expect(controller.workspaceRoot, isEmpty);
      expect(controller.workspacePersistent, isTrue);
      expect(controller.demoModeActive, isTrue);
      expect(
        controller.workspaceRootDisplayPath,
        flowHeroWorkspaceRoot(),
        reason: 'the drawer keeps the package-root fallback',
      );
    });

    test(
      'switchWorkspace persists and re-roots index, bridge and store',
      () async {
        final store = _FakeWorkspaceStore();
        var executionBoots = 0;
        final controller = FlowHeroController(
          workspaceStore: store,
          workspaceFileIndexFactory: factory,
          executionBoot: (FlowHeroToolchainSelection selection) async {
            executionBoots++;
            return _FakeExecutionSource();
          },
          languageBoot: (FlowHeroToolchainSelection selection) async =>
              FlowHeroLanguageRuntime.boot(workspaceRoot: ''),
        );
        addTearDown(controller.dispose);
        await controller.workspaceBootSettled;

        expect(indexRoots, <String>[''], reason: 'the initial root is empty');
        expect(executionBoots, 1, reason: 'the constructor probes once');

        final bool switched = await controller.switchWorkspace('/tmp/ws-b');

        expect(switched, isTrue);
        expect(controller.workspaceRoot, '/tmp/ws-b');
        expect(controller.workspaceRootDisplayPath, '/tmp/ws-b');
        expect(controller.bridge.workspaceRoot, '/tmp/ws-b');
        expect(store.stored, '/tmp/ws-b');
        expect(store.saves, 1);
        expect(indexRoots, <String>['', '/tmp/ws-b']);
        expect((controller.workspaceFileIndex as _FakeIndex).files, <String>[
          '/tmp/ws-b/a.styio',
        ]);
        expect(executionBoots, 2, reason: 'the execution route re-probes');
        expect(controller.demoModeActive, isFalse);
      },
    );

    test(
      'pickWorkspace adopts the chosen directory and seeds the picker',
      () async {
        final store = _FakeWorkspaceStore();
        final List<String> seeds = <String>[];
        final controller = FlowHeroController(
          workspaceStore: store,
          workspaceFileIndexFactory: factory,
          workspacePicker: (String currentRoot) async {
            seeds.add(currentRoot);
            return '  /tmp/ws-picked  ';
          },
        );
        addTearDown(controller.dispose);
        await controller.workspaceBootSettled;

        expect(await controller.pickWorkspace(), isTrue);
        expect(seeds, <String>['']);
        expect(controller.workspaceRoot, '/tmp/ws-picked');
        expect(store.stored, '/tmp/ws-picked');
      },
    );

    test('a cancelled picker leaves the workspace untouched', () async {
      final store = _FakeWorkspaceStore();
      final controller = FlowHeroController(
        workspaceStore: store,
        workspaceFileIndexFactory: factory,
        workspacePicker: (String currentRoot) async => null,
      );
      addTearDown(controller.dispose);
      await controller.workspaceBootSettled;

      expect(await controller.pickWorkspace(), isFalse);
      expect(controller.workspaceRoot, isEmpty);
      expect(store.saves, 0);
    });

    test('a persisted selection outranks the injected initial root', () async {
      final store = _FakeWorkspaceStore(stored: '/tmp/ws-stored');
      final controller = FlowHeroController(
        workspaceStore: store,
        workspaceFileIndexFactory: factory,
        initialWorkspaceRoot: '/tmp/ws-injected',
      );
      addTearDown(controller.dispose);

      expect(controller.workspaceRoot, '/tmp/ws-injected');
      await controller.workspaceBootSettled;

      expect(controller.workspaceRoot, '/tmp/ws-stored');
      expect(
        store.saves,
        0,
        reason: 'an adopted root is already stored; it is not written back',
      );
      expect(indexRoots, <String>['/tmp/ws-injected', '/tmp/ws-stored']);
    });

    test('switching to the current root persists without rebuilding', () async {
      final store = _FakeWorkspaceStore();
      final controller = FlowHeroController(
        workspaceStore: store,
        workspaceFileIndexFactory: factory,
      );
      addTearDown(controller.dispose);
      await controller.workspaceBootSettled;

      expect(await controller.switchWorkspace('/tmp/ws-same'), isTrue);
      expect(indexRoots, <String>['', '/tmp/ws-same']);

      expect(await controller.switchWorkspace('/tmp/ws-same'), isTrue);
      expect(indexRoots, <String>[
        '',
        '/tmp/ws-same',
      ], reason: 'an unchanged root does not rebuild the index');
      expect(
        store.saves,
        2,
        reason: 'each explicit switch is persisted, even when unchanged',
      );
    });

    test('switchWorkspace drops buffers opened from the old root', () async {
      final Directory oldRoot = Directory.systemTemp.createTempSync(
        'flow_hero_ws_old_',
      );
      addTearDown(() {
        if (oldRoot.existsSync()) oldRoot.deleteSync(recursive: true);
      });
      final String path = '${oldRoot.path}/only.styio';
      File(path).writeAsStringSync('pipeline onlyFlow\nlet staged := source\n');

      final store = _FakeWorkspaceStore();
      final controller = FlowHeroController(
        workspaceStore: store,
        workspaceFileIndexFactory: factory,
      );
      addTearDown(controller.dispose);
      await controller.workspaceBootSettled;

      expect(await controller.engine.openPath(path), isTrue);
      expect(controller.engine.activeFile.path, path);

      expect(await controller.switchWorkspace('/tmp/ws-elsewhere'), isTrue);

      expect(
        controller.engine.files.where((file) => file.path != null),
        isEmpty,
        reason: 'buffers read through the old root must not stay authoritative',
      );
      expect(controller.engine.activeFile.name, 'main.styio');
      expect(controller.activeFile, 'main.styio');
    });
  });

  group('agent bridge workspace root', () {
    test('setWorkspaceRoot is adopted by the next reconnect', () async {
      final WorkbenchController engine = WorkbenchController();
      addTearDown(engine.dispose);
      final List<String> resolvedRoots = <String>[];
      final bridge = AgentBridge(
        launchResolver: ({required String workingDirectory}) async {
          resolvedRoots.add(workingDirectory);
          return AgentLaunchDescriptor(
            id: AgentBridge.agentId,
            executable: '/fixture/vityo-coding-agent',
            arguments: const <String>['--stdio-agent'],
            workingDirectory: workingDirectory,
          );
        },
        clientFactory: () async => null,
      )..modelConfigured = () async => true;
      addTearDown(bridge.dispose);

      expect(bridge.workspaceRoot, isEmpty);

      bridge.setWorkspaceRoot('/tmp/ws-a');
      await bridge.attach(
        engine: engine,
        onText: (String _) {},
        onReceipt: (String _) {},
      );
      expect(resolvedRoots, <String>['/tmp/ws-a']);

      bridge.setWorkspaceRoot('  /tmp/ws-b  ');
      expect(bridge.workspaceRoot, '/tmp/ws-b');
      await bridge.reconnect();

      expect(resolvedRoots, <String>['/tmp/ws-a', '/tmp/ws-b']);
    });

    test('clearing the selection falls back to the default root', () {
      final bridge = AgentBridge();
      addTearDown(bridge.dispose);

      bridge.setWorkspaceRoot('/tmp/ws-a');
      expect(bridge.workspaceRoot, '/tmp/ws-a');
      bridge.setWorkspaceRoot('   ');
      expect(bridge.workspaceRoot, AgentBridge.workspaceDir.trim());
    });
  });

  group('the running app', () {
    testWidgets('the drawer and settings follow a workspace switch', (
      WidgetTester tester,
    ) async {
      P.dark = true;
      addTearDown(() => P.dark = true);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final Directory workspace = Directory.systemTemp.createTempSync(
        'flow_hero_ws_target_',
      );
      addTearDown(() {
        if (workspace.existsSync()) workspace.deleteSync(recursive: true);
      });
      final String rootName = workspace.path.split('/').last;

      await tester.pumpWidget(
        FlowHeroApp(
          workspaceStore: _FakeWorkspaceStore(),
          workspacePicker: (String currentRoot) async => workspace.path,
        ),
      );
      await tester.pump();

      final FlowHeroController controller = tester
          .widget<WorkspaceDrawer>(find.byType(WorkspaceDrawer))
          .controller;
      expect(controller.workspaceRoot, isEmpty);

      // The drawer header carries the switch entry and starts on the fallback.
      await tester.tap(find.byIcon(Icons.folder_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey<String>('flow-hero-workspace-switch')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('flow-hero-workspace-switch')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(controller.workspaceRoot, workspace.path);
      expect(find.text(rootName), findsWidgets);

      // The settings panel exposes the same root and the same entry point.
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(SettingsPanel),
          matching: find.text('工作区'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('settings-workspace-switch')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey<String>('settings-workspace-path')),
            )
            .data,
        workspace.path,
      );

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}
