import 'dart:convert';
import 'dart:io';

import '../services/observable_topology/observable_delta_model.dart';
import '../services/observable_topology/observable_snapshot_model.dart';
import 'execution_adapter.dart';
import 'pafio_cli_support.dart';
import '../environment/system_compatibility/process/process_manager.dart';

ObservableSnapshotPublisher createObservableSnapshotPublisher({
  ProcessManager? processManager,
}) {
  return IoObservableSnapshotPublisher(processManager: processManager);
}

List<String> observablePublishArgumentList(
  ObservableSnapshotPublishRequest request,
) {
  final args = <String>[
    '--json',
    'check',
    '--manifest-path',
    request.manifestPath,
    '--styio-bin',
    request.compilerBinary,
    '$kObservablePafioEmitOption=${request.schemaVersion}',
    for (final capability in request.requiredCapabilities) ...<String>[
      kObservablePafioCapabilityOption,
      capability,
    ],
  ];
  final parent = request.parentSnapshotPath?.trim() ?? '';
  if (parent.isNotEmpty) {
    args.add(kObservablePafioParentSnapshotOption);
    args.add(parent);
  }
  return args;
}

class IoObservableSnapshotPublisher implements ObservableSnapshotPublisher {
  IoObservableSnapshotPublisher({this.processManager});

  final ProcessManager? processManager;
  final Set<Process> _processes = <Process>{};
  final Set<String> _handles = <String>{};
  int _cancellation = 0;

  @override
  Future<ObservableSnapshotPublishResult> publish(
    ObservableSnapshotPublishRequest request,
  ) async {
    final generation = _cancellation;
    final args = observablePublishArgumentList(request);
    Process? child;
    String? handle;
    try {
      final String output;
      final String errors;
      final int? exitCode;
      final manager = processManager;
      if (manager != null) {
        final result = await manager.run(
          ProcessCommandRequest(
            executablePath: request.pafioBinary,
            arguments: args,
            workingDirectory: request.workspaceRoot,
            serviceKind: ProcessServiceKind.pafio,
            onStarted: (started) {
              handle = started.processHandleId;
              _handles.add(handle!);
              if (generation != _cancellation &&
                  manager is CancellableProcessManager) {
                (manager as CancellableProcessManager).cancelProcess(handle!);
              }
            },
          ),
        );
        output = result.stdout;
        errors = result.stderr;
        exitCode = result.exitCode;
      } else {
        child = await Process.start(
          request.pafioBinary,
          args,
          workingDirectory: request.workspaceRoot,
        );
        _processes.add(child);
        if (generation != _cancellation) child.kill();
        final stdout = child.stdout.transform(utf8.decoder).join();
        final stderr = child.stderr.transform(utf8.decoder).join();
        exitCode = await child.exitCode;
        output = await stdout;
        errors = await stderr;
      }
      if (generation != _cancellation) {
        return ObservableSnapshotPublishResult.cancelled();
      }
      if (exitCode != 0) {
        final payload =
            parseJsonObjectPayload(errors) ?? parseJsonObjectPayload(output);
        final message =
            payload?['message'] as String? ??
            'Pafio check failed while publishing the observable snapshot.';
        final parent = request.parentSnapshotPath?.trim() ?? '';
        return ObservableSnapshotPublishResult.failed(
          reason:
              parent.isNotEmpty &&
                  payload?['category'] == kObservablePafioUsageErrorCategory
              ? ObservableReasonCode.deltaTransportUnavailable
              : ObservableReasonCode.publicationFailed,
          detail: sanitizeObservablePublishDetail(message),
        );
      }
      final result = await _readArtifact(stdout: output, request: request);
      return generation == _cancellation
          ? result
          : ObservableSnapshotPublishResult.cancelled();
    } on Object {
      return ObservableSnapshotPublishResult.failed(
        detail: 'Snapshot process or artifact unavailable.',
      );
    } finally {
      if (child != null) _processes.remove(child);
      if (handle != null) _handles.remove(handle);
    }
  }

  @override
  void cancel() {
    _cancellation++;
    for (final child in _processes) {
      child.kill();
    }
    final manager = processManager;
    if (manager is CancellableProcessManager) {
      for (final handle in _handles) {
        (manager as CancellableProcessManager).cancelProcess(handle);
      }
    }
  }

