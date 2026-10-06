import 'dart:collection';

enum AgentClientOperationKind {
  readTextFile,
  writeTextFile,
  terminal,
  workspaceChangeProposal,
}

final class AgentClientOperationCapabilities {
  AgentClientOperationCapabilities({
    this.readTextFile = false,
    this.writeTextFile = false,
    this.terminal = false,
    this.workspaceChangeProposal = false,
  });

  final bool readTextFile;
  final bool writeTextFile;
  final bool terminal;
  final bool workspaceChangeProposal;

  bool supports(AgentClientOperationKind kind) => switch (kind) {
    AgentClientOperationKind.readTextFile => readTextFile,
    AgentClientOperationKind.writeTextFile => writeTextFile,
    AgentClientOperationKind.terminal => terminal,
    AgentClientOperationKind.workspaceChangeProposal =>
      workspaceChangeProposal,
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'fs': <String, Object?>{
      'readTextFile': readTextFile,
      'writeTextFile': writeTextFile,
    },
    'terminal': terminal,
    '_meta': <String, Object?>{
      'vityo.dev': <String, Object?>{
        'extensions': <String>[
          if (workspaceChangeProposal)
            '_vityo.dev/workspace-change-proposal',
        ],
      },
    },
  };
}

final class AgentClientOperation {
  AgentClientOperation({
    required this.operationId,
    required this.sessionId,
    required this.method,
    required Map<String, Object?> params,
  }) : params = UnmodifiableMapView<String, Object?>(params) {
    if (operationId.isEmpty || sessionId.isEmpty || method.isEmpty) {
      throw const FormatException('Agent client operation is malformed');
    }
  }

  factory AgentClientOperation.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Agent client operation must be an object');
    }
    final value = Map<String, Object?>.from(raw);
    final params = value['params'];
    if (params is! Map) {
      throw const FormatException(
        'Agent client operation params must be an object',
      );
    }
    return AgentClientOperation(
      operationId: _requiredString(value, 'operationId'),
      sessionId: _requiredString(value, 'sessionId'),
      method: _requiredString(value, 'method'),
      params: Map<String, Object?>.from(params),
    );
  }

  final String operationId;
  final String sessionId;
  final String method;
  final Map<String, Object?> params;

  AgentClientOperationKind get kind => switch (method) {
    'fs/read_text_file' => AgentClientOperationKind.readTextFile,
    'fs/write_text_file' => AgentClientOperationKind.writeTextFile,
    'terminal/create' ||
    'terminal/output' ||
    'terminal/wait_for_exit' ||
    'terminal/kill' ||
    'terminal/release' => AgentClientOperationKind.terminal,
    '_vityo.dev/workspace-change-proposal' =>
      AgentClientOperationKind.workspaceChangeProposal,
    _ => throw FormatException('Unsupported Agent operation method: $method'),
  };
}

abstract interface class AgentClientOperationPort {
  AgentClientOperationCapabilities get capabilities;

  Future<Map<String, Object?>> dispatch(AgentClientOperation operation);
}

abstract interface class AgentClientOperationLifecycle {
  void cancelSessionOperations(String sessionId);

  Future<void> closeSessionOperations(String sessionId);
}

final class AgentClientOperationFailure implements Exception {
  AgentClientOperationFailure(
    this.code,
    String message, {
    this.data = const <String, Object?>{},
  }) : message = message.length <= 1024 ? message : message.substring(0, 1024);

  final String code;
  final String message;
  final Map<String, Object?> data;

  @override
  String toString() => 'AgentClientOperationFailure($code)';
}

String _requiredString(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value is String && value.isNotEmpty && value.length <= 1024) return value;
  throw FormatException('$key must be a non-empty bounded string');
}
