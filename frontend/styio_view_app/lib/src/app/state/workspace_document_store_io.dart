import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../editor/document_state.dart';
import '../../editor/editor_controller.dart';
import 'workspace_document_store_types.dart';

Future<WorkspaceDocumentStore> createPlatformWorkspaceDocumentStore() async {
  final supportDirectory = await getApplicationSupportDirectory();
  final rootDirectory = Directory(
    '${supportDirectory.path}${Platform.pathSeparator}styio_view_workspace',
  );
  return FileSystemWorkspaceDocumentStore(rootDirectory);
}

class FileSystemWorkspaceDocumentStore implements WorkspaceDocumentStore {
  FileSystemWorkspaceDocumentStore(this.rootDirectory);

  final Directory rootDirectory;

  @override
  Future<DocumentState> loadDocument(String path) async {
    await rootDirectory.create(recursive: true);
    if (_isAbsolutePath(path)) {
      final sourceFile = File(path);
      if (await sourceFile.exists()) {
        return DocumentState(
          documentId: path,
          text: await sourceFile.readAsString(),
          revision: 0,
        );
      }
      return EditorSessionController.seedDocumentForPath(path);
    }
    final sourceFile = _sourceFile(path);
    final metadataFile = _metadataFile(path);

    if (!await sourceFile.exists()) {
      return EditorSessionController.seedDocumentForPath(path);
    }

    final text = await sourceFile.readAsString();
    var revision = 0;

    if (await metadataFile.exists()) {
      final metadata = jsonDecode(await metadataFile.readAsString());
      if (metadata is Map<String, dynamic>) {
        revision = metadata['revision'] is int
            ? metadata['revision'] as int
            : 0;
      }
    }

    return DocumentState(documentId: path, text: text, revision: revision);
  }

  @override
  Future<void> saveDocument(DocumentState document) async {
    await rootDirectory.create(recursive: true);
    if (_isAbsolutePath(document.documentId)) {
      final sourceFile = File(document.documentId);
      await sourceFile.parent.create(recursive: true);
      await sourceFile.writeAsString(document.text);
      return;
    }
    final sourceFile = _sourceFile(document.documentId);
    final metadataFile = _metadataFile(document.documentId);

    await sourceFile.parent.create(recursive: true);
    await sourceFile.writeAsString(document.text);
    await metadataFile.writeAsString(
      jsonEncode(<String, Object>{'revision': document.revision}),
    );
  }

  File _sourceFile(String path) {
    return File(_resolvePath(path));
  }

  File _metadataFile(String path) {
    return File('${_resolvePath(path)}.meta.json');
  }

  String _resolvePath(String documentId) {
    final segments = documentId
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .map(Uri.encodeComponent);
    return [rootDirectory.path, ...segments].join(Platform.pathSeparator);
  }

  bool _isAbsolutePath(String path) {
    return path.startsWith(Platform.pathSeparator) ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
  }
}
