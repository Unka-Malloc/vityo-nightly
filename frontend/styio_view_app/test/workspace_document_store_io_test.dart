import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:styio_view_app/src/app/state/workspace_document_store_io.dart';
import 'package:styio_view_app/src/editor/document_state.dart';

void main() {
  test('filesystem store persists source and revision sidecar', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'styio_view_store_test_',
    );
    addTearDown(() => tempRoot.delete(recursive: true));

    final store = FileSystemWorkspaceDocumentStore(tempRoot);
    const document = DocumentState(
      documentId: 'cloud/main.styio',
      text: 'fn main() {\n  emit session\n}\n',
      revision: 7,
    );

    await store.saveDocument(document);
    final loaded = await store.loadDocument(document.documentId);

    expect(loaded.text, document.text);
    expect(loaded.revision, document.revision);
    expect(
      File(
        '${tempRoot.path}${Platform.pathSeparator}cloud${Platform.pathSeparator}main.styio',
      ).existsSync(),
      isTrue,
    );
  });

  test(
    'filesystem store reads and writes absolute project files directly',
    () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'styio_view_store_abs_test_',
      );
      addTearDown(() => tempRoot.delete(recursive: true));

      final absoluteFile = File(
        '${tempRoot.path}${Platform.pathSeparator}src${Platform.pathSeparator}main.styio',
      )..createSync(recursive: true);
      absoluteFile.writeAsStringSync('fn main() {\n  emit seed\n}\n');

      final store = FileSystemWorkspaceDocumentStore(tempRoot);

      final loaded = await store.loadDocument(absoluteFile.path);
      expect(loaded.text, 'fn main() {\n  emit seed\n}\n');

      final updated = DocumentState(
        documentId: loaded.documentId,
        text: 'fn main() {\n  emit updated\n}\n',
        revision: 3,
      );

      await store.saveDocument(updated);

      expect(absoluteFile.readAsStringSync(), updated.text);
    },
  );
}
