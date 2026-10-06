/// Agent-neutral ACP operations backed by Flow Hero's live document owner.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:vityo_daemon_protocol/vityo_daemon_protocol.dart';
import 'package:vityo_agent_protocol/vityo_agent_protocol.dart';

import '../../ide/editor/document/document_state.dart';
import '../../ide/agent_client/agent_client_operations.dart';
import '../../ide/local_service/vityod_client.dart';
import '../../ide/workspace/workspace_document_store_types.dart';
import 'engine/machine.dart';

const int _maxAgentOperationTextBytes = 128 * 1024;

final class FlowHeroAgentOperationPort
    implements AgentClientOperationPort, AgentClientOperationLifecycle {
  FlowHeroAgentOperationPort({
    required WorkbenchController engine,
    required WorkspaceDocumentOperationStore documentStore,
    required VityodClient client,
    required this.workspaceId,
    required this.workspaceRoot,
  }) : _engine = engine,
       _documentStore = documentStore,
       _client = client;

  final WorkbenchController _engine;
  final WorkspaceDocumentOperationStore _documentStore;
  final VityodClient _client;
  final String workspaceId;
  final String workspaceRoot;
  final Map<String, _FlowHeroTerminal> _terminals =
      <String, _FlowHeroTerminal>{};
  final Map<String, int> _sessionOperationGenerations = <String, int>{};
  final Map<String, Map<String, _AgentDocumentBaseline>> _documentBaselines =
      <String, Map<String, _AgentDocumentBaseline>>{};
  final Map<String, _PendingWorkspaceProposal> _pendingProposals =
      <String, _PendingWorkspaceProposal>{};
  final StreamController<FlowHeroWorkspaceChangeReview> _proposalReviews =
      StreamController<FlowHeroWorkspaceChangeReview>.broadcast(sync: true);
  final StreamController<String> _resolvedProposalReviews =
      StreamController<String>.broadcast(sync: true);
  var _documentObservationSequence = 0;
  var _terminalSequence = 0;
  var _closed = false;

  @override
  AgentClientOperationCapabilities get capabilities =>
      AgentClientOperationCapabilities(
        readTextFile: true,
        writeTextFile: true,
        terminal: true,
        workspaceChangeProposal: true,
      );

  Stream<FlowHeroWorkspaceChangeReview> get proposalReviews =>
      _proposalReviews.stream;
  Stream<String> get resolvedProposalReviews => _resolvedProposalReviews.stream;

  @override
  Future<Map<String, Object?>> dispatch(AgentClientOperation operation) async {
    if (_closed) throw _operationPortClosed();
    return switch (operation.kind) {
      AgentClientOperationKind.readTextFile => _readTextFile(operation),
      AgentClientOperationKind.writeTextFile => _writeTextFile(operation),
      AgentClientOperationKind.terminal => _terminal(operation),
      AgentClientOperationKind.workspaceChangeProposal =>
        _workspaceChangeProposal(operation),
    };
  }

  Future<Map<String, Object?>> _readTextFile(
    AgentClientOperation operation,
  ) async {
    final sessionGeneration =
        _sessionOperationGenerations[operation.sessionId] ?? 0;
    final observationSequence = ++_documentObservationSequence;
    final path = _requiredString(operation.params, 'path');
    final relativePath = _resolvePath(path);
    final absolutePath = _absolutePathForRelative(relativePath);
    final file = _engine.openedBuffer(absolutePath);
    final snapshot = await _documentStore.readWorkspaceSnapshot(absolutePath);
    final persistedDocument = snapshot.document;
    if (persistedDocument == null) {
      final sourceRevision = file?.sourceRevision;
      final isDirty = file?.dirty ?? false;
      _recordDocumentBaseline(
        operation.sessionId,
        relativePath,
        observationSequence,
        _AgentDocumentBaseline(
          resourceId: snapshot.resourceId,
          workspaceRevision: snapshot.workspaceRevision,
          persistedRevision: null,
          sourceRevision: sourceRevision,
          isOpenBuffer: file != null,
          isMissing: true,
          isDirty: isDirty,
          proposalEligible: false,
        ),
        sessionGeneration: sessionGeneration,
      );
      throw AgentClientOperationFailure(
        'document_missing',
        'The requested workspace document does not exist.',
        data: <String, Object?>{
          '_meta': <String, Object?>{
            'vityo.dev': <String, Object?>{
              'workspaceSnapshot': _workspaceSnapshotMetadata(
                workspaceId: workspaceId,
                rootId: workspaceId,
                resourceId: snapshot.resourceId,
                workspaceRevision: snapshot.workspaceRevision,
                documentExists: false,
                sourceRevision: sourceRevision,
                sourceKind: file == null ? 'workspace' : 'openBuffer',
                sourceDirty: isDirty,
                proposalEligible: false,
              ),
            },
          },
        },
      );
    }
    final source = file?.text ?? persistedDocument.text;
    final line = _optionalPositiveInt(operation.params, 'line');
    final limit = _optionalPositiveInt(operation.params, 'limit');
    final isWholeSourceRead = line == null && limit == null;
    final sourceIsPersisted =
        file == null ||
        (!file.dirty &&
            file.documentRevision == persistedDocument.revision &&
            file.persistedText == persistedDocument.text);
    final proposalEligible = isWholeSourceRead && sourceIsPersisted;
    final baseline = _AgentDocumentBaseline(
      resourceId: snapshot.resourceId,
      workspaceRevision: snapshot.workspaceRevision,
      persistedRevision: persistedDocument.revision,
      sourceRevision: file?.sourceRevision,
      isOpenBuffer: file != null,
      isMissing: false,
      isDirty: file?.dirty ?? false,
      proposalEligible: proposalEligible,
    );
    _recordDocumentBaseline(
      operation.sessionId,
      snapshot.resourceId,
      observationSequence,
      baseline,
      sessionGeneration: sessionGeneration,
    );
    final content = _selectTextLines(source, line ?? 1, limit);
    return <String, Object?>{
      'content': content,
      '_meta': <String, Object?>{
        'vityo.dev': <String, Object?>{
          'workspaceSnapshot': _workspaceSnapshotMetadata(
            workspaceId: workspaceId,
            rootId: workspaceId,
            resourceId: snapshot.resourceId,
            workspaceRevision: snapshot.workspaceRevision,
            documentExists: true,
            documentRevision: persistedDocument.revision,
            sourceRevision: file?.sourceRevision,
            sourceKind: file == null ? 'workspace' : 'openBuffer',
            sourceDirty: file?.dirty ?? false,
            proposalEligible: proposalEligible,
          ),
        },
      },
    };
  }

  Future<Map<String, Object?>> _writeTextFile(
    AgentClientOperation operation,
  ) async {
    final sessionGeneration =
        _sessionOperationGenerations[operation.sessionId] ?? 0;
    final observationSequence = ++_documentObservationSequence;
    final path = _requiredString(operation.params, 'path');
    final content = _requiredString(
      operation.params,
      'content',
      allowEmpty: true,
    );
    if (utf8.encode(content).length > _maxAgentOperationTextBytes) {
      throw AgentClientOperationFailure(
        'document_too_large',
        'The requested document exceeds the Agent protocol message limit.',
      );
    }
    final relativePath = _resolvePath(path);
    final absolutePath = _absolutePathForRelative(relativePath);
    final sessionBaselines = _documentBaselines[operation.sessionId];
    final baseline = sessionBaselines?[relativePath];
    if (sessionBaselines == null || baseline == null) {
      throw AgentClientOperationFailure(
        'document_snapshot_required',
        'Read the workspace document before writing it.',
      );
    }
    final storeGeneration = _engine.documentStoreGeneration;
    final openBuffer = _engine.openedBuffer(absolutePath);
    final expectedSourceRevision = baseline.sourceRevision;
    if (baseline.isOpenBuffer &&
        (openBuffer == null ||
            openBuffer.sourceRevision != expectedSourceRevision ||
            openBuffer.documentRevision != baseline.persistedRevision)) {
      sessionBaselines.remove(relativePath);
      throw _documentRevisionConflict();
    }
    if (!baseline.isOpenBuffer && openBuffer != null) {
      sessionBaselines.remove(relativePath);
      throw _documentRevisionConflict();
    }
    final currentSnapshot = await _documentStore.readWorkspaceSnapshot(
      absolutePath,
    );
    final currentDocument = currentSnapshot.document;
    final bufferAfterRead = _engine.openedBuffer(absolutePath);
    if (baseline.isMissing != (currentDocument == null) ||
        baseline.workspaceRevision != currentSnapshot.workspaceRevision ||
        baseline.resourceId != currentSnapshot.resourceId ||
        baseline.persistedRevision != currentDocument?.revision ||
        (baseline.isOpenBuffer &&
            (!identical(bufferAfterRead, openBuffer) ||
                openBuffer!.sourceRevision != expectedSourceRevision))) {
      sessionBaselines.remove(relativePath);
      throw _documentRevisionConflict();
    }
    if (!baseline.isOpenBuffer && bufferAfterRead != null) {
      sessionBaselines.remove(relativePath);
      throw _documentRevisionConflict();
    }
    if (!baseline.isMissing && baseline.persistedRevision == null) {
      sessionBaselines.remove(relativePath);
      throw _documentRevisionConflict();
    }
    late final WorkspaceDocumentCommitReceipt receipt;
    try {
      receipt = await _documentStore.saveDocumentsAtomically(
        <DocumentState>[
          DocumentState(
            documentId: absolutePath,
            text: content,
            revision: currentDocument?.revision ?? 0,
          ),
        ],
        expectedWorkspaceRevision: baseline.workspaceRevision,
        expectedDocumentRevisions: <String, int>{
          absolutePath: baseline.persistedRevision ?? 0,
        },
      );
    } on VityodWorkspaceStoreFailure catch (failure) {
      if (failure.code.contains('revision')) {
        sessionBaselines.remove(relativePath);
      }
      throw AgentClientOperationFailure(
        failure.code.contains('revision')
            ? 'document_revision_conflict'
            : 'workspace_commit_failed',
        'The workspace could not commit the Agent document edit.',
      );
    } on Object {
      throw AgentClientOperationFailure(
        'workspace_commit_failed',
        'The workspace could not commit the Agent document edit.',
      );
    }
    final documentRevision = receipt.documentRevisions[relativePath];
    if (documentRevision == null) {
      throw AgentClientOperationFailure(
        'invalid_commit_receipt',
        'The workspace did not return a document revision.',
      );
    }
    if (expectedSourceRevision != null && openBuffer != null) {
      _engine.acceptAgentDocumentWrite(
        expectedStore: _documentStore,
        expectedStoreGeneration: storeGeneration,
        expectedBuffer: openBuffer,
        absolutePath: absolutePath,
        text: content,
        expectedSourceRevision: expectedSourceRevision,
        documentRevision: documentRevision,
        workspaceRevision: receipt.workspaceRevision,
      );
    }
    final updatedBuffer = _engine.openedBuffer(absolutePath);
    if (baseline.isOpenBuffer &&
        (updatedBuffer == null ||
            updatedBuffer.sourceRevision != expectedSourceRevision! + 1 ||
            updatedBuffer.text != content ||
            updatedBuffer.dirty)) {
      sessionBaselines.remove(relativePath);
    } else {
      _recordDocumentBaseline(
        operation.sessionId,
        relativePath,
        observationSequence,
        _AgentDocumentBaseline(
          resourceId: baseline.resourceId,
          workspaceRevision: receipt.workspaceRevision,
          persistedRevision: documentRevision,
          sourceRevision: baseline.isOpenBuffer
              ? expectedSourceRevision! + 1
              : null,
          isOpenBuffer: baseline.isOpenBuffer,
          isMissing: false,
          isDirty: false,
          proposalEligible: true,
        ),
        sessionGeneration: sessionGeneration,
      );
    }
    return <String, Object?>{};
  }

  void _recordDocumentBaseline(
    String sessionId,
    String relativePath,
    int observationSequence,
    _AgentDocumentBaseline baseline, {
    required int sessionGeneration,
  }) {
    if (_closed ||
        (_sessionOperationGenerations[sessionId] ?? 0) != sessionGeneration) {
      return;
    }
    final sessionBaselines = _documentBaselines.putIfAbsent(
      sessionId,
      () => <String, _AgentDocumentBaseline>{},
    );
    final previous = sessionBaselines[relativePath];
    if (previous == null ||
        observationSequence >= previous.observationSequence) {
      sessionBaselines[relativePath] = baseline.withSequence(
        observationSequence,
      );
    }
  }

  Future<Map<String, Object?>> _workspaceChangeProposal(
    AgentClientOperation operation,
  ) async {
    String? proposalId;
    try {
      final request = VityoWorkspaceChangeProposalRequest.fromJson(
        operation.params,
      );
      final proposal = request.proposal;
      proposalId = proposal.id;
      final prepared = await _prepareProposal(operation.sessionId, proposal);
      if (prepared == null) {
        return _proposalResult(
          proposalId: proposal.id,
          outcome: 'conflict',
          code: 'revision_conflict',
        );
      }
      if (_pendingProposals.containsKey(operation.operationId)) {
        return _proposalResult(
          proposalId: proposal.id,
          outcome: 'failed',
          code: 'proposal_already_pending',
        );
      }
      final pending = _PendingWorkspaceProposal(operation.sessionId);
      _pendingProposals[operation.operationId] = pending;
      _proposalReviews.add(
        FlowHeroWorkspaceChangeReview(
          reviewId: operation.operationId,
          sessionId: operation.sessionId,
          proposal: proposal,
          resources: prepared
              .map((resource) => resource.review)
              .toList(growable: false),
        ),
      );
      final decision = await pending.decision.future;
      if (decision == 'reject') {
        return _proposalResult(proposalId: proposal.id, outcome: 'rejected');
      }
      if (decision != 'apply' || _closed) {
        return _proposalResult(
          proposalId: proposal.id,
          outcome: 'failed',
          code: 'review_cancelled',
        );
      }
      return await _commitProposal(
        sessionId: operation.sessionId,
        proposal: proposal,
        prepared: prepared,
      );
    } on AgentProtocolException catch (error) {
      return _proposalResult(
        proposalId: proposalId ?? _proposalId(operation.params),
        outcome: 'failed',
        code: error.code,
      );
    } on Object {
      return _proposalResult(
        proposalId: proposalId ?? _proposalId(operation.params),
        outcome: 'failed',
        code: 'proposal_failed',
      );
    } finally {
      _pendingProposals.remove(operation.operationId);
      if (!_resolvedProposalReviews.isClosed) {
        _resolvedProposalReviews.add(operation.operationId);
      }
    }
  }

  Future<List<_PreparedWorkspaceProposalResource>?> _prepareProposal(
    String sessionId,
    VityoWorkspaceChangeProposal proposal,
  ) async {
    final sessionBaselines = _documentBaselines[sessionId];
    if (sessionBaselines == null) return null;
    final prepared = <_PreparedWorkspaceProposalResource>[];
    for (final resource in proposal.resources) {
      final resourceId = resource.resourceId;
      if (resourceId.isEmpty ||
          resourceId.startsWith('/') ||
          resourceId.contains('\\') ||
          resourceId
              .split('/')
              .any(
                (segment) =>
                    segment.isEmpty || segment == '.' || segment == '..',
              )) {
        return null;
      }
      final absolutePath = _absolutePathForRelative(resourceId);
      if (_resolvePath(absolutePath) != resourceId) return null;
      final baseline = sessionBaselines[resourceId];
      if (baseline == null ||
          baseline.isMissing ||
          baseline.persistedRevision != resource.baseDocumentRevision ||
          baseline.workspaceRevision != proposal.baseWorkspaceRevision ||
          !baseline.proposalEligible ||
          baseline.isDirty) {
        return null;
      }
      final snapshot = await _documentStore.readWorkspaceSnapshot(absolutePath);
      final document = snapshot.document;
      if (document == null ||
          snapshot.resourceId != resourceId ||
          snapshot.workspaceRevision != proposal.baseWorkspaceRevision ||
          document.revision != resource.baseDocumentRevision) {
        return null;
      }
      final buffer = _engine.openedBuffer(absolutePath);
      if (baseline.isOpenBuffer) {
        if (buffer == null ||
            buffer.sourceRevision != baseline.sourceRevision ||
            buffer.dirty ||
            buffer.documentRevision != document.revision ||
            buffer.persistedText != document.text ||
            buffer.text != document.text) {
          return null;
        }
      } else if (buffer != null) {
        return null;
      }
      final edits = _applyProposalEdits(document.text, resource.edits);
      if (edits == null || edits.text == document.text) return null;
      prepared.add(
        _PreparedWorkspaceProposalResource(
          resourceId: resourceId,
          absolutePath: absolutePath,
          documentRevision: document.revision,
          sourceRevision: baseline.sourceRevision,
          isOpenBuffer: baseline.isOpenBuffer,
          text: edits.text,
          review: FlowHeroWorkspaceResourceReview(
            resourceId: resourceId,
            baseDocumentRevision: document.revision,
            edits: edits.previews,
          ),
        ),
      );
    }
    return prepared;
  }

  Future<Map<String, Object?>> _commitProposal({
    required String sessionId,
    required VityoWorkspaceChangeProposal proposal,
    required List<_PreparedWorkspaceProposalResource> prepared,
  }) async {
    final sessionGeneration = _sessionOperationGenerations[sessionId] ?? 0;
    final sessionBaselines = _documentBaselines[sessionId];
    if (sessionBaselines == null) {
      return _proposalResult(
        proposalId: proposal.id,
        outcome: 'conflict',
        code: 'revision_conflict',
      );
    }
    final storeGeneration = _engine.documentStoreGeneration;
    final originalBuffers = {
      for (final resource in prepared)
        resource.resourceId: _engine.openedBuffer(resource.absolutePath),
    };
    for (final resource in prepared) {
      final current = await _documentStore.readWorkspaceSnapshot(
        resource.absolutePath,
      );
      final baseline = sessionBaselines[resource.resourceId];
      final buffer = _engine.openedBuffer(resource.absolutePath);
      if (baseline == null ||
          current.resourceId != resource.resourceId ||
          current.workspaceRevision != proposal.baseWorkspaceRevision ||
          current.document?.revision != resource.documentRevision ||
          (resource.isOpenBuffer &&
              (buffer == null ||
                  buffer.sourceRevision != resource.sourceRevision ||
                  buffer.dirty ||
                  buffer.text != current.document?.text)) ||
          (!resource.isOpenBuffer && buffer != null)) {
        return _proposalResult(
          proposalId: proposal.id,
          outcome: 'conflict',
          code: 'revision_conflict',
        );
      }
    }
    late final WorkspaceDocumentCommitReceipt receipt;
    try {
      receipt = await _documentStore.saveDocumentsAtomically(
        prepared
            .map(
              (resource) => DocumentState(
                documentId: resource.absolutePath,
                text: resource.text,
                revision: resource.documentRevision + 1,
                workspaceRevision: proposal.baseWorkspaceRevision,
                baseDocumentRevision: resource.documentRevision,
              ),
            )
            .toList(growable: false),
        expectedWorkspaceRevision: proposal.baseWorkspaceRevision,
        expectedDocumentRevisions: <String, int>{
          for (final resource in prepared)
            resource.absolutePath: resource.documentRevision,
        },
      );
    } on VityodWorkspaceStoreFailure catch (failure) {
      return _proposalResult(
        proposalId: proposal.id,
        outcome: failure.code.contains('revision') ? 'conflict' : 'failed',
        code: failure.code.contains('revision')
            ? 'revision_conflict'
            : 'transaction_failed',
      );
    } on Object {
      return _proposalResult(
        proposalId: proposal.id,
        outcome: 'failed',
        code: 'transaction_failed',
      );
    }
    final documentRevisions = <String, int>{};
    for (final resource in prepared) {
      final revision = receipt.documentRevisions[resource.resourceId];
      if (revision == null) {
        return _proposalResult(
          proposalId: proposal.id,
          outcome: 'failed',
          code: 'invalid_commit_receipt',
        );
      }
      documentRevisions[resource.resourceId] = revision;
      final originalBuffer = originalBuffers[resource.resourceId];
      if (resource.isOpenBuffer &&
          resource.sourceRevision != null &&
          originalBuffer != null) {
        _engine.acceptAgentDocumentWrite(
          expectedStore: _documentStore,
          expectedStoreGeneration: storeGeneration,
          expectedBuffer: originalBuffer,
          absolutePath: resource.absolutePath,
          text: resource.text,
          expectedSourceRevision: resource.sourceRevision!,
          documentRevision: revision,
          workspaceRevision: receipt.workspaceRevision,
        );
      }
      _recordDocumentBaseline(
        sessionId,
        resource.resourceId,
        ++_documentObservationSequence,
        _AgentDocumentBaseline(
          resourceId: resource.resourceId,
          workspaceRevision: receipt.workspaceRevision,
          persistedRevision: revision,
          sourceRevision:
              resource.isOpenBuffer && resource.sourceRevision != null
              ? resource.sourceRevision! + 1
              : null,
          isOpenBuffer: resource.isOpenBuffer,
          isMissing: false,
          isDirty: false,
          proposalEligible: true,
        ),
        sessionGeneration: sessionGeneration,
      );
    }
    return VityoWorkspaceChangeProposalResponse(
      proposalId: proposal.id,
      outcome: VityoWorkspaceChangeOutcome.committed,
      workspaceRevision: receipt.workspaceRevision,
      documentRevisions: documentRevisions,
    ).toJson();
  }

  void decideWorkspaceProposal(String reviewId, {required bool apply}) {
    final pending = _pendingProposals[reviewId];
    if (pending == null || pending.decision.isCompleted) return;
    pending.decision.complete(apply ? 'apply' : 'reject');
  }

  @override
  void cancelSessionOperations(String sessionId) {
    for (final terminal in _terminals.values) {
      if (terminal.ownerSessionId == sessionId) terminal.interruptWaits();
    }
    for (final pending in _pendingProposals.values) {
      if (pending.sessionId == sessionId && !pending.decision.isCompleted) {
        pending.decision.complete('cancelled');
      }
    }
  }

  @override
  Future<void> closeSessionOperations(String sessionId) async {
    _sessionOperationGenerations[sessionId] =
        (_sessionOperationGenerations[sessionId] ?? 0) + 1;
    _documentBaselines.remove(sessionId);
    for (final entry in _pendingProposals.entries.toList(growable: false)) {
      final pending = entry.value;
      if (pending.sessionId == sessionId) {
        if (!pending.decision.isCompleted) pending.decision.complete('closed');
        _pendingProposals.remove(entry.key);
      }
    }
    for (final terminal
        in _terminals.values
            .where((terminal) => terminal.ownerSessionId == sessionId)
            .toList(growable: false)) {
      _terminals.remove(terminal.id);
      terminal.interruptWaits();
      try {
        await _client.request(
          method: 'pty.close',
          idempotencyKey: 'agent-pty-release-${terminal.id}',
          workspaceId: workspaceId,
          params: <String, Object?>{'streamId': terminal.streamId},
        );
      } on Object {
        // Session teardown drops local terminal ownership if vityod is gone.
      }
    }
  }

  Future<Map<String, Object?>> _terminal(AgentClientOperation operation) async {
    return switch (operation.method) {
      'terminal/create' => _createTerminal(operation),
      'terminal/output' => _readTerminalOutput(operation),
      'terminal/wait_for_exit' => _waitForTerminal(operation),
      'terminal/kill' => _killTerminal(operation),
      'terminal/release' => _releaseTerminal(operation),
      _ => throw AgentClientOperationFailure(
        'unsupported_operation',
        'The requested terminal operation is not supported.',
      ),
    };
  }

  Future<Map<String, Object?>> _createTerminal(
    AgentClientOperation operation,
  ) async {
    final operationSessionId = operation.sessionId;
    final sessionOperationGeneration =
        _sessionOperationGenerations[operationSessionId] ?? 0;
    final sessionId = _requiredString(operation.params, 'sessionId');
    final command = _requiredString(operation.params, 'command');
    final rawArguments = operation.params['args'] ?? const <Object?>[];
    if (rawArguments is! List || rawArguments.any((item) => item is! String)) {
      throw AgentClientOperationFailure(
        'invalid_operation_request',
        'Terminal arguments must be strings.',
      );
    }
    final requestedCwd = operation.params['cwd'];
    if (requestedCwd != null && requestedCwd is! String) {
      throw AgentClientOperationFailure(
        'invalid_operation_request',
        'Terminal cwd must be a workspace path.',
      );
    }
    final relativeCwd = requestedCwd == null
        ? ''
        : _resolvePath(requestedCwd as String, allowWorkspaceRoot: true);
    final workingDirectory = relativeCwd.isEmpty
        ? workspaceRoot
        : _absolutePathForRelative(relativeCwd);
    final environment = _environment(operation.params['env']);
    final outputByteLimit = _outputByteLimit(
      operation.params['outputByteLimit'],
    );
    final terminalId = 'flowhero-${++_terminalSequence}';
    final response = await _client.request(
      method: 'pty.start',
      idempotencyKey: 'agent-pty-start-$terminalId',
      workspaceId: workspaceId,
      params: <String, Object?>{
        'terminalId': terminalId,
        'executable': command,
        'arguments': rawArguments,
        'environment': environment,
        'workingDirectory': workingDirectory,
        'rows': 24,
        'cols': 80,
      },
    );
    _throwServiceError(response);
    final streamId = response.params['streamId'];
    if (streamId is! int || streamId <= 0) {
      throw AgentClientOperationFailure(
        'invalid_terminal_receipt',
        'The local service returned an invalid terminal stream.',
      );
    }
    if (_closed ||
        (_sessionOperationGenerations[operationSessionId] ?? 0) !=
            sessionOperationGeneration) {
      await _closeUnclaimedTerminal(terminalId, streamId);
      throw _closed ? _operationPortClosed() : _operationSessionClosed();
    }
    _terminals[terminalId] = _FlowHeroTerminal(
      id: terminalId,
      sessionId: sessionId,
      ownerSessionId: operationSessionId,
      streamId: streamId,
      outputByteLimit: outputByteLimit,
    );
    return <String, Object?>{'terminalId': terminalId};
  }

  Future<Map<String, Object?>> _readTerminalOutput(
    AgentClientOperation operation,
  ) async {
    final terminal = _terminalFor(operation.params);
    await _drainOutput(terminal);
    return terminal.outputResult();
  }

  Future<Map<String, Object?>> _waitForTerminal(
    AgentClientOperation operation,
  ) async {
    final terminal = _terminalFor(operation.params);
    final waitEpoch = terminal.waitEpoch;
    while (!terminal.exited) {
      await _drainOutput(terminal, waitEpoch: waitEpoch);
      if (!terminal.exited) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    return terminal.exitResult();
  }

  Future<Map<String, Object?>> _killTerminal(
    AgentClientOperation operation,
  ) async {
    final terminal = _terminalFor(operation.params);
    if (terminal.exited) return <String, Object?>{};
    final response = await _client.request(
      method: 'pty.kill',
      idempotencyKey: 'agent-pty-kill-${terminal.id}',
      workspaceId: workspaceId,
      params: <String, Object?>{'streamId': terminal.streamId},
    );
    _throwServiceError(response);
    final exitCode = response.params['exitCode'];
    terminal.exited = true;
    terminal.exitCode = exitCode is int ? exitCode : null;
    return <String, Object?>{};
  }

  Future<Map<String, Object?>> _releaseTerminal(
    AgentClientOperation operation,
  ) async {
    final terminal = _terminalFor(operation.params);
    final response = await _client.request(
      method: 'pty.close',
      idempotencyKey: 'agent-pty-release-${terminal.id}',
      workspaceId: workspaceId,
      params: <String, Object?>{'streamId': terminal.streamId},
    );
    _throwServiceError(response);
    _terminals.remove(terminal.id);
    terminal.interruptWaits();
    return <String, Object?>{};
  }

  Future<void> _drainOutput(
    _FlowHeroTerminal terminal, {
    int? waitEpoch,
  }) async {
    const creditBytes = 256 * 1024;
    final epoch = waitEpoch ?? terminal.waitEpoch;
    while (!terminal.outputClosed) {
      if (_closed ||
          _terminals[terminal.id] != terminal ||
          terminal.waitEpoch != epoch ||
          !_client.state.canDispatch) {
        throw _terminalWaitInterrupted();
      }
      final frame = await _requestPtyOutput(terminal, creditBytes);
      if (frame.sequence > terminal.lastOutputSequence) {
        terminal.lastOutputSequence = frame.sequence;
        terminal.appendFrame(frame);
      }
      if (terminal.outputClosed || frame.payload.length < creditBytes) return;
    }
  }

  Future<VityodBinaryFrame> _requestPtyOutput(
    _FlowHeroTerminal terminal,
    int creditBytes,
  ) async {
    final received = Completer<VityodBinaryFrame>();
    terminal.pendingOutput.add(received);
    void interrupted() {
      if (!received.isCompleted) {
        received.completeError(_terminalWaitInterrupted());
      }
    }

    final subscription = _client.binaryFrames.listen(
      (frame) {
        if (!received.isCompleted &&
            frame.kind == VityodFrameKind.pty &&
            frame.streamId == terminal.streamId) {
          received.complete(frame);
        }
      },
      onDone: interrupted,
      onError: (Object _, StackTrace __) => interrupted(),
    );
    final states = _client.states.listen((state) {
      if (!state.canDispatch) interrupted();
    }, onDone: interrupted);
    try {
      final credit = Uint8List(4);
      ByteData.sublistView(credit).setUint32(0, creditBytes, Endian.big);
      // Attach the reply/error listener before dispatch: a synchronous transport
      // can close or fail while sending the output credit.
      final reply = received.future;
      await Future.wait<Object?>([
        reply,
        _client.sendBinary(
          VityodBinaryFrame(
            kind: VityodFrameKind.credit,
            streamId: terminal.streamId,
            sequence: ++terminal.creditSequence,
            payload: credit,
          ),
        ),
      ], eagerError: true);
      return await reply;
    } finally {
      terminal.pendingOutput.remove(received);
      await subscription.cancel();
      await states.cancel();
    }
  }

  _FlowHeroTerminal _terminalFor(Map<String, Object?> params) {
    final terminalId = _requiredString(params, 'terminalId');
    final sessionId = _requiredString(params, 'sessionId');
    final terminal = _terminals[terminalId];
    if (terminal == null || terminal.sessionId != sessionId) {
      throw AgentClientOperationFailure(
        'unknown_terminal',
        'The requested terminal is no longer available.',
      );
    }
    return terminal;
  }

  String _resolvePath(String path, {bool allowWorkspaceRoot = false}) {
    final normalizedRoot = workspaceRoot
        .replaceAll(r'\', '/')
        .replaceFirst(RegExp(r'/+$'), '');
    final normalizedPath = path.replaceAll(r'\', '/');
    if (allowWorkspaceRoot && normalizedPath == normalizedRoot) return '';
    try {
      final relative = _documentStore.relativeDocumentPath(path);
      if (relative.isEmpty || relative.split('/').contains('..')) {
        throw const FormatException();
      }
      return relative;
    } on Object {
      throw AgentClientOperationFailure(
        'workspace_root_escape',
        'The requested path is outside the active workspace.',
      );
    }
  }

  String _absolutePathForRelative(String relative) {
    final normalizedRoot = workspaceRoot
        .replaceAll(r'\', '/')
        .replaceFirst(RegExp(r'/+$'), '');
    return relative.isEmpty ? normalizedRoot : '$normalizedRoot/$relative';
  }

  Future<void> _closeUnclaimedTerminal(String terminalId, int streamId) async {
    try {
      await _client.request(
        method: 'pty.close',
        idempotencyKey: 'agent-pty-release-$terminalId',
        workspaceId: workspaceId,
        params: <String, Object?>{'streamId': streamId},
      );
    } on Object {
      // The caller already retired this session; release when the daemon is
      // reachable and otherwise let daemon/session teardown own the stream.
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final pending in _pendingProposals.values) {
      if (!pending.decision.isCompleted) {
        pending.decision.complete('closed');
      }
    }
    _pendingProposals.clear();
    _documentBaselines.clear();
    final terminals = _terminals.values.toList(growable: false);
    _terminals.clear();
    for (final terminal in terminals) {
      terminal.interruptWaits();
      await _closeUnclaimedTerminal(terminal.id, terminal.streamId);
    }
    await _proposalReviews.close();
    await _resolvedProposalReviews.close();
  }
}

final class FlowHeroWorkspaceChangeReview {
  FlowHeroWorkspaceChangeReview({
    required this.reviewId,
    required this.sessionId,
    required this.proposal,
    required Iterable<FlowHeroWorkspaceResourceReview> resources,
  }) : resources = List<FlowHeroWorkspaceResourceReview>.unmodifiable(
         resources,
       );

  final String reviewId;
  final String sessionId;
  final VityoWorkspaceChangeProposal proposal;
  final List<FlowHeroWorkspaceResourceReview> resources;

  int get editCount => resources.fold<int>(
    0,
    (count, resource) => count + resource.edits.length,
  );
}

final class FlowHeroWorkspaceResourceReview {
  FlowHeroWorkspaceResourceReview({
    required this.resourceId,
    required this.baseDocumentRevision,
    required Iterable<FlowHeroWorkspaceEditReview> edits,
  }) : edits = List<FlowHeroWorkspaceEditReview>.unmodifiable(edits);

  final String resourceId;
  final int baseDocumentRevision;
  final List<FlowHeroWorkspaceEditReview> edits;
}

final class FlowHeroWorkspaceEditReview {
  const FlowHeroWorkspaceEditReview({
    required this.start,
    required this.end,
    required this.beforeText,
    required this.replacement,
  });

  final int start;
  final int end;
  final String beforeText;
  final String replacement;
}

final class _PendingWorkspaceProposal {
  _PendingWorkspaceProposal(this.sessionId);

  final String sessionId;
  final Completer<String> decision = Completer<String>();
}

final class _PreparedWorkspaceProposalResource {
  const _PreparedWorkspaceProposalResource({
    required this.resourceId,
    required this.absolutePath,
    required this.documentRevision,
    required this.sourceRevision,
    required this.isOpenBuffer,
    required this.text,
    required this.review,
  });

  final String resourceId;
  final String absolutePath;
  final int documentRevision;
  final int? sourceRevision;
  final bool isOpenBuffer;
  final String text;
  final FlowHeroWorkspaceResourceReview review;
}

({String text, List<FlowHeroWorkspaceEditReview> previews})?
_applyProposalEdits(String source, List<VityoTextChange> edits) {
  final ordered = List<VityoTextChange>.of(edits)
    ..sort((left, right) {
      final startOrder = left.start.compareTo(right.start);
      return startOrder == 0 ? left.end.compareTo(right.end) : startOrder;
    });
  VityoTextChange? previous;
  for (final edit in ordered) {
    if (edit.start < 0 ||
        edit.end < edit.start ||
        edit.end > source.length ||
        (previous != null && edit.start < previous.end) ||
        (previous != null &&
            previous.start == previous.end &&
            edit.start == edit.end &&
            previous.start == edit.start)) {
      return null;
    }
    previous = edit;
  }
  var text = source;
  for (final edit in ordered.reversed) {
    text = text.replaceRange(edit.start, edit.end, edit.replacement);
  }
  return (
    text: text,
    previews: ordered
        .map(
          (edit) => FlowHeroWorkspaceEditReview(
            start: edit.start,
            end: edit.end,
            beforeText: source.substring(edit.start, edit.end),
            replacement: edit.replacement,
          ),
        )
        .toList(growable: false),
  );
}

Map<String, Object?> _proposalResult({
  required String? proposalId,
  required String outcome,
  String? code,
}) {
  if (proposalId == null || proposalId.isEmpty) {
    throw AgentClientOperationFailure(
      'invalid_workspace_change_proposal',
      'The workspace proposal is invalid.',
    );
  }
  final result = VityoWorkspaceChangeProposalResponse(
    proposalId: proposalId,
    outcome: switch (outcome) {
      'committed' => VityoWorkspaceChangeOutcome.committed,
      'rejected' => VityoWorkspaceChangeOutcome.rejected,
      'conflict' => VityoWorkspaceChangeOutcome.conflict,
      'failed' => VityoWorkspaceChangeOutcome.failed,
      _ => throw ArgumentError.value(outcome, 'outcome'),
    },
    code: code,
  );
  return result.toJson();
}

String? _proposalId(Map<String, Object?> params) {
  final proposal = params['proposal'];
  if (proposal is! Map) return null;
  final id = proposal['id'];
  return id is String && id.isNotEmpty ? id : null;
}

final class _FlowHeroTerminal {
  _FlowHeroTerminal({
    required this.id,
    required this.sessionId,
    required this.ownerSessionId,
    required this.streamId,
    required this.outputByteLimit,
  });

  final String id;

  /// ACP session ID used by the terminal tool payload.
  final String sessionId;

  /// IDE registry session ID that owns this terminal resource.
  final String ownerSessionId;
  final int streamId;
  final int outputByteLimit;
  final List<int> outputBytes = <int>[];
  int creditSequence = 0;
  int lastOutputSequence = 0;
  bool truncated = false;
  bool exited = false;
  bool outputClosed = false;
  int? exitCode;
  int waitEpoch = 0;
  final Set<Completer<VityodBinaryFrame>> pendingOutput = {};

  void interruptWaits() {
    waitEpoch++;
    for (final reply in pendingOutput) {
      if (!reply.isCompleted) reply.completeError(_terminalWaitInterrupted());
    }
  }

  void appendFrame(VityodBinaryFrame frame) {
    var start = 0;
    if (frame.flags & 1 != 0) truncated = true;
    if (frame.flags & 4 != 0) {
      if (frame.payload.length < 4) {
        throw AgentClientOperationFailure(
          'invalid_terminal_output',
          'The local service returned malformed terminal output.',
        );
      }
      exitCode = ByteData.sublistView(frame.payload).getUint32(0, Endian.big);
      start = 4;
    }
    if (frame.flags & 2 != 0) {
      exited = true;
      outputClosed = true;
    }
    outputBytes.addAll(frame.payload.skip(start));
    if (outputBytes.length > outputByteLimit) {
      outputBytes.removeRange(0, outputBytes.length - outputByteLimit);
      truncated = true;
    }
  }

  Map<String, Object?> outputResult() => <String, Object?>{
    'output': utf8.decode(outputBytes, allowMalformed: true),
    'truncated': truncated,
    if (exited)
      'exitStatus': <String, Object?>{'exitCode': exitCode, 'signal': null},
  };

  Map<String, Object?> exitResult() => <String, Object?>{
    'exitCode': exitCode,
    'signal': null,
  };
}

AgentClientOperationFailure _terminalWaitInterrupted() =>
    AgentClientOperationFailure(
      'terminal_wait_interrupted',
      'The terminal wait ended because its session or connection changed.',
    );

final class _AgentDocumentBaseline {
  const _AgentDocumentBaseline({
    required this.resourceId,
    required this.workspaceRevision,
    required this.persistedRevision,
    required this.sourceRevision,
    required this.isOpenBuffer,
    required this.isMissing,
    required this.isDirty,
    required this.proposalEligible,
    this.observationSequence = 0,
  });

  final String resourceId;
  final int workspaceRevision;
  final int? persistedRevision;
  final int? sourceRevision;
  final bool isOpenBuffer;
  final bool isMissing;
  final bool isDirty;
  final bool proposalEligible;
  final int observationSequence;

  _AgentDocumentBaseline withSequence(int sequence) => _AgentDocumentBaseline(
    resourceId: resourceId,
    workspaceRevision: workspaceRevision,
    persistedRevision: persistedRevision,
    sourceRevision: sourceRevision,
    isOpenBuffer: isOpenBuffer,
    isMissing: isMissing,
    isDirty: isDirty,
    proposalEligible: proposalEligible,
    observationSequence: sequence,
  );
}

AgentClientOperationFailure _documentRevisionConflict() =>
    AgentClientOperationFailure(
      'document_revision_conflict',
      'The workspace document changed after the Agent read it.',
    );

Map<String, Object?> _workspaceSnapshotMetadata({
  required String workspaceId,
  required String rootId,
  required String resourceId,
  required int workspaceRevision,
  required bool documentExists,
  int? documentRevision,
  required int? sourceRevision,
  required String sourceKind,
  required bool sourceDirty,
  required bool proposalEligible,
}) => <String, Object?>{
  'workspaceId': workspaceId,
  'rootId': rootId,
  'resourceId': resourceId,
  'workspaceRevision': workspaceRevision,
  'documentExists': documentExists,
  'documentRevision': documentRevision,
  'sourceRevision': sourceRevision,
  'sourceKind': sourceKind,
  'sourceDirty': sourceDirty,
  'proposalEligible': proposalEligible,
};

int _outputByteLimit(Object? value) {
  if (value == null) return _maxAgentOperationTextBytes;
  if (value is int && value >= 0) {
    return value.clamp(0, _maxAgentOperationTextBytes);
  }
  throw AgentClientOperationFailure(
    'invalid_operation_request',
    'Terminal outputByteLimit must be a non-negative integer.',
  );
}

Map<String, String> _environment(Object? raw) {
  if (raw == null) return const <String, String>{};
  if (raw is! List) {
    throw AgentClientOperationFailure(
      'invalid_operation_request',
      'Terminal environment must be a list.',
    );
  }
  final result = <String, String>{};
  for (final entry in raw) {
    if (entry is! Map ||
        entry['name'] is! String ||
        entry['value'] is! String) {
      throw AgentClientOperationFailure(
        'invalid_operation_request',
        'Terminal environment entries require string names and values.',
      );
    }
    result[entry['name']! as String] = entry['value']! as String;
  }
  return result;
}

String _requiredString(
  Map<String, Object?> params,
  String name, {
  bool allowEmpty = false,
}) {
  final value = params[name];
  if (value is String && (allowEmpty || value.isNotEmpty)) return value;
  throw AgentClientOperationFailure(
    'invalid_operation_request',
    '$name must be a string.',
  );
}

int? _optionalPositiveInt(Map<String, Object?> params, String name) {
  final value = params[name];
  if (value == null) return null;
  if (value is int && value > 0) return value;
  throw AgentClientOperationFailure(
    'invalid_operation_request',
    '$name must be a positive integer.',
  );
}

void _requireServiceSuccess(VityodControlEnvelope response) {
  if (!response.method.endsWith('.error')) return;
  final code = response.params['errorCode'];
  throw AgentClientOperationFailure(
    code is String ? code : 'workspace_service_error',
    'The workspace service is not ready.',
  );
}

void _throwServiceError(VityodControlEnvelope response) =>
    _requireServiceSuccess(response);

String _selectTextLines(String source, int firstLine, int? lineLimit) {
  final selected = StringBuffer();
  var line = 1;
  var start = 0;
  var selectedCount = 0;
  for (var offset = 0; offset <= source.length; offset++) {
    if (lineLimit != null && selectedCount >= lineLimit && line >= firstLine) {
      break;
    }
    if (offset < source.length && source.codeUnitAt(offset) != 10) continue;
    if (line >= firstLine) {
      final separatorLength = selectedCount == 0 ? 0 : 1;
      final lineLength = offset - start;
      if (selected.length + separatorLength + lineLength >
          _maxAgentOperationTextBytes) {
        throw _documentTooLarge();
      }
      if (separatorLength != 0) selected.write('\n');
      selected.write(source.substring(start, offset));
      selectedCount++;
    }
    if (offset == source.length) break;
    start = offset + 1;
    line++;
  }
  final content = selected.toString();
  if (utf8.encode(content).length > _maxAgentOperationTextBytes) {
    throw _documentTooLarge();
  }
  return content;
}

AgentClientOperationFailure _documentTooLarge() => AgentClientOperationFailure(
  'document_too_large',
  'The requested document exceeds the Agent protocol message limit.',
);

AgentClientOperationFailure _operationPortClosed() =>
    AgentClientOperationFailure(
      'operation_port_closed',
      'The operation port is closed.',
    );

AgentClientOperationFailure _operationSessionClosed() =>
    AgentClientOperationFailure(
      'operation_session_closed',
      'The operation session is closed.',
    );
