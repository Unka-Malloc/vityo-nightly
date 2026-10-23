import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_render/flow_hero/controller.dart';
import 'package:vityo_app/src/view_render/flow_hero/flow_hero.dart';
import 'package:vityo_app/src/view_render/flow_hero/palette.dart';
import 'package:vityo_app/src/view_ide/flow_hero/theme_store.dart';

import 'support/test_file_system_manager.dart';

class _FakeThemeStore implements FlowHeroThemeStore {
  _FakeThemeStore({this.dark});

  bool? dark;
  int saves = 0;

  @override
  bool get persistent => true;

  @override
  Future<bool?> loadDark() async => dark;

  @override
  Future<void> saveDark(bool value) async {
    dark = value;
    saves++;
  }
}

void main() {
  group('theme store', () {
    test('the memory store is honest about being session-scoped', () async {
      final store = FlowHeroMemoryThemeStore();
      expect(store.persistent, isFalse);
      expect(await store.loadDark(), isNull);
      await store.saveDark(true);
      expect(await store.loadDark(), isTrue);
    });

    test('the file store round-trips through the home-relative path', () async {
      final Directory home = Directory.systemTemp.createTempSync(
        'flow_hero_theme_',
      );
      addTearDown(() {
        if (home.existsSync()) home.deleteSync(recursive: true);
      });
      final TestFileSystemManager fileSystem =
          TestFileSystemManager.linuxDebianArm();
      final String path = fileSystem.joinPath(<String>[
        home.path,
        ...kFlowHeroThemeStorePathSegments,
      ]);
      final store = FlowHeroFileThemeStore(fileSystem: fileSystem, path: path);

      expect(store.persistent, isTrue);
      expect(await store.loadDark(), isNull, reason: 'nothing stored yet');

      await store.saveDark(false);
      expect(await store.loadDark(), isFalse);

      await store.saveDark(true);
      expect(await store.loadDark(), isTrue);
    });

    test('an unknown schema is rejected instead of guessed', () async {
      final Directory home = Directory.systemTemp.createTempSync(
        'flow_hero_theme_',
      );
      addTearDown(() {
        if (home.existsSync()) home.deleteSync(recursive: true);
      });
      final TestFileSystemManager fileSystem =
          TestFileSystemManager.linuxDebianArm();
      final String path = fileSystem.joinPath(<String>[
        home.path,
        ...kFlowHeroThemeStorePathSegments,
      ]);
      await fileSystem.writeText(path, '{"schemaVersion": 99, "dark": true}\n');

      final store = FlowHeroFileThemeStore(fileSystem: fileSystem, path: path);
      expect(await store.loadDark(), isNull);
    });

    test('boot never throws and returns a store', () async {
      final store = await FlowHeroThemeStoreBoot.boot();
      expect(store, isNotNull);
    });
  });

  group('controller persistence', () {
    test('setDark flips the palette and persists', () async {
      P.dark = true;
      addTearDown(() => P.dark = true);
      final store = _FakeThemeStore();
      final controller = FlowHeroController(themeStore: store);
      addTearDown(controller.dispose);

      await controller.setDark(false);
      expect(P.dark, isFalse);
      expect(store.dark, isFalse);
      expect(store.saves, 1);
    });

    test('a restored value is applied without writing it back', () {
      P.dark = true;
      addTearDown(() => P.dark = true);
      final store = _FakeThemeStore();
      final controller = FlowHeroController(themeStore: store);
      addTearDown(controller.dispose);

      controller.applyRestoredDark(false);
      expect(P.dark, isFalse);
      expect(store.saves, 0);
    });
  });

  group('the running app', () {
    testWidgets('a stored choice is restored at startup and re-persisted', (
      WidgetTester tester,
    ) async {
      P.dark = true;
      addTearDown(() => P.dark = true);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final store = _FakeThemeStore(dark: false);
      await tester.pumpWidget(FlowHeroApp(themeStore: store));
      await tester.pump();

      expect(P.dark, isFalse, reason: 'the stored light choice wins');

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pump();
      await tester.tap(find.text('夜间'));
      await tester.pump();

      expect(P.dark, isTrue);
      expect(store.dark, isTrue);
      expect(store.saves, 1);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}
