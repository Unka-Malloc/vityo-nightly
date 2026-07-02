import 'dart:io';

String joinPath(String left, String right) {
  if (left.isEmpty) {
    return right;
  }
  if (right.isEmpty) {
    return left;
  }
  final separator = Platform.pathSeparator;
  final normalizedLeft = left.endsWith(separator)
      ? left.substring(0, left.length - separator.length)
      : left;
  final normalizedRight = right.startsWith(separator)
      ? right.substring(separator.length)
      : right;
  return '$normalizedLeft$separator$normalizedRight';
}

Future<String?> resolvePafioBinary({required String workspaceRoot}) async {
  final candidates = <String>[];
  final seen = <String>{};
  final explicit = Platform.environment['STYIO_VIEW_PAFIO_BIN'];
  if (explicit != null && explicit.isNotEmpty) {
    candidates.add(explicit);
  }
  final fromEnv = Platform.environment['PAFIO_BIN'];
  if (fromEnv != null && fromEnv.isNotEmpty) {
    candidates.add(fromEnv);
  }

  var current = Directory(workspaceRoot).absolute;
  while (true) {
    candidates.add(joinPath(current.path, '.pafio/bin/pafio'));
    candidates.add(joinPath(current.path, 'scripts/pafio'));
    candidates.add(joinPath(current.path, '../styio-pafio/scripts/pafio'));
    candidates.add(
      joinPath(current.path, '../../Unka-Malloc/styio-pafio/scripts/pafio'),
    );
    final parent = current.parent;
    if (parent.path == current.path) {
      break;
    }
    current = parent;
  }

  for (final candidate in candidates) {
    if (!seen.add(candidate)) {
      continue;
    }
    final file = File(candidate);
    if (await file.exists()) {
      return file.path;
    }
  }

  try {
    final result = await Process.run('pafio', const <String>['--version']);
    if (result.exitCode == 0) {
      return 'pafio';
    }
  } on ProcessException {
    // Fall through to null when the binary is unavailable.
  }
  return null;
}
