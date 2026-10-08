import 'process_adapter.dart';
import 'process_facts.dart';

enum ProcessCommandStatus { succeeded, failed, timedOut, blocked }

enum ProcessServiceKind { generic, styio, pafio }

enum ProcessFailureKind {
  unsupported,
  executableNotFound,
  permissionDenied,
  timedOut,
  nonZeroExit,
  spawnFailed,
  unknownFailure,
}

class ProcessCommandHandle {
  const ProcessCommandHandle({
    required this.processHandleId,
    required this.sourceManager,
    this.pid,
    this.metadata = const <String, Object?>{},
  });

  final String processHandleId;
  final String sourceManager;
  final int? pid;
  final Map<String, Object?> metadata;

  bool get available => processHandleId.trim().isNotEmpty || pid != null;

  Map<String, Object?> toMetadata() {
    return <String, Object?>{
      ...metadata,
      if (processHandleId.trim().isNotEmpty)
        'processHandleId': processHandleId.trim(),
      if (pid != null) 'pid': pid,
      if (sourceManager.trim().isNotEmpty)
        'processHandleSource': sourceManager.trim(),
    };
  }
}

typedef ProcessCommandStartedCallback =
    void Function(ProcessCommandHandle handle);

class ProcessCommandCancellationResult {
  const ProcessCommandCancellationResult({
    required this.accepted,
    required this.processTerminated,
    required this.message,
    this.exitCode,
    this.metadata = const <String, Object?>{},
  });

  const ProcessCommandCancellationResult.unsupported({
    String message = 'Process cancellation is not available.',
  }) : this(accepted: false, processTerminated: false, message: message);

  final bool accepted;
  final bool processTerminated;
  final String message;
  final int? exitCode;
  final Map<String, Object?> metadata;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'accepted': accepted,
      'processTerminated': processTerminated,
      'message': message,
      if (exitCode != null) 'exitCode': exitCode,
      if (metadata.isNotEmpty) 'metadata': metadata,
    };
  }
}

abstract interface class CancellableProcessManager {
  Future<ProcessCommandCancellationResult> cancelProcess(
    String processHandleId,
  );
}

class ProcessCommandRequest {
  const ProcessCommandRequest({
    required this.executablePath,
    this.arguments = const <String>[],
    this.environment = const <String, String>{},
    this.workingDirectory,
    this.timeout,
    this.standardInput,
    this.serviceKind = ProcessServiceKind.generic,
    this.onStarted,
  });

  final String executablePath;
  final List<String> arguments;
  final Map<String, String> environment;
  final String? workingDirectory;
  final Duration? timeout;
  final String? standardInput;
  final ProcessServiceKind serviceKind;
  final ProcessCommandStartedCallback? onStarted;
}

class ProcessOperationFailure {
  const ProcessOperationFailure({
    required this.kind,
    required this.operation,
    required this.target,
    required this.sourceManager,
    required this.message,
    this.recoveryHint,
  });

  final ProcessFailureKind kind;
  final String operation;
  final String target;
  final String sourceManager;
  final String message;
  final String? recoveryHint;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'kind': kind.name,
      'operation': operation,
      'target': target,
      'sourceManager': sourceManager,
      'message': message,
      if (recoveryHint != null) 'recoveryHint': recoveryHint,
    };
  }
}

class ProcessCommandResult {
  const ProcessCommandResult({
    required this.status,
    required this.executablePath,
    required this.arguments,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.duration,
    this.message,
    this.metadata = const <String, Object?>{},
  });

  final ProcessCommandStatus status;
  final String executablePath;
  final List<String> arguments;
  final int? exitCode;
  final String stdout;
  final String stderr;
  final Duration duration;
  final String? message;

  /// Local process evidence, including identity and output truncation flags.
  ///
  /// After a valid daemon execution receipt, `cleanup` independently records
  /// `operation: process.close`, `sourceManager: vityod`, and a `status` of
  /// `succeeded`, `failed`, or `unconfirmed`, with an optional safe `errorCode`
  /// and boolean `retryable`. Cleanup does not replace the execution outcome.
  /// This metadata is an IDE-local contract, not a daemon wire-schema change.
  final Map<String, Object?> metadata;
  bool get succeeded => status == ProcessCommandStatus.succeeded;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'status': status.name,
      'executablePath': executablePath,
      'arguments': arguments,
      if (exitCode != null) 'exitCode': exitCode,
      'stdout': stdout,
      'stderr': stderr,
      'durationMilliseconds': duration.inMilliseconds,
      if (message != null) 'message': message,
      if (metadata.isNotEmpty) 'metadata': metadata,
      'succeeded': succeeded,
    };
  }
}

class ProcessFailureClassifier {
  const ProcessFailureClassifier({required this.sourceManager});

  final String sourceManager;

  ProcessOperationFailure? classify(
    ProcessCommandResult result, {
    String operation = 'process.spawn',
    String? recoveryHint,
  }) {
    if (result.succeeded) {
      return null;
    }
    return ProcessOperationFailure(
      kind: _kindFor(result),
      operation: operation,
      target: result.executablePath,
      sourceManager: sourceManager,
      message: result.message ?? result.stderr,
      recoveryHint: recoveryHint,
    );
  }

  ProcessFailureKind _kindFor(ProcessCommandResult result) {
    return switch (result.status) {
      ProcessCommandStatus.succeeded => ProcessFailureKind.unknownFailure,
      ProcessCommandStatus.blocked => ProcessFailureKind.unsupported,
      ProcessCommandStatus.timedOut => ProcessFailureKind.timedOut,
      ProcessCommandStatus.failed =>
        result.exitCode == null
            ? ProcessFailureKind.spawnFailed
            : ProcessFailureKind.nonZeroExit,
    };
  }
}

abstract class ProcessManager {
  ProcessFacts get facts;
  ProcessCompatibility get compatibility;
  Future<ProcessCommandResult> run(ProcessCommandRequest request);
  ProcessOperationFailure? failureFor(
    ProcessCommandResult result, {
    String operation = 'process.spawn',
    String? recoveryHint,
  });
}

class UnsupportedProcessManager
    implements ProcessManager, CancellableProcessManager {
  UnsupportedProcessManager({required this.facts})
    : compatibility = ProcessAdapter(facts).adapt();
  @override
  final ProcessFacts facts;
  @override
  final ProcessCompatibility compatibility;
  @override
  Future<ProcessCommandResult> run(ProcessCommandRequest request) async =>
      ProcessCommandResult(
        status: ProcessCommandStatus.blocked,
        executablePath: request.executablePath,
        arguments: request.arguments,
        exitCode: null,
        stdout: '',
        stderr: '',
        duration: Duration.zero,
        message: 'Process execution is not available.',
      );
  @override
  Future<ProcessCommandCancellationResult> cancelProcess(
    String processHandleId,
  ) async => const ProcessCommandCancellationResult.unsupported();
  @override
  ProcessOperationFailure? failureFor(
    ProcessCommandResult result, {
    String operation = 'process.spawn',
    String? recoveryHint,
  }) {
    return const ProcessFailureClassifier(
      sourceManager: 'UnsupportedProcessManager',
    ).classify(result, operation: operation, recoveryHint: recoveryHint);
  }
}
