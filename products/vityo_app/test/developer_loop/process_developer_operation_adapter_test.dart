import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/ide/execution/developer_operation_adapter.dart';
import 'package:vityo_app/src/ide/execution/execution_receipt.dart';
import 'package:vityo_app/src/ide/execution/process_developer_operation_adapter.dart';
import 'package:vityo_app/src/ide/local_service/vityod_client.dart';
import 'package:vityo_app/src/ide/workbench/capability_snapshot.dart';
import 'package:vityo_daemon_protocol/vityo_daemon_protocol.dart';

/// Answers the `task.start` / `task.output` exchange a process adapter performs,
/// with a chosen terminal exit status and captured streams.
///
/// The adapter polls until `running` is false, so the first `task.output` reports
/// the task as still running. Requests are answered by method name, and each
/// reply echoes the request id so the client can correlate it.
final class _ScriptedTaskTransport implements VityodTransport {
  _ScriptedTaskTransport({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  final List<String> methods = <String>[];
  int _outputCalls = 0;
  int _sequence = 0;

  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast(sync: true);

  @override
  Stream<Uint8List> get incomingControl => _incoming.stream;

  @override
  Stream<VityodBinaryFrame> get incomingBinary => const Stream<VityodBinaryFrame>.empty();

  @override
  Future<String> connect() async => 'scripted';

  @override
  Future<void> sendControl(Uint8List payload) async {
    final request = jsonDecode(utf8.decode(payload)) as Map<String, Object?>;
    final method = request['method'] as String? ?? '';
    methods.add(method);
    final id = request['id'];
    Map<String, Object?> result;
    switch (method) {
      case 'task.start':
        result = <String, Object?>{'taskId': 'task-1', 'running': true};
      case 'task.output':
        _outputCalls += 1;
        result = _outputCalls == 1
            ? <String, Object?>{'running': true}
            : <String, Object?>{
                'running': false,
                'exitCode': exitCode,
                'stdout': stdout,
                'stderr': stderr,
              };
      default:
        result = <String, Object?>{'ok': true};
    }
    _incoming.add(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': id,
            'result': result,
            'sequence': ++_sequence,
          }),
        ),
      ),
    );
  }

  @override
  Future<void> sendBinary(VityodBinaryFrame frame) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> dispose() async => _incoming.close();
}

IdeCapabilityFact _analyzeCapability() => IdeCapabilityFact(
  id: 'ide.language.analyze',
  domain: IdeCapabilityDomain.language,
  state: IdeCapabilityState.available,
  provenance: 'process-adapter-test',
  message: 'Analyzer adapter is available.',
);

ProcessDeveloperOperationAdapter _adapter(VityodClient client) =>
    ProcessDeveloperOperationAdapter(
      kind: DeveloperOperationKind.analyze,
      capabilities: <IdeCapabilityFact>[_analyzeCapability()],
      executable: '/tools/dart',
      arguments: const <String>['analyze', '--format=machine', 'lib', 'test'],
      workingDirectory: '/workspace',
      client: client,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a non-zero analyzer exit is a failed operation carrying its output', () async {
    final transport = _ScriptedTaskTransport(
      exitCode: 4,
      stdout: 'ERROR|COMPILE_TIME_ERROR|UNDEFINED_IDENTIFIER|lib/main.dart|1|1|1|greeting\n',
      stderr: '',
    );
    final client = VityodClient(
      transport: transport,
      clientInstanceId: 'developer-process-adapter-test',
    );
    addTearDown(client.dispose);

    final result = await _adapter(client).execute(
      DeveloperOperationContext(
        operationId: 'analyze-1',
        workspaceRevision: 1,
        cancellation: DeveloperOperationCancellation(),
      ),
    );

    expect(transport.methods.first, 'task.start');
    expect(result.status, ExecutionReceiptStatus.failed);
    expect(result.exitCode, 4);
    expect(result.provenance, 'vityod-process-adapter');
    expect(result.message, 'Process exited with a non-zero status.');
    expect(result.output.text, contains('UNDEFINED_IDENTIFIER'));
    expect(result.errorOutput.text, isEmpty);
  });

  test('a zero exit is a successful operation', () async {
    final transport = _ScriptedTaskTransport(exitCode: 0, stdout: 'INFO|...\n');
    final client = VityodClient(
      transport: transport,
      clientInstanceId: 'developer-process-adapter-zero',
    );
    addTearDown(client.dispose);

    final result = await _adapter(client).execute(
      DeveloperOperationContext(
        operationId: 'analyze-2',
        workspaceRevision: 1,
        cancellation: DeveloperOperationCancellation(),
      ),
    );

    expect(result.status, ExecutionReceiptStatus.succeeded);
    expect(result.exitCode, 0);
    expect(result.message, 'Process completed successfully.');
  });
}