  Future<ObservableSnapshotPublishResult> _readArtifact({
    required String stdout,
    required ObservableSnapshotPublishRequest request,
  }) async {
    // Pafio prints one success envelope on stdout:
    // {action, command, intent, message, mode, plan, profile, status, styio,
    //  sync, target}. The Styio receipt is the file <plan.build_root>/
    // receipt.json whose artifact list names the snapshot under
    // <plan.artifact_dir>. There is no inline receipt in the envelope.
    final payload = parseJsonObjectPayload(stdout);
    if (payload == null || payload['status'] != 'succeeded') {
      return ObservableSnapshotPublishResult.failed(
        detail:
            'Pafio did not emit a succeeded workflow payload for the snapshot.',
      );
    }
    final plan = payload['plan'];
    final buildRoot = plan is Map ? plan['build_root'] : null;
    if (buildRoot is! String || buildRoot.trim().isEmpty) {
      return ObservableSnapshotPublishResult.failed(
        detail: 'Pafio workflow payload did not name plan.build_root.',
      );
    }
    if (!_isContained(buildRoot, request.workspaceRoot) &&
        (request.outputTree == null ||
            !_isContained(buildRoot, request.outputTree!))) {
      return ObservableSnapshotPublishResult.failed(
        detail: 'Workflow build root is outside the allowed tree.',
      );
    }
    final receiptFile = File('$buildRoot${Platform.pathSeparator}receipt.json');
    if (!await receiptFile.exists()) {
      return ObservableSnapshotPublishResult.failed(
        detail: 'Workflow receipt was not found under the build root.',
      );
    }
    final receiptRaw = parseJsonObjectPayload(await receiptFile.readAsString());
    final receipt = ExecutionReceiptSnapshot.decode(
      receiptRaw,
      fallbackSessionId: 'observable-snapshot',
    );
    if (receipt == null) {
      return ObservableSnapshotPublishResult.failed(
        detail:
            'Workflow receipt rejected: only receipt schema version 1 is supported.',
      );
    }
    final artifactPath = _selectSnapshotArtifact(receipt.artifacts);
    if (artifactPath == null) {
      return ObservableSnapshotPublishResult.failed(
        detail:
            'Workflow receipt did not name an observable static snapshot artifact.',
      );
    }
    if (!_isContained(artifactPath, request.workspaceRoot) &&
        (request.outputTree == null ||
            !_isContained(artifactPath, request.outputTree!))) {
      return ObservableSnapshotPublishResult.failed(
        detail: 'Snapshot artifact path is outside the allowed tree.',
      );
    }
    final file = File(artifactPath);
    if (!await file.exists()) {
      return ObservableSnapshotPublishResult.failed(
        detail: 'Snapshot artifact named by the receipt was not found.',
      );
    }
    final deltaPath = _selectDeltaArtifact(receipt.artifacts);
    if (deltaPath != null) {
      if (!_isContained(deltaPath, request.workspaceRoot) &&
          (request.outputTree == null ||
              !_isContained(deltaPath, request.outputTree!))) {
        return ObservableSnapshotPublishResult.failed(
          detail: 'Delta artifact path is outside the allowed tree.',
        );
      }
      final deltaFile = File(deltaPath);
      if (!await deltaFile.exists()) {
        return ObservableSnapshotPublishResult.failed(
          detail: 'Delta artifact named by the receipt was not found.',
        );
      }
      return ObservableSnapshotPublishResult.succeeded(
        bytes: await file.readAsBytes(),
        artifactPath: artifactPath,
        receipt: receipt,
        deltaBytes: await deltaFile.readAsBytes(),
        degradation: _receiptDegradation(receiptRaw),
      );
    }
    return ObservableSnapshotPublishResult.succeeded(
      bytes: await file.readAsBytes(),
      artifactPath: artifactPath,
      receipt: receipt,
      degradation: _receiptDegradation(receiptRaw),
    );
  }
}

String? _selectSnapshotArtifact(List<String> artifacts) {
  for (final artifact in artifacts) {
    if (artifact.endsWith(kObservableArtifactSuffix)) {
      return artifact;
    }
  }
  return null;
}

String? _selectDeltaArtifact(List<String> artifacts) {
  for (final artifact in artifacts) {
    if (artifact.endsWith(kObservableDeltaArtifactSuffix)) {
      return artifact;
    }
  }
  return null;
}

String? _receiptDegradation(Map<String, dynamic>? receiptRaw) {
  if (receiptRaw == null) {
    return null;
  }
  final field = receiptRaw[kObservableReceiptObservableField];
  if (field is! Map) {
    return null;
  }
  final delta = field[kObservableReceiptDeltaKey];
  if (delta is String && delta.trim().isNotEmpty) {
    return delta.trim();
  }
  return null;
}

/// Producer failure messages can embed absolute paths (Pafio names the
/// compile-plan path in compiler errors). The workbench never displays or
/// persists absolute paths, so absolute-path runs are redacted before the
/// message becomes surface state. Relative paths stay readable.
String sanitizeObservablePublishDetail(String message) {
  return message.replaceAllMapped(
    RegExp(r'(?:[A-Za-z]:[\\/]|/)\S*'),
    (match) => '<path>',
  );
}

bool _isContained(String path, String root) {
  final rootDir = Directory(root);
  if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound ||
      !rootDir.existsSync()) {
    return false;
  }
  final resolvedPath = File(path).resolveSymbolicLinksSync();
  final resolvedRoot = rootDir.resolveSymbolicLinksSync();
  if (resolvedPath == resolvedRoot) {
    return true;
  }
  final separator = Platform.pathSeparator;
  final prefix = resolvedRoot.endsWith(separator)
      ? resolvedRoot
      : '$resolvedRoot$separator';
  return resolvedPath.startsWith(prefix);
}
