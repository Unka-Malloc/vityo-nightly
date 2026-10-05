import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/flow_hero/toolchain_store.dart';

import 'support/test_file_system_manager.dart';

void main() {
  group('toolchain store', () {
    late Directory home;
    late TestFileSystemManager fileSystem;
    late String path;

    setUp(() {
      home = Directory.systemTemp.createTempSync('flow_hero_toolchain_');
      fileSystem = TestFileSystemManager.linuxDebianArm();
      path = fileSystem.joinPath(<String>[
        home.path,
        ...kFlowHeroToolchainStorePathSegments,
      ]);
    });

    tearDown(() {
      if (home.existsSync()) home.deleteSync(recursive: true);
    });

    test('an empty store reports nothing stored', () async {
      final store = FlowHeroFileToolchainStore(
        fileSystem: fileSystem,
        path: path,
      );
      expect(store.persistent, isTrue);
      expect(await store.load(), isNull);
    });

    test('save and load round-trip both slots without losing either', () async {
      final store = FlowHeroFileToolchainStore(
        fileSystem: fileSystem,
        path: path,
      );

      await store.savePath(FlowHeroToolchainKind.pafio, '/opt/pafio/bin/pafio');
      FlowHeroToolchainSelection? loaded = await store.load();
      expect(loaded?.pafioPath, '/opt/pafio/bin/pafio');
      expect(loaded?.styioPath, '');

      await store.savePath(FlowHeroToolchainKind.styio, '/opt/styio/bin/styio');
      loaded = await store.load();
      expect(loaded?.pafioPath, '/opt/pafio/bin/pafio');
      expect(loaded?.styioPath, '/opt/styio/bin/styio');

      // Writing an empty path clears just that slot.
      await store.clearPath(FlowHeroToolchainKind.pafio);
      loaded = await store.load();
      expect(loaded?.pafioPath, '');
      expect(loaded?.styioPath, '/opt/styio/bin/styio');
    });

    test(
      'a partial file loads the field it has and leaves the other empty',
      () async {
        await fileSystem.writeText(
          path,
          '{"version": 1, "pafioPath": "/tmp/pafio"}\n',
        );
        final store = FlowHeroFileToolchainStore(
          fileSystem: fileSystem,
          path: path,
        );

        final loaded = await store.load();
        expect(loaded, isNotNull);
        expect(loaded!.pafioPath, '/tmp/pafio');
        expect(loaded.styioPath, '');
      },
    );

    test(
      'corrupted and unknown-shape files are rejected, not guessed',
      () async {
        final store = FlowHeroFileToolchainStore(
          fileSystem: fileSystem,
          path: path,
        );
        final List<String> rejected = <String>[
          'not json at all\n',
          '{"version": 99, "pafioPath": "/tmp/pafio"}\n',
          '{"pafioPath": "/tmp/pafio"}\n',
          '{"version": 1, "pafioPath": 42}\n',
          '{"version": 1, "styioPath": true}\n',
        ];
        for (final String contents in rejected) {
          await fileSystem.writeText(path, contents);
          expect(await store.load(), isNull, reason: 'must reject: $contents');
        }
      },
    );

    test('the memory store is honest about being session-scoped', () async {
      final store = FlowHeroMemoryToolchainStore();
      expect(store.persistent, isFalse);
      expect((await store.load())?.isEmpty, isTrue);

      await store.savePath(FlowHeroToolchainKind.pafio, '/tmp/pafio');
      expect((await store.load())?.pafioPath, '/tmp/pafio');
    });

    test('boot never throws and returns a store', () async {
      final store = await FlowHeroToolchainStoreBoot.boot();
      expect(store, isNotNull);
    });
  });
}
