import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_agent_protocol/vityo_agent_protocol.dart';
import 'package:vityo_app/src/ide/agent_client/agent_client_models.dart';
import 'package:vityo_app/src/ide/agent_client/agent_client_operations.dart';
import 'package:vityo_app/src/ide/agent_client/agent_client_registry.dart';
import 'package:vityo_app/src/ide/editor/document/document_state.dart';
import 'package:vityo_app/src/ide/local_service/vityod_client.dart';
import 'package:vityo_app/src/ide/workspace/workspace_document_store_types.dart';
import 'package:vityo_app/src/view_render/flow_hero/agent_bridge.dart';
import 'package:vityo_app/src/view_render/flow_hero/agent_operations.dart';
import 'package:vityo_app/src/view_render/flow_hero/engine/machine.dart';
import 'package:vityo_daemon_protocol/vityo_daemon_protocol.dart';

void main() {
  test(
    'Flow Hero callbacks read unsaved buffers and commit into the editor',
    () async {
      const path = '/workspace/src/main.styio';
      final engine = WorkbenchController();
      addTearDown(engine.dispose);
      final documents = _MemoryDocumentStore(
        root: '/workspace',
        seed: const <String, DocumentState>{
          'src/main.styio': DocumentState(
            documentId: 'src/main.styio',
            text: 'disk source',
            revision: 4,
          ),
        },
      );
      await engine.attachWorkspaceDocumentStore(documents);
      expect(engine.files.where((file) => file.savable), isEmpty);

      final client = _newClient(_OperationTransport());
      await client.connect();
      final port = FlowHeroAgentOperationPort(
        engine: engine,
        documentStore: documents,
        client: client,
        workspaceId: 'flow-hero',
        workspaceRoot: '/workspace',
      );
      addTearDown(client.dispose);

      expect(await engine.openPath(path), isTrue);
      engine.onBufferChanged('unsaved source\nsecond line', line: 1, column: 1);
      final updates = <int>[];
      engine.addListener(() => updates.add(engine.bufferEpoch));
      final read = await port.dispatch(
        _operation(
          id: 'read-1',
          method: 'fs/read_text_file',
          params: const <String, Object?>{
            'path': 'src/main.styio',
            'line': 2,
            'limit': 1,
          },
        ),
      );
      expect(read['content'], 'second line');
      expect(documents.documents['src/main.styio']!.text, 'disk source');

      final beforeRevision = engine.openedBuffer(path)!.sourceRevision;
      await port.dispatch(
        _operation(
          id: 'write-1',
          method: 'fs/write_text_file',
          params: const <String, Object?>{
            'path': path,
            'content': 'agent source\nreflected',
          },
        ),
      );
      final file = engine.openedBuffer(path)!;
      expect(file.text, 'agent source\nreflected');
      expect(file.sourceRevision, beforeRevision + 1);
      expect(file.documentRevision, 5);
      expect(file.dirty, isFalse);
      expect(documents.documents['src/main.styio']!.text, file.text);
      expect(updates, isNotEmpty);

      documents.replaceExternally(
        'src/main.styio',
        text: 'external update',
        revision: 6,
      );
      engine.onBufferChanged('local stale edit', line: 1, column: 1);
      expect(await engine.saveActive(), isFalse);
      await expectLater(
        port.dispatch(
          _operation(
            id: 'write-stale',
            method: 'fs/write_text_file',
            params: const <String, Object?>{
              'path': path,
              'content': 'agent stale edit',
            },
          ),
        ),
        throwsA(isA<AgentClientOperationFailure>()),
      );
      expect(engine.openedBuffer(path)!.text, 'local stale edit');
      expect(documents.documents['src/main.styio']!.text, 'external update');

      await expectLater(
        port.dispatch(
          _operation(
            id: 'read-demo',
            method: 'fs/read_text_file',
            params: const <String, Object?>{'path': '/workspace/main.styio'},
          ),
        ),
        throwsA(isA<AgentClientOperationFailure>()),
      );
      expect(engine.files.where((file) => file.savable), hasLength(1));
      await expectLater(
        port.dispatch(
          _operation(
            id: 'read-outside',
            method: 'fs/read_text_file',
            params: const <String, Object?>{'path': '/workspace/../outside'},
          ),
        ),
        throwsA(isA<AgentClientOperationFailure>()),
      );
    },
  );

  test(
    'an observed missing path is session-scoped and creates atomically',
    () async {
      const path = '/workspace/src/new.styio';
      final engine = WorkbenchController();
      addTearDown(engine.dispose);
      final documents = _MemoryDocumentStore(root: '/workspace');
      final client = _newClient(_OperationTransport());
      await client.connect();
      final port = FlowHeroAgentOperationPort(
        engine: engine,
        documentStore: documents,
        client: client,
        workspaceId: 'flow-hero',
        workspaceRoot: '/workspace',
      );
      addTearDown(port.close);
      addTearDown(client.dispose);

      final missing = await port
          .dispatch(
            _operation(
              id: 'missing-read',
              method: 'fs/read_text_file',
              params: const <String, Object?>{'path': path},
            ),
          )
          .then<Object?>((_) => null, onError: (Object error) => error);
      expect(missing, isA<AgentClientOperationFailure>());
      final snapshot =
          (missing as AgentClientOperationFailure).data['_meta'] as Map;
      final vendor = snapshot['vityo.dev'] as Map;
      final workspace = vendor['workspaceSnapshot'] as Map;
      expect(workspace['rootId'], 'flow-hero');
      expect(workspace['workspaceId'], 'flow-hero');
      expect(workspace['resourceId'], 'src/new.styio');
      expect(workspace['workspaceRevision'], 0);
      expect(workspace['documentExists'], isFalse);
      expect(workspace.containsKey('documentRevision'), isTrue);
      expect(workspace['documentRevision'], isNull);
      expect(workspace['proposalEligible'], isFalse);

      await expectLater(
        port.dispatch(
          _operation(
            id: 'other-session-write',
            sessionId: 'session-2',
            method: 'fs/write_text_file',
            params: const <String, Object?>{
              'path': path,
              'content': 'unobserved session',
            },
          ),
        ),
        throwsA(
          isA<AgentClientOperationFailure>().having(
            (failure) => failure.code,
            'code',
            'document_snapshot_required',
          ),
        ),
      );
      await port.dispatch(
        _operation(
          id: 'observed-create',
          method: 'fs/write_text_file',
          params: const <String, Object?>{
            'path': path,
            'content': 'created from observed absence',
          },
        ),
      );
      expect(
        documents.documents['src/new.styio']!.text,
        'created from observed absence',
      );
      expect(documents.documents['src/new.styio']!.revision, 1);
      expect(documents.workspaceRevision, 1);
    },
  );

  test(
    'a stale missing-file observation cannot replace a concurrent create',
    () async {
      const path = '/workspace/src/race-new.styio';
      final engine = WorkbenchController();
      addTearDown(engine.dispose);
      final documents = _MemoryDocumentStore(root: '/workspace');
      final client = _newClient(_OperationTransport());
      await client.connect();
      final port = FlowHeroAgentOperationPort(
        engine: engine,
        documentStore: documents,
        client: client,
        workspaceId: 'flow-hero',
        workspaceRoot: '/workspace',
      );
      addTearDown(port.close);
      addTearDown(client.dispose);
      await expectLater(
        port.dispatch(
          _operation(
            id: 'race-missing-read',
            method: 'fs/read_text_file',
            params: const <String, Object?>{'path': path},
          ),
        ),
        throwsA(isA<AgentClientOperationFailure>()),
      );
      await documents.saveDocumentsAtomically(
        const <DocumentState>[
          DocumentState(
            documentId: 'src/race-new.styio',
            text: 'concurrent creation',
            revision: 1,
          ),
        ],
        expectedWorkspaceRevision: 0,
        expectedDocumentRevisions: const <String, int>{'src/race-new.styio': 0},
      );

      await expectLater(
        port.dispatch(
          _operation(
            id: 'race-stale-create',
            method: 'fs/write_text_file',
            params: const <String, Object?>{
              'path': path,
              'content': 'stale overwrite',
            },
          ),
        ),
        throwsA(
          isA<AgentClientOperationFailure>().having(
            (failure) => failure.code,
            'code',
            'document_revision_conflict',
          ),
        ),
      );
      expect(
        documents.documents['src/race-new.styio']!.text,
        'concurrent creation',
      );
    },
  );

  test(
    'a newer user buffer survives an Agent commit already in flight',
    () async {
      const path = '/workspace/src/race.styio';
      final engine = WorkbenchController();
      addTearDown(engine.dispose);
      final documents = _MemoryDocumentStore(
        root: '/workspace',
        seed: const <String, DocumentState>{
          'src/race.styio': DocumentState(
            documentId: 'src/race.styio',
            text: 'initial',
            revision: 2,
          ),
        },
      );
      await engine.attachWorkspaceDocumentStore(documents);
      expect(await engine.openPath(path), isTrue);
      final client = _newClient(_OperationTransport());
      await client.connect();
      final port = FlowHeroAgentOperationPort(
        engine: engine,
        documentStore: documents,
        client: client,
        workspaceId: 'flow-hero',
        workspaceRoot: '/workspace',
      );
      addTearDown(client.dispose);

      await port.dispatch(
        _operation(
          id: 'read-race',
          method: 'fs/read_text_file',
          params: const <String, Object?>{'path': path},
        ),
      );

      final commitStarted = Completer<void>();
      final finishCommit = Completer<void>();
      documents.blockNextCommit(commitStarted, finishCommit);
      final agentWrite = port.dispatch(
        _operation(
          id: 'write-race',
          method: 'fs/write_text_file',
          params: const <String, Object?>{
            'path': path,
            'content': 'agent commit',
          },
        ),
      );
      await commitStarted.future;
      engine.onBufferChanged('newer user edit', line: 1, column: 1);
      finishCommit.complete();
      await agentWrite;

      final file = engine.openedBuffer(path)!;
      expect(file.text, 'newer user edit');
      expect(file.dirty, isTrue);
      expect(file.documentRevision, 3);
      expect(documents.documents['src/race.styio']!.text, 'agent commit');
    },
  );

  test(
    'a paused workspace read cannot authorize overwriting a concurrent write',
    () async {
      const path = '/workspace/src/paused.styio';
      final engine = WorkbenchController();
      addTearDown(engine.dispose);
      final documents = _MemoryDocumentStore(
        root: '/workspace',
        seed: const <String, DocumentState>{
          'src/paused.styio': DocumentState(
            documentId: 'src/paused.styio',
            text: 'read snapshot',
            revision: 2,
          ),
          'src/other.styio': DocumentState(
            documentId: 'src/other.styio',
            text: 'other source',
            revision: 1,
          ),
        },
      );
      await engine.attachWorkspaceDocumentStore(documents);
      final client = _newClient(_OperationTransport());
      await client.connect();
      final port = FlowHeroAgentOperationPort(
        engine: engine,
        documentStore: documents,
        client: client,
        workspaceId: 'flow-hero',
        workspaceRoot: '/workspace',
      );
      addTearDown(client.dispose);

      final readStarted = Completer<void>();
      final finishRead = Completer<void>();
      documents.blockNextRead(readStarted, finishRead);
      final read = port.dispatch(
        _operation(
          id: 'read-paused',
          method: 'fs/read_text_file',
          params: const <String, Object?>{'path': path},
        ),
      );
      await readStarted.future;
      await documents.saveDocumentsAtomically(
        <DocumentState>[
          const DocumentState(
            documentId: '/workspace/src/other.styio',
            text: 'concurrent source',
            revision: 2,
          ),
        ],
        expectedWorkspaceRevision: 0,
        expectedDocumentRevisions: const <String, int>{
          '/workspace/src/other.styio': 1,
        },
      );
      finishRead.complete();
      expect((await read)['content'], 'read snapshot');

      await expectLater(
        port.dispatch(
          _operation(
            id: 'write-from-stale-read',
            method: 'fs/write_text_file',
            params: const <String, Object?>{
              'path': path,
              'content': 'stale replacement',
            },
          ),
        ),
        throwsA(
          isA<AgentClientOperationFailure>().having(
            (failure) => failure.code,
            'code',
            'document_revision_conflict',
          ),
        ),
      );
      expect(documents.documents['src/paused.styio']!.text, 'read snapshot');
      expect(documents.documents['src/paused.styio']!.revision, 2);
      expect(documents.documents['src/other.styio']!.text, 'concurrent source');
    },
  );

  test(
    'the workspace transaction rejects a writer whose observed revision went stale',
    () async {
      const path = '/workspace/src/transaction-race.styio';
      final engine = WorkbenchController();
      addTearDown(engine.dispose);
      final documents = _MemoryDocumentStore(
        root: '/workspace',
        seed: const <String, DocumentState>{
          'src/transaction-race.styio': DocumentState(
            documentId: 'src/transaction-race.styio',
            text: 'initial',
            revision: 2,
          ),
        },
      );
      await engine.attachWorkspaceDocumentStore(documents);
      expect(await engine.openPath(path), isTrue);
      final client = _newClient(_OperationTransport());
      await client.connect();
      final port = FlowHeroAgentOperationPort(
        engine: engine,
        documentStore: documents,
        client: client,
        workspaceId: 'flow-hero',
        workspaceRoot: '/workspace',
      );
      addTearDown(client.dispose);
      await port.dispatch(
        _operation(
          id: 'read-transaction-race',
          method: 'fs/read_text_file',
          params: const <String, Object?>{'path': path},
        ),
      );

      final commitStarted = Completer<void>();
      final finishCommit = Completer<void>();
      documents.blockNextCommit(commitStarted, finishCommit);
      final pendingWrite = port.dispatch(
        _operation(
          id: 'write-transaction-race',
          method: 'fs/write_text_file',
          params: const <String, Object?>{
            'path': path,
            'content': 'Agent replacement',
          },
        ),
      );
      await commitStarted.future;
      await documents.saveDocumentsAtomically(
        <DocumentState>[
          const DocumentState(
            documentId: path,
            text: 'concurrent transaction',
            revision: 3,
          ),
        ],
        expectedWorkspaceRevision: 0,
        expectedDocumentRevisions: const <String, int>{path: 2},
      );
      finishCommit.complete();
      await expectLater(
        pendingWrite,
        throwsA(
          isA<AgentClientOperationFailure>().having(
            (failure) => failure.code,
            'code',
            'document_revision_conflict',
          ),
        ),
      );
      expect(engine.openedBuffer(path)!.text, 'initial');
      expect(
        documents.documents['src/transaction-race.styio']!.text,
        'concurrent transaction',
      );
      expect(documents.documents['src/transaction-race.styio']!.revision, 3);
    },
  );

  test('document read baselines are isolated per Agent session', () async {
    const path = '/workspace/src/session-isolation.styio';
    final engine = WorkbenchController();
    addTearDown(engine.dispose);
    final documents = _MemoryDocumentStore(
      root: '/workspace',
      seed: const <String, DocumentState>{
        'src/session-isolation.styio': DocumentState(
          documentId: 'src/session-isolation.styio',
          text: 'initial',
          revision: 2,
        ),
      },
    );
    await engine.attachWorkspaceDocumentStore(documents);
    expect(await engine.openPath(path), isTrue);
    final client = _newClient(_OperationTransport());
    await client.connect();
    final port = FlowHeroAgentOperationPort(
      engine: engine,
      documentStore: documents,
      client: client,
      workspaceId: 'flow-hero',
      workspaceRoot: '/workspace',
    );
    addTearDown(client.dispose);

    await port.dispatch(
      _operation(
        id: 'session-a-read',
        sessionId: 'session-a',
        method: 'fs/read_text_file',
        params: const <String, Object?>{'path': path},
      ),
    );
    engine.onBufferChanged('new user source', line: 1, column: 1);
    await port.dispatch(
      _operation(
        id: 'session-b-read',
        sessionId: 'session-b',
        method: 'fs/read_text_file',
        params: const <String, Object?>{'path': path},
      ),
    );

    await expectLater(
      port.dispatch(
        _operation(
          id: 'session-a-write',
          sessionId: 'session-a',
          method: 'fs/write_text_file',
          params: const <String, Object?>{
            'path': path,
            'content': 'stale session A',
          },
        ),
      ),
      throwsA(
        isA<AgentClientOperationFailure>().having(
          (failure) => failure.code,
          'code',
          'document_revision_conflict',
        ),
      ),
    );
    await port.dispatch(
      _operation(
        id: 'session-b-write',
        sessionId: 'session-b',
        method: 'fs/write_text_file',
        params: const <String, Object?>{
          'path': path,
          'content': 'session B replacement',
        },
      ),
    );
    expect(engine.openedBuffer(path)!.text, 'session B replacement');
    expect(
      documents.documents['src/session-isolation.styio']!.text,
      'session B replacement',
    );
  });

  test(
    'workspace proposal Apply commits and Reject leaves source unchanged',
    () async {
      const path = '/workspace/src/proposed.styio';
      final engine = WorkbenchController();
      addTearDown(engine.dispose);
      final documents = _MemoryDocumentStore(
        root: '/workspace',
        seed: const <String, DocumentState>{
          'src/proposed.styio': DocumentState(
            documentId: 'src/proposed.styio',
            text: 'keep old value\n',
            revision: 4,
          ),
        },
      );
      await engine.attachWorkspaceDocumentStore(documents);
      expect(await engine.openPath(path), isTrue);
      final client = _newClient(_OperationTransport());
      await client.connect();
      final port = FlowHeroAgentOperationPort(
        engine: engine,
        documentStore: documents,
        client: client,
        workspaceId: 'flow-hero',
        workspaceRoot: '/workspace',
      );
      addTearDown(port.close);
      addTearDown(client.dispose);

      await port.dispatch(
        _operation(
          id: 'proposal-source-read',
          method: 'fs/read_text_file',
          params: const <String, Object?>{'path': path},
        ),
      );
      final applyProposal = VityoWorkspaceChangeProposal(
        id: 'apply-proposal',
        baseWorkspaceRevision: 0,
        resources: <VityoResourceChange>[
          VityoResourceChange(
            resourceId: 'src/proposed.styio',
            baseDocumentRevision: 4,
            edits: <VityoTextChange>[
              VityoTextChange(start: 5, end: 8, replacement: 'new'),
            ],
          ),
        ],
      );
      final applyReviewFuture = port.proposalReviews.first;
      final applyResultFuture = port.dispatch(
        _operation(
          id: 'apply-operation',
          method: VityoCapability.workspaceChangeProposal,
          params: <String, Object?>{
            'sessionId': 'remote-1',
            'proposal': applyProposal.toJson(),
          },
        ),
      );
      final applyReview = await applyReviewFuture;
      expect(applyReview.resources.single.edits.single.beforeText, 'old');
      expect(applyReview.resources.single.edits.single.replacement, 'new');
      port.decideWorkspaceProposal(applyReview.reviewId, apply: true);
      final applied = await applyResultFuture;
      expect(applied, <String, Object?>{
        'proposalId': 'apply-proposal',
        'outcome': 'committed',
        'workspaceRevision': 1,
        'documentRevisions': <String, int>{'src/proposed.styio': 5},
      });
      expect(
        documents.documents['src/proposed.styio']!.text,
        'keep new value\n',
      );
      expect(documents.documents['src/proposed.styio']!.revision, 5);
      expect(engine.openedBuffer(path)!.text, 'keep new value\n');

      await port.dispatch(
        _operation(
          id: 'proposal-source-read-again',
          method: 'fs/read_text_file',
          params: const <String, Object?>{'path': path},
        ),
      );
      final rejectProposal = VityoWorkspaceChangeProposal(
        id: 'reject-proposal',
        baseWorkspaceRevision: 1,
        resources: <VityoResourceChange>[
          VityoResourceChange(
            resourceId: 'src/proposed.styio',
            baseDocumentRevision: 5,
            edits: <VityoTextChange>[
              VityoTextChange(start: 5, end: 8, replacement: 'bad'),
            ],
          ),
        ],
      );
      final rejectReviewFuture = port.proposalReviews.first;
      final rejectResultFuture = port.dispatch(
        _operation(
          id: 'reject-operation',
          method: VityoCapability.workspaceChangeProposal,
          params: <String, Object?>{
            'sessionId': 'remote-1',
            'proposal': rejectProposal.toJson(),
          },
        ),
      );
      final rejectReview = await rejectReviewFuture;
      port.decideWorkspaceProposal(rejectReview.reviewId, apply: false);
      expect(await rejectResultFuture, <String, Object?>{
        'proposalId': 'reject-proposal',
        'outcome': 'rejected',
      });
      expect(
        documents.documents['src/proposed.styio']!.text,
        'keep new value\n',
      );
      expect(documents.workspaceRevision, 1);
    },
  );

  test('proposal Apply rechecks source after review before commit', () async {
    const path = '/workspace/src/review-race.styio';
    final engine = WorkbenchController();
    addTearDown(engine.dispose);
    final documents = _MemoryDocumentStore(
      root: '/workspace',
      seed: const <String, DocumentState>{
        'src/review-race.styio': DocumentState(
          documentId: 'src/review-race.styio',
          text: 'original source',
          revision: 1,
        ),
      },
    );
    await engine.attachWorkspaceDocumentStore(documents);
    expect(await engine.openPath(path), isTrue);
    final client = _newClient(_OperationTransport());
    await client.connect();
    final port = FlowHeroAgentOperationPort(
      engine: engine,
      documentStore: documents,
      client: client,
      workspaceId: 'flow-hero',
      workspaceRoot: '/workspace',
    );
    addTearDown(port.close);
    addTearDown(client.dispose);
    await port.dispatch(
      _operation(
        id: 'review-race-read',
        method: 'fs/read_text_file',
        params: const <String, Object?>{'path': path},
      ),
    );
    final proposal = VityoWorkspaceChangeProposal(
      id: 'stale-review',
      baseWorkspaceRevision: 0,
      resources: <VityoResourceChange>[
        VityoResourceChange(
          resourceId: 'src/review-race.styio',
          baseDocumentRevision: 1,
          edits: <VityoTextChange>[
            VityoTextChange(start: 0, end: 8, replacement: 'changed'),
          ],
        ),
      ],
    );
    final reviewFuture = port.proposalReviews.first;
    final resultFuture = port.dispatch(
      _operation(
        id: 'stale-review-operation',
        method: VityoCapability.workspaceChangeProposal,
        params: <String, Object?>{
          'sessionId': 'remote-1',
          'proposal': proposal.toJson(),
        },
      ),
    );
    final review = await reviewFuture;
    documents.replaceExternally(
      'src/review-race.styio',
      text: 'concurrent source',
      revision: 2,
    );
    port.decideWorkspaceProposal(review.reviewId, apply: true);

    expect(await resultFuture, <String, Object?>{
      'proposalId': 'stale-review',
      'outcome': 'conflict',
      'code': 'revision_conflict',
    });
    expect(
      documents.documents['src/review-race.styio']!.text,
      'concurrent source',
    );
    expect(documents.workspaceRevision, 1);
  });

  test(
    'workspace binding keeps dirty editor source on an external conflict',
    () async {
      final directory = await Directory.systemTemp.createTemp('flow-hero-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/src/conflict.styio';
      final source = File(path)..createSync(recursive: true);
      source.writeAsStringSync('opened source');
      final engine = WorkbenchController();
      addTearDown(engine.dispose);
      expect(await engine.openPath(path), isTrue);
      engine.onBufferChanged('unsaved local source', line: 1, column: 1);
      final documents = _MemoryDocumentStore(
        root: directory.path,
        seed: const <String, DocumentState>{
          'src/conflict.styio': DocumentState(
            documentId: 'src/conflict.styio',
            text: 'external source',
            revision: 9,
          ),
        },
      );

      await engine.attachWorkspaceDocumentStore(documents);

      final file = engine.openedBuffer(path)!;
      expect(file.text, 'unsaved local source');
      expect(file.dirty, isTrue);
      expect(file.documentRevision, isNull);
      expect(await engine.saveActive(), isFalse);
      expect(
        documents.documents['src/conflict.styio']!.text,
        'external source',
      );
    },
  );

  test(
    'registry forwards standard callbacks and preserves operation correlation',
    () async {
      final transport = _OperationTransport(includeClientOperation: true);
      final client = _newClient(transport);
      await client.connect();
      expect(client.state.canDispatch, isTrue);
      final port = _OperationProbe();
      final registry = AgentClientRegistry(
        descriptors: <String, AgentLaunchDescriptor>{
          'fixture-agent': AgentLaunchDescriptor(
            id: 'fixture-agent',
            executable: 'fixture-agent',
            arguments: const <String>[],
            workingDirectory: '/workspace',
          ),
        },
        client: client,
        operationPort: port,
        policy: flowHeroAgentClientPolicy,
      );

      final session = await registry.newSession(
        agentId: 'fixture-agent',
        cwd: Uri.directory('/workspace'),
      );
      final result = await session.prompt('read source');
      expect(result.stopReason, 'end_turn');
      final operation = await port.received.future;
      final response = await transport.clientOperationResponse.future;
      final open = transport.requests.singleWhere(
        (request) => request.method == 'agent.connection.open',
      );
      expect(open.params['clientCapabilities'], <String, Object?>{
        'fs': <String, Object?>{'readTextFile': true, 'writeTextFile': true},
        'terminal': true,
        '_meta': <String, Object?>{
          'vityo.dev': <String, Object?>{
            'extensions': <String>[VityoCapability.workspaceChangeProposal],
          },
        },
      });
      expect(open.params['allowedExtensions'], <String>[
        VityoCapability.workspaceChangeProposal,
      ]);
      expect(operation.operationId, 'operation-1');
      expect(response.method, 'agent.acp.client_operation.respond');
      expect(response.params['sessionId'], session.id);
      expect(response.params['operationId'], operation.operationId);
      expect(response.params['response'], <String, Object?>{
        'content': 'buffer source',
      });
      await registry.close();
      await client.dispose();
    },
  );

  test(
    'failed callback delivery is reported without an unhandled future',
    () async {
      final transport = _OperationTransport(
        includeClientOperation: true,
        failOperationResponses: true,
      );
      final client = _newClient(transport);
      await client.connect();
      final port = _OperationProbe();
      final registry = AgentClientRegistry(
        descriptors: <String, AgentLaunchDescriptor>{
          'fixture-agent': AgentLaunchDescriptor(
            id: 'fixture-agent',
            executable: 'fixture-agent',
            arguments: const <String>[],
            workingDirectory: '/workspace',
          ),
        },
        client: client,
        operationPort: port,
      );
      final session = await registry.newSession(
        agentId: 'fixture-agent',
        cwd: Uri.directory('/workspace'),
      );
      final deliveryFailure = Completer<AgentSessionUpdate>();
      final updates = session.updates.listen((update) {
        if (update.kind == 'client_operation.delivery_failed' &&
            !deliveryFailure.isCompleted) {
          deliveryFailure.complete(update);
        }
      });

      await session.prompt('read source');
      final update = await deliveryFailure.future.timeout(
        const Duration(seconds: 1),
      );
      expect(update.payload['operationId'], 'operation-1');
      expect(update.payload['failureCode'], 'service_unavailable');
      expect(
        transport.requests
            .where(
              (request) =>
                  request.method == 'agent.acp.client_operation.respond',
            )
            .map((request) => request.params['operationId']),
        <Object?>['operation-1'],
      );

      await updates.cancel();
      await registry.close();
      await client.dispose();
    },
  );

  for (final ending in [
    'disconnect',
    'cancel',
    'session-close',
    'release',
    'port-close',
    'stream-close',
  ]) {
    test('pending terminal wait ends on $ending', () async {
      final transport = _OperationTransport(emitTerminalOutput: false);
      final client = _newClient(transport);
      await client.connect();
      final engine = WorkbenchController();
      final port = FlowHeroAgentOperationPort(
        engine: engine,
        documentStore: _MemoryDocumentStore(root: '/workspace'),
        client: client,
        workspaceId: 'flow-hero',
        workspaceRoot: '/workspace',
      );
      addTearDown(engine.dispose);
      addTearDown(client.dispose);
      final created = await port.dispatch(
        _operation(
          id: 'create-waiting-terminal',
          method: 'terminal/create',
          params: const {'sessionId': 'session-1', 'command': 'shell'},
        ),
      );
      final params = <String, Object?>{
        'sessionId': 'session-1',
        'terminalId': created['terminalId'],
      };
      final waiting = expectLater(
        port.dispatch(
          _operation(
            id: 'wait',
            method: 'terminal/wait_for_exit',
            params: params,
          ),
        ),
        throwsA(
          isA<AgentClientOperationFailure>().having(
            (failure) => failure.code,
            'code',
            'terminal_wait_interrupted',
          ),
        ),
      );
      await transport.terminalCredit.future;
      switch (ending) {
        case 'disconnect':
          await client.close();
        case 'cancel':
          port.cancelSessionOperations('session-1');
        case 'session-close':
          await port.closeSessionOperations('session-1');
        case 'release':
          await port.dispatch(
            _operation(
              id: 'release',
              method: 'terminal/release',
              params: params,
            ),
          );
        case 'port-close':
          await port.close();
        case 'stream-close':
          await transport._binary.close();
      }
      await waiting;
    });
  }

  test('terminal output remains readable after kill until release', () async {
    final transport = _OperationTransport();
    final client = _newClient(transport);
    await client.connect();
    expect(client.state.canDispatch, isTrue);
    final port = FlowHeroAgentOperationPort(
      engine: WorkbenchController(),
      documentStore: _MemoryDocumentStore(root: '/workspace'),
      client: client,
      workspaceId: 'flow-hero',
      workspaceRoot: '/workspace',
    );
    addTearDown(client.dispose);

    final created = await port.dispatch(
      _operation(
        id: 'terminal-create',
        method: 'terminal/create',
        params: const <String, Object?>{
          'sessionId': 'session-1',
          'command': 'shell',
          'cwd': 'src',
        },
      ),
    );
    final terminalId = created['terminalId']! as String;
    expect(
      transport.requests
          .singleWhere((request) => request.method == 'pty.start')
          .params['workingDirectory'],
      '/workspace/src',
    );
    await expectLater(
      port.dispatch(
        AgentClientOperation(
          operationId: 'terminal-cross-session',
          sessionId: 'session-2',
          method: 'terminal/output',
          params: <String, Object?>{
            'sessionId': 'session-2',
            'terminalId': terminalId,
          },
        ),
      ),
      throwsA(isA<AgentClientOperationFailure>()),
    );
    await port.dispatch(
      _operation(
        id: 'terminal-kill',
        method: 'terminal/kill',
        params: <String, Object?>{
          'sessionId': 'session-1',
          'terminalId': terminalId,
        },
      ),
    );
    final output = await port.dispatch(
      _operation(
        id: 'terminal-output',
        method: 'terminal/output',
        params: <String, Object?>{
          'sessionId': 'session-1',
          'terminalId': terminalId,
        },
      ),
    );
    expect(output['output'], 'retained after kill');
    expect(output['exitStatus'], <String, Object?>{
      'exitCode': 137,
      'signal': null,
    });
    final waited = await port.dispatch(
      _operation(
        id: 'terminal-wait',
        method: 'terminal/wait_for_exit',
        params: <String, Object?>{
          'sessionId': 'session-1',
          'terminalId': terminalId,
        },
      ),
    );
    expect(waited['exitCode'], 137);
    await port.dispatch(
      _operation(
        id: 'terminal-release',
        method: 'terminal/release',
        params: <String, Object?>{
          'sessionId': 'session-1',
          'terminalId': terminalId,
        },
      ),
    );
    expect(
      transport.requests.map((request) => request.method),
      containsAllInOrder(<String>['pty.start', 'pty.kill', 'pty.close']),
    );
    await expectLater(
      port.dispatch(
        _operation(
          id: 'terminal-after-release',
          method: 'terminal/output',
          params: <String, Object?>{
            'sessionId': 'session-1',
            'terminalId': terminalId,
          },
        ),
      ),
      throwsA(isA<AgentClientOperationFailure>()),
    );

    final completed = await port.dispatch(
      _operation(
        id: 'terminal-completed-create',
        method: 'terminal/create',
        params: const <String, Object?>{
          'sessionId': 'session-1',
          'command': 'already-finished',
        },
      ),
    );
    final completedTerminalId = completed['terminalId']! as String;
    final exitStatus = await port.dispatch(
      _operation(
        id: 'terminal-completed-wait',
        method: 'terminal/wait_for_exit',
        params: <String, Object?>{
          'sessionId': 'session-1',
          'terminalId': completedTerminalId,
        },
      ),
    );
    expect(exitStatus['exitCode'], 137);
    final killCount = transport.requests
        .where((request) => request.method == 'pty.kill')
        .length;
    await port.dispatch(
      _operation(
        id: 'terminal-completed-kill',
        method: 'terminal/kill',
        params: <String, Object?>{
          'sessionId': 'session-1',
          'terminalId': completedTerminalId,
        },
      ),
    );
    expect(
      transport.requests
          .where((request) => request.method == 'pty.kill')
          .length,
      killCount,
    );
    await port.dispatch(
      _operation(
        id: 'terminal-completed-release',
        method: 'terminal/release',
        params: <String, Object?>{
          'sessionId': 'session-1',
          'terminalId': completedTerminalId,
        },
      ),
    );
  });
}

AgentClientOperation _operation({
  required String id,
  String sessionId = 'session-1',
  required String method,
  required Map<String, Object?> params,
}) => AgentClientOperation(
  operationId: id,
  sessionId: sessionId,
  method: method,
  params: params,
);

VityodClient _newClient(_OperationTransport transport) =>
    VityodClient(transport: transport, clientInstanceId: 'operation-test');

final class _MemoryDocumentStore implements WorkspaceDocumentOperationStore {
  _MemoryDocumentStore({required this.root, Map<String, DocumentState>? seed})
    : documents = Map<String, DocumentState>.from(seed ?? const {});

  final String root;
  final Map<String, DocumentState> documents;
  int workspaceRevision = 0;
  Completer<void>? _commitStarted;
  Completer<void>? _finishCommit;
  Completer<void>? _readStarted;
  Completer<void>? _finishRead;

  void blockNextCommit(Completer<void> started, Completer<void> finish) {
    _commitStarted = started;
    _finishCommit = finish;
  }

  void blockNextRead(Completer<void> started, Completer<void> finish) {
    _readStarted = started;
    _finishRead = finish;
  }

  void replaceExternally(
    String relativePath, {
    required String text,
    required int revision,
  }) {
    workspaceRevision += 1;
    documents[relativePath] = DocumentState(
      documentId: relativePath,
      text: text,
      revision: revision,
      workspaceRevision: workspaceRevision,
      baseDocumentRevision: revision,
    );
  }

  @override
  Future<DocumentState> loadDocument(String path) async {
    final relative = relativeDocumentPath(path);
    final snapshot = await readWorkspaceSnapshot(path);
    return snapshot.document ??
        DocumentState(
          documentId: relative,
          text: '',
          revision: 0,
          workspaceRevision: snapshot.workspaceRevision,
          baseDocumentRevision: 0,
        );
  }

  @override
  Future<WorkspaceDocumentOperationSnapshot> readWorkspaceSnapshot(
    String path,
  ) async {
    final relative = relativeDocumentPath(path);
    final document = documents[relative];
    final snapshot = WorkspaceDocumentOperationSnapshot(
      resourceId: relative,
      workspaceRevision: workspaceRevision,
      document: document == null
          ? null
          : DocumentState(
              documentId: relative,
              text: document.text,
              revision: document.revision,
              workspaceRevision: workspaceRevision,
              baseDocumentRevision: document.revision,
            ),
    );
    final started = _readStarted;
    final finish = _finishRead;
    if (started != null && finish != null) {
      _readStarted = null;
      _finishRead = null;
      started.complete();
      await finish.future;
    }
    return snapshot;
  }

  @override
  Future<DocumentState?> readExistingDocument(String path) async {
    final relative = relativeDocumentPath(path);
    final document = documents[relative];
    if (document == null) return null;
    return DocumentState(
      documentId: relative,
      text: document.text,
      revision: document.revision,
      workspaceRevision: workspaceRevision,
      baseDocumentRevision: document.revision,
    );
  }

  @override
  Future<void> saveDocument(DocumentState document) async {
    final snapshot = await readWorkspaceSnapshot(document.documentId);
    await saveDocumentsAtomically(
      <DocumentState>[document],
      expectedWorkspaceRevision: snapshot.workspaceRevision,
      expectedDocumentRevisions: <String, int>{
        document.documentId: snapshot.document?.revision ?? 0,
      },
    );
  }

  @override
  Future<WorkspaceDocumentCommitReceipt> saveDocumentsAtomically(
    Iterable<DocumentState> changes, {
    required int expectedWorkspaceRevision,
    required Map<String, int> expectedDocumentRevisions,
  }) async {
    final started = _commitStarted;
    final finish = _finishCommit;
    if (started != null && finish != null) {
      _commitStarted = null;
      _finishCommit = null;
      started.complete();
      await finish.future;
    }
    if (workspaceRevision != expectedWorkspaceRevision) {
      throw const VityodWorkspaceStoreFailure('workspace_revision_conflict');
    }
    final pending = changes.toList(growable: false);
    final nextWorkspaceRevision = workspaceRevision + 1;
    final revisions = <String, int>{};
    for (final change in pending) {
      final relative = relativeDocumentPath(change.documentId);
      final current = documents[relative];
      final expected = expectedDocumentRevisions[change.documentId];
      if (expected == null) throw StateError('missing expected revision');
      if ((current?.revision ?? 0) != expected) {
        throw const VityodWorkspaceStoreFailure('document_revision_conflict');
      }
      final revision = expected + 1;
      documents[relative] = DocumentState(
        documentId: relative,
        text: change.text,
        revision: revision,
        workspaceRevision: nextWorkspaceRevision,
        baseDocumentRevision: revision,
      );
      revisions[relative] = revision;
    }
    workspaceRevision = nextWorkspaceRevision;
    return WorkspaceDocumentCommitReceipt(
      workspaceRevision: workspaceRevision,
      documentRevisions: revisions,
    );
  }

  @override
  Future<bool> deleteDocument(String path) async =>
      documents.remove(relativeDocumentPath(path)) != null;

  @override
  Future<bool> documentExists(String path) async =>
      documents.containsKey(relativeDocumentPath(path));

  @override
  String? filePathForDocumentId(String documentId) =>
      '$root/${relativeDocumentPath(documentId)}';

  @override
  String relativeDocumentPath(String path) {
    final normalizedRoot = root.replaceFirst(RegExp(r'/+$'), '');
    final normalizedPath = path.replaceAll(r'\', '/');
    if (normalizedPath.split('/').contains('..')) {
      throw const FormatException('path escapes the workspace');
    }
    if (normalizedPath == normalizedRoot) {
      throw const FormatException('workspace root is not a document');
    }
    if (normalizedPath.startsWith('$normalizedRoot/')) {
      return normalizedPath.substring(normalizedRoot.length + 1);
    }
    if (normalizedPath.startsWith('/')) {
      throw const FormatException('path escapes the workspace');
    }
    return normalizedPath;
  }
}

final class _OperationTransport implements VityodTransport {
  _OperationTransport({
    this.includeClientOperation = false,
    this.failOperationResponses = false,
    this.emitTerminalOutput = true,
  });

  final bool includeClientOperation;
  final bool failOperationResponses;
  final bool emitTerminalOutput;
  final Completer<void> terminalCredit = Completer<void>();
  final StreamController<Uint8List> _control =
      StreamController<Uint8List>.broadcast(sync: true);
  final StreamController<VityodBinaryFrame> _binary =
      StreamController<VityodBinaryFrame>.broadcast(sync: true);
  final List<VityodControlEnvelope> requests = <VityodControlEnvelope>[];
  final Completer<VityodControlEnvelope> clientOperationResponse =
      Completer<VityodControlEnvelope>();
  var _connected = false;
  var _terminalOutputSequence = 0;

  @override
  Stream<Uint8List> get incomingControl => _control.stream;

  @override
  Stream<VityodBinaryFrame> get incomingBinary => _binary.stream;

  @override
  Future<String> connect() async {
    _connected = true;
    return 'operation-test-daemon';
  }

  @override
  Future<void> sendControl(Uint8List payload) async {
    if (!_connected) throw StateError('disconnected');
    final request = VityodControlCodec.decode(payload);
    requests.add(request);
    if (request.method == 'agent.acp.client_operation.respond' &&
        !clientOperationResponse.isCompleted) {
      clientOperationResponse.complete(request);
    }
    if (request.requestId == null) return;
    final result = switch (request.method) {
      'handshake.negotiate' => <String, Object?>{
        'selectedProtocolVersion': vityodProtocolVersion,
        'capabilities': vityodCoreCapabilities,
      },
      'event.resume' => <String, Object?>{
        'eventCursor': 0,
        'workspaceRevision': 0,
        'capabilities': vityodCoreCapabilities,
        'events': const <Object?>[],
        'activeTerminalIds': const <String>[],
        'activeTaskIds': const <String>[],
        'activeAgentSessionIds': const <String>[],
        'dirtyBuffers': const <Object?>[],
        'eventDigest': 'cbf29ce484222325',
      },
      'agent.connection.open' => <String, Object?>{
        'agentId': request.params['agentId'],
        'protocolVersion': acpProtocolVersion,
        'generation': 1,
        'capabilities': <String>[],
      },
      'agent.session.new' => <String, Object?>{
        'sessionId': 'session-1',
        'remoteSessionId': 'remote-1',
        'generation': 1,
      },
      'agent.session.prompt' => const <String, Object?>{},
      'agent.session.poll' => <String, Object?>{
        'events': const <Object?>[],
        'permissions': const <Object?>[],
        'clientOperations': includeClientOperation
            ? <Object?>[
                <String, Object?>{
                  'operationId': 'operation-1',
                  'sessionId': 'session-1',
                  'method': 'fs/read_text_file',
                  'params': <String, Object?>{
                    'sessionId': 'remote-1',
                    'path': '/workspace/src/app.styio',
                  },
                },
              ]
            : const <Object?>[],
        'promptResult': const <String, Object?>{'stopReason': 'end_turn'},
      },
      'agent.acp.client_operation.respond' => const <String, Object?>{
        'accepted': true,
      },
      'agent.connection.close' => const <String, Object?>{
        'terminated': true,
        'forced': false,
        'exitCode': 0,
      },
      'pty.start' => const <String, Object?>{'streamId': 7},
      'pty.kill' => const <String, Object?>{'exitCode': 137},
      'pty.close' => const <String, Object?>{
        'state': 'closed',
        'exitCode': 137,
      },
      _ => const <String, Object?>{},
    };
    final operationResponseRejected =
        failOperationResponses &&
        request.method == 'agent.acp.client_operation.respond';
    _control.add(
      VityodControlCodec.encode(
        VityodControlEnvelope(
          method:
              '${request.method}.${operationResponseRejected ? 'error' : 'result'}',
          requestId: request.requestId,
          clientInstanceId: request.clientInstanceId,
          idempotencyKey: request.idempotencyKey,
          deadlineUnixMillis: request.deadlineUnixMillis,
          params: operationResponseRejected
              ? const <String, Object?>{'errorCode': 'service_unavailable'}
              : result,
        ),
      ),
    );
  }

  @override
  Future<void> sendBinary(VityodBinaryFrame frame) async {
    if (!_connected) throw StateError('disconnected');
    if (frame.kind != VityodFrameKind.credit) return;
    if (!terminalCredit.isCompleted) terminalCredit.complete();
    if (!emitTerminalOutput) return;
    final payload = Uint8List(4 + utf8.encode('retained after kill').length);
    ByteData.sublistView(payload).setUint32(0, 137, Endian.big);
    payload.setRange(4, payload.length, utf8.encode('retained after kill'));
    _binary.add(
      VityodBinaryFrame(
        kind: VityodFrameKind.pty,
        flags: 2 | 4,
        streamId: frame.streamId,
        sequence: ++_terminalOutputSequence,
        payload: payload,
      ),
    );
  }

  @override
  Future<void> close() async {
    _connected = false;
  }

  @override
  Future<void> dispose() async {
    await close();
    await _control.close();
    await _binary.close();
  }
}

final class _OperationProbe implements AgentClientOperationPort {
  final Completer<AgentClientOperation> received =
      Completer<AgentClientOperation>();

  @override
  AgentClientOperationCapabilities get capabilities =>
      AgentClientOperationCapabilities(
        readTextFile: true,
        writeTextFile: true,
        terminal: true,
        workspaceChangeProposal: true,
      );

  @override
  Future<Map<String, Object?>> dispatch(AgentClientOperation operation) async {
    if (!received.isCompleted) received.complete(operation);
    return <String, Object?>{'content': 'buffer source'};
  }
}
