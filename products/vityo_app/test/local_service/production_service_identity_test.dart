import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/ide/local_service/vityod_client.dart';
import 'package:vityo_app/src/ide/local_service/vityod_lsp_gateway.dart';
import 'package:vityo_app/src/ide/workspace/workspace_document_store_io.dart';
import 'package:vityo_daemon_protocol/vityo_daemon_protocol.dart';

void main() {
  test(
    'recreated document and LSP owners never replay a previous operation',
    () async {
      final transport = MemoryVityodTransport();
      final client = VityodClient(
        transport: transport,
        clientInstanceId: 'shared',
      );
      await client.connect();
      final keys = <String>{};
      final processIds = <String>{};
      Future<void> respond(String method, Map<String, Object?> result) async {
        await Future<void>.delayed(Duration.zero);
        final request = VityodControlCodec.decode(transport.sent.last);
        expect(request.method, method);
        expect(keys.add(request.idempotencyKey), isTrue);
        if (method == 'lsp.start') {
          expect(
            processIds.add(request.params['processId']! as String),
            isTrue,
          );
        }
        transport.receiveControl(
          VityodControlCodec.encode(
            VityodControlEnvelope(
              method: '$method.result',
              requestId: request.requestId,
              clientInstanceId: 'daemon',
              idempotencyKey: request.idempotencyKey,
              deadlineUnixMillis: 0,
              params: result,
            ),
          ),
        );
      }

      for (var index = 0; index < 2; index++) {
        final store = VityodWorkspaceDocumentStore(
          client: client,
          workspaceId: 'project',
          workspaceRoot: '/workspace',
        );
        final opening = store.open();
        await respond('workspace.open', {'workspaceRevision': index});
        await opening;
        final starting = VityodLspGateway(
          client: client,
        ).start(executable: 'selected-lsp');
        await respond('lsp.start', {});
        final session = await starting;
        expect(processIds, contains(session.processId));
      }
      await client.dispose();
    },
  );
}
