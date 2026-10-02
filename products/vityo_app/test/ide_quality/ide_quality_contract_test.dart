import 'package:vityo_app/src/ide/agent_client/agent_client.dart';
import 'package:test/test.dart';

void main() {
  test('backpressure byte and event ceilings are enforced together', () async {
    const policy = AgentEventBackpressurePolicy(
      maxQueuedEvents: 2,
      maxQueuedBytes: 512,
      maxHotHistoryEvents: 2,
      maxHotHistoryBytes: 256,
    );
    final reducer = AgentSessionReducer(
      sessionId: 'quality',
      maxBufferedUpdates: 2,
      backpressurePolicy: policy,
    );
    await Future.wait<void>(<Future<void>>[
      for (var index = 0; index < 20; index += 1)
        reducer.reduce(
          AgentSessionUpdate(
            sessionId: 'quality',
            kind: 'turn',
            text: 'event-$index',
            payload: <String, Object?>{
              'id': '$index',
              'content': List<String>.filled(32, 'x').join(),
            },
          ),
        ),
    ]);
    final snapshot = reducer.snapshot;
    expect(snapshot.queuedUpdateCount, 0);
    expect(snapshot.updates.length, lessThanOrEqualTo(2));
    expect(snapshot.bufferedUpdateBytes, lessThanOrEqualTo(256));
    expect(snapshot.acceptedUpdateCount + snapshot.droppedUpdateCount, 20);
    await reducer.close();
  });

}
