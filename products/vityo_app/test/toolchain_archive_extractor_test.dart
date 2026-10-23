import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/toolchain/toolchain.dart';

import 'support/test_file_system_manager.dart';

void main() {
  test('archive extractor expands tar directories and files', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'vityo_toolchain_archive_test_',
    );
    addTearDown(() => tempRoot.delete(recursive: true));
    final manager = TestFileSystemManager.linuxDebianArm();
    final extractor = ToolchainArchiveExtractor(fileSystemManager: manager);
    final destination = manager.joinPath(<String>[tempRoot.path, 'extracted']);
    final archive = _tarArchive(<_TarEntry>[
      _TarEntry.directory('bin/'),
      _TarEntry.file('bin/styio', utf8.encode('styio executable')),
      _TarEntry.file('manifest.json', utf8.encode('{"name":"styio"}')),
    ]);

    final result = await extractor.extractTar(
      archiveBytes: archive,
      destinationDirectory: destination,
    );

    expect(result.succeeded, isTrue);
    expect(result.extractedEntryCount, 3);
    expect(result.toJson()['succeeded'], isTrue);
    expect(
      await File(
        manager.joinPath(<String>[destination, 'bin/styio']),
      ).readAsString(),
      'styio executable',
    );
    expect(
      await File(
        manager.joinPath(<String>[destination, 'manifest.json']),
      ).readAsString(),
      '{"name":"styio"}',
    );
  });

  test('archive extractor rejects unsafe tar entry paths', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'vityo_toolchain_archive_unsafe_test_',
    );
    addTearDown(() => tempRoot.delete(recursive: true));
    final extractor = ToolchainArchiveExtractor(
      fileSystemManager: TestFileSystemManager.linuxDebianArm(),
    );

    final emptyPath = await extractor.extractTar(
      archiveBytes: _tarArchive(<_TarEntry>[_TarEntry.file('', const <int>[])]),
      destinationDirectory: tempRoot.path,
    );
    final absolutePath = await extractor.extractTar(
      archiveBytes: _tarArchive(<_TarEntry>[
        _TarEntry.file('/tmp/styio', const <int>[]),
      ]),
      destinationDirectory: tempRoot.path,
    );
    final parentEscape = await extractor.extractTar(
      archiveBytes: _tarArchive(<_TarEntry>[
        _TarEntry.file('../styio', const <int>[]),
      ]),
      destinationDirectory: tempRoot.path,
    );

    expect(emptyPath.succeeded, isFalse);
    expect(emptyPath.message, contains('path is empty'));
    expect(absolutePath.message, contains('absolute'));
    expect(parentEscape.message, contains('escapes'));
  });

  test('archive extractor rejects backslash traversal on Windows paths', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'vityo_toolchain_archive_windows_test_',
    );
    addTearDown(() => tempRoot.delete(recursive: true));
    final extractor = ToolchainArchiveExtractor(
      fileSystemManager: TestFileSystemManager.windowsX64(),
    );
    final destination = tempRoot.path;

    for (final name in <String>[
      '..\\..\\outside-file',
      'nested\\..\\..\\outside-file',
      r'\\server\share\outside-file',
      r'C:\outside-file',
      'C:\\outside-file',
      '..\\outside-file',
    ]) {
      final result = await extractor.extractTar(
        archiveBytes: _tarArchive(<_TarEntry>[
          _TarEntry.file(name, const <int>[]),
        ]),
        destinationDirectory: destination,
      );
      expect(result.succeeded, isFalse, reason: name);
    }

    // The windows fixture rewrites '/' to '\', which a POSIX host would
    // materialize as one literal filename outside the destination; the
    // success case therefore runs under posix facts where a backslash
    // entry normalizes to a real nested path inside it.
    final posixExtractor = ToolchainArchiveExtractor(
      fileSystemManager: TestFileSystemManager.linuxDebianArm(),
    );
    final safe = await posixExtractor.extractTar(
      archiveBytes: _tarArchive(<_TarEntry>[
        _TarEntry.file('dir\\nested\\file.txt', utf8.encode('payload')),
      ]),
      destinationDirectory: destination,
    );
    expect(safe.succeeded, isTrue, reason: safe.message);
    final extracted = File(
      '${tempRoot.path}/dir/nested/file.txt',
    );
    expect(await extracted.exists(), isTrue);
    expect(await extracted.readAsString(), 'payload');
  });

  test('archive extractor reports truncated and unterminated tar archives', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'vityo_toolchain_archive_invalid_test_',
    );
    addTearDown(() => tempRoot.delete(recursive: true));
    final extractor = ToolchainArchiveExtractor(
      fileSystemManager: TestFileSystemManager.linuxDebianArm(),
    );

    final truncated = await extractor.extractTar(
      archiveBytes: _header(name: 'bin/styio', size: 12, typeFlag: 48),
      destinationDirectory: tempRoot.path,
    );
    final unterminated = await extractor.extractTar(
      archiveBytes: _header(name: 'bin/styio', size: 0, typeFlag: 48),
      destinationDirectory: tempRoot.path,
    );

    expect(truncated.succeeded, isFalse);
    expect(truncated.message, contains('exceeds archive length'));
    expect(unterminated.succeeded, isFalse);
    expect(unterminated.message, contains('before a terminator block'));
  });
}

class _TarEntry {
  const _TarEntry._({
    required this.name,
    required this.bytes,
    required this.typeFlag,
  });

  factory _TarEntry.file(String name, List<int> bytes) {
    return _TarEntry._(name: name, bytes: bytes, typeFlag: 48);
  }

  factory _TarEntry.directory(String name) {
    return _TarEntry._(name: name, bytes: const <int>[], typeFlag: 53);
  }

  final String name;
  final List<int> bytes;
  final int typeFlag;
}

List<int> _tarArchive(List<_TarEntry> entries) {
  return <int>[
    for (final entry in entries) ...[
      ..._header(
        name: entry.name,
        size: entry.bytes.length,
        typeFlag: entry.typeFlag,
      ),
      ...entry.bytes,
      ...List<int>.filled(_paddingFor(entry.bytes.length), 0),
    ],
    ...List<int>.filled(512, 0),
  ];
}

List<int> _header({
  required String name,
  required int size,
  required int typeFlag,
}) {
  final header = List<int>.filled(512, 0);
  _writeAscii(header, 0, 100, name);
  _writeAscii(header, 100, 8, '0000777');
  _writeAscii(header, 108, 8, '0000000');
  _writeAscii(header, 116, 8, '0000000');
  _writeAscii(header, 124, 12, size.toRadixString(8).padLeft(11, '0'));
  _writeAscii(header, 136, 12, '00000000000');
  header[156] = typeFlag;
  return header;
}

void _writeAscii(List<int> target, int start, int length, String value) {
  final bytes = ascii.encode(value);
  for (var index = 0; index < bytes.length && index < length; index += 1) {
    target[start + index] = bytes[index];
  }
}

int _paddingFor(int size) {
  final remainder = size % 512;
  return remainder == 0 ? 0 : 512 - remainder;
}
