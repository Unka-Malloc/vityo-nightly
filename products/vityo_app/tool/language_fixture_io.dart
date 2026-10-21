import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vityo_app/src/view_ide/environment/system_compatibility/file_system/file_system_manager.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/process/process_adapter.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/process/process_facts.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/process/process_manager.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/file_system/file_system_prober_io.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/process/process_prober_io.dart';

Future<FileSystemManager> createLanguageFixtureFileSystemManager() async {
  return StandaloneFixtureFileSystemManager(
    facts: await const LocalFileSystemProber().probe(),
  );
}

Future<ProcessManager> createLanguageFixtureProcessManager() async {
  return StandaloneFixtureProcessManager(
    facts: await const LocalProcessProber().probe(),
  );
}

/// Read-only host file access for the standalone fixture command.
///
/// The desktop runtime continues to use its daemon-backed filesystem provider.
/// This narrow adapter lets the repository tool inspect its explicit fixture
/// roots without starting a daemon or widening product filesystem access.
final class StandaloneFixtureFileSystemManager
    extends UnsupportedFileSystemManager {
  StandaloneFixtureFileSystemManager({required super.facts});

  @override
  Future<FileSystemEntitySnapshot> stat(String path) async {
    final normalizedPath = normalizePath(path);
    final type = await FileSystemEntity.type(
      normalizedPath,
      followLinks: false,
    );
    final entityType = switch (type) {
      FileSystemEntityType.file => VityoFileSystemEntityType.file,
      FileSystemEntityType.directory => VityoFileSystemEntityType.directory,
      FileSystemEntityType.link => VityoFileSystemEntityType.link,
      FileSystemEntityType.notFound => VityoFileSystemEntityType.notFound,
      _ => VityoFileSystemEntityType.other,
    };
    final entity = switch (entityType) {
      VityoFileSystemEntityType.file => File(normalizedPath),
      VityoFileSystemEntityType.directory => Directory(normalizedPath),
      VityoFileSystemEntityType.link => Link(normalizedPath),
      _ => null,
    };
    final stat = entity == null ? null : await entity.stat();
    return FileSystemEntitySnapshot(
      path: path,
      normalizedPath: normalizedPath,
      type: entityType,
      size: entityType == VityoFileSystemEntityType.file ? stat?.size : null,
      modifiedAt: stat?.modified,
    );
  }

  @override
  Future<List<FileSystemEntitySnapshot>> list(
    String path, {
    bool recursive = false,
  }) async {
    final entities = await Directory(
      normalizePath(path),
    ).list(recursive: recursive, followLinks: false).toList();
    final snapshots = <FileSystemEntitySnapshot>[];
    for (final entity in entities) {
      final normalizedPath = normalizePath(entity.path);
      final type = switch (entity) {
        File() => VityoFileSystemEntityType.file,
        Directory() => VityoFileSystemEntityType.directory,
        Link() => VityoFileSystemEntityType.link,
        _ => VityoFileSystemEntityType.other,
      };
      final stat = type == VityoFileSystemEntityType.file
          ? await entity.stat()
          : null;
      snapshots.add(
        FileSystemEntitySnapshot(
          path: entity.path,
          normalizedPath: normalizedPath,
          type: type,
          size: stat?.size,
          modifiedAt: stat?.modified,
        ),
      );
    }
    return snapshots;
  }

  @override
  Future<String> readText(String path) {
    return File(normalizePath(path)).readAsString();
  }
}

/// Runs the explicitly selected parser CLI for this standalone tool only.
///
/// Product execution continues through vityod; this adapter exists so the
/// repository's deterministic source-fixture gate does not depend on launching
/// the desktop daemon.
final class StandaloneFixtureProcessManager implements ProcessManager {
  StandaloneFixtureProcessManager({required this.facts})
    : compatibility = ProcessAdapter(facts).adapt();

  @override
  final ProcessFacts facts;

  @override
  final ProcessCompatibility compatibility;

  @override
  Future<ProcessCommandResult> run(ProcessCommandRequest request) async {
    final stopwatch = Stopwatch()..start();
    Process? process;
    try {
      process = await Process.start(
        request.executablePath,
        request.arguments,
        workingDirectory: request.workingDirectory,
        environment: request.environment,
        includeParentEnvironment: true,
        runInShell: false,
      );
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();
      if (request.standardInput != null) {
        process.stdin.write(request.standardInput);
      }
      await process.stdin.close();

      var timedOut = false;
      try {
        if (request.timeout case final timeout?) {
          await process.exitCode.timeout(timeout);
        } else {
          await process.exitCode;
        }
      } on TimeoutException {
        timedOut = true;
        process.kill();
      }
      final exitCode = await process.exitCode;
      final stdout = await stdoutFuture;
      final stderr = await stderrFuture;
      stopwatch.stop();
      return ProcessCommandResult(
        status: timedOut
            ? ProcessCommandStatus.timedOut
            : exitCode == 0
            ? ProcessCommandStatus.succeeded
            : ProcessCommandStatus.failed,
        executablePath: request.executablePath,
        arguments: request.arguments,
        exitCode: exitCode,
        stdout: stdout,
        stderr: stderr,
        duration: stopwatch.elapsed,
        message: timedOut ? 'The fixture tool process timed out.' : null,
      );
    } on ProcessException {
      stopwatch.stop();
      return ProcessCommandResult(
        status: ProcessCommandStatus.failed,
        executablePath: request.executablePath,
        arguments: request.arguments,
        exitCode: null,
        stdout: '',
        stderr: '',
        duration: stopwatch.elapsed,
        message: 'The configured fixture tool could not be started.',
      );
    } on Object {
      if (process != null) {
        process.kill();
      }
      stopwatch.stop();
      return ProcessCommandResult(
        status: ProcessCommandStatus.failed,
        executablePath: request.executablePath,
        arguments: request.arguments,
        exitCode: null,
        stdout: '',
        stderr: '',
        duration: stopwatch.elapsed,
        message: 'The fixture tool process failed.',
      );
    }
  }

  @override
  ProcessOperationFailure? failureFor(
    ProcessCommandResult result, {
    String operation = 'process.spawn',
    String? recoveryHint,
  }) {
    return const ProcessFailureClassifier(
      sourceManager: 'StandaloneFixtureProcessManager',
    ).classify(result, operation: operation, recoveryHint: recoveryHint);
  }
}
