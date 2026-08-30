import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../ide/editor/editor.dart';
import '../../../ide/workspace/workspace.dart';
import '../../environment/system_compatibility/file_system/file_system_manager.dart';
import '../../language/service/service.dart';
import '../../runtime/runtime.dart';

/// Owns workspace text/symbol search, its index, and the production file
/// watcher that keeps the index current.
final class WorkspaceSearchController extends ChangeNotifier {
  WorkspaceSearchController({
    required this.workspaceController,
    required this.documentStore,
    required this.languageService,
    required this.documentSamples,
    required this.log,
    this.textSearchProvider,
    this.fileSystemManager,
    this.runtimeOutputBuffer,
    this.watcherPolicy = const WorkspaceSearchWatcherPolicy(),
  }) : _indexController = WorkspaceSearchIndexController(
         service: WorkspaceSearchService(documentStore: documentStore),
       ) {
    workspaceController.addListener(_handleWorkspaceChanged);
  }

  final WorkspaceController workspaceController;
  final WorkspaceDocumentStore documentStore;
  final ProjectStyioLanguageService languageService;
  final List<DocumentState> Function() documentSamples;
  final void Function(String message) log;
  final WorkspaceTextSearchProvider? textSearchProvider;
  final FileSystemManager? fileSystemManager;
  final RuntimeOutputLiveBuffer? runtimeOutputBuffer;
  final WorkspaceSearchWatcherPolicy watcherPolicy;
  final WorkspaceSearchIndexController _indexController;

  WorkspaceSearchResult? _lastTextSearch;
  WorkspaceSymbolSearchResult? _lastSymbolSearch;
  WorkspaceSearchIndexWatcherSnapshot? _watcherSnapshot;
  StreamSubscription<WorkspaceSearchIndexWatcherSnapshot>? _watcherSubscription;
  String? _lastQuery;
  String? _watchedWorkspaceRoot;
  String? _lastPublishedTelemetrySignature;
  int _watcherGeneration = 0;
  int _lastScannedDocumentCount = 0;
  bool _disposed = false;

  WorkspaceSearchResult? get lastTextSearch => _lastTextSearch;
  WorkspaceSymbolSearchResult? get lastSymbolSearch => _lastSymbolSearch;
  WorkspaceSearchIndexRefreshSnapshot get searchIndexSnapshot =>
      _indexController.snapshot;
  WorkspaceSearchIndex? get searchIndex => _indexController.snapshot.index;
  WorkspaceSearchIndexWatcherSnapshot? get watcherSnapshot => _watcherSnapshot;
  String? get lastQuery => _lastQuery;
  int get lastScannedDocumentCount => _lastScannedDocumentCount;

  Future<void> start() async {
    final generation = ++_watcherGeneration;
    final previousSubscription = _watcherSubscription;
    _watcherSubscription = null;
    await previousSubscription?.cancel();
    if (_disposed || generation != _watcherGeneration) {
      return;
    }

    final workspaceRoot = workspaceController.activeProject.workspaceRoot;
    final refresh = await _indexController.refresh(
      documentIds: workspaceController.files,
    );
    if (_disposed || generation != _watcherGeneration) {
      return;
    }
    _watchedWorkspaceRoot = workspaceRoot;
    final manager = fileSystemManager;
    if (manager == null || workspaceRoot.trim().isEmpty) {
      _watcherSnapshot = WorkspaceSearchIndexWatcherSnapshot(
        status: WorkspaceSearchIndexWatcherStatus.idle,
        workspaceRoot: workspaceRoot,
        recursive: true,
        refreshSnapshot: refresh,
        message: 'Workspace search watcher is unavailable for this backend.',
      );
      notifyListeners();
      return;
    }

    final binding = WorkspaceSearchIndexFileSystemWatcherBinding(
      controller: _indexController,
      fileSystemManager: manager,
      workspaceRoot: workspaceRoot,
      currentDocuments: documentSamples,
      currentDocumentIds: () => workspaceController.files,
      watcherPolicy: watcherPolicy,
    );
    _watcherSubscription = binding.watchAndRefresh().listen(
      _handleWatcherSnapshot,
      onError: (Object error, StackTrace stackTrace) {
        if (_disposed || generation != _watcherGeneration) {
          return;
        }
        _watcherSnapshot = WorkspaceSearchIndexWatcherSnapshot(
          status: WorkspaceSearchIndexWatcherStatus.failed,
          workspaceRoot: workspaceRoot,
          recursive: true,
          message: 'Workspace search watcher ended unexpectedly.',
        );
        notifyListeners();
      },
    );
    notifyListeners();
  }

  Future<void> recoverWatcher() => start();

  Future<bool> search(String query) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      log('Workspace search skipped: missing input.');
      return false;
    }
    final documents = await _collectDocuments();
    final provider = textSearchProvider;
    final textSearch = provider == null
        ? await WorkspaceSearchService(
            documentStore: InMemoryWorkspaceDocumentStore(
              seededDocuments: <String, DocumentState>{
                for (final document in documents) document.documentId: document,
              },
            ),
          ).search(
            documentIds: documents.map((document) => document.documentId),
            query: normalizedQuery,
            maxMatches: 1000,
          )
        : await provider.search(
            workspaceId: workspaceController.activeProject.id,
            query: normalizedQuery,
            maxMatches: 1000,
          );
    final symbolResult =
        await WorkspaceSymbolSearchService(
          documentStore: InMemoryWorkspaceDocumentStore(
            seededDocuments: <String, DocumentState>{
              for (final document in documents) document.documentId: document,
            },
          ),
          semanticSnapshotProvider: SemanticSnapshotProvider(
            languageService: languageService.documentService,
          ),
        ).searchSymbols(
          documentIds: documents.map((document) => document.documentId),
          query: normalizedQuery,
        );
    _lastQuery = normalizedQuery;
    _lastScannedDocumentCount = documents.length;
    _lastTextSearch = textSearch;
    _lastSymbolSearch = symbolResult;
    log(
      'Workspace search found '
      '${textSearch.matches.length} text match(es) and '
      '${symbolResult.matches.length} symbol match(es) for "$normalizedQuery".',
    );
    notifyListeners();
    return true;
  }

  Future<List<DocumentState>> _collectDocuments() async {
    final documents = <DocumentState>[];
    final seen = <String>{};
    for (final document in documentSamples()) {
      if (seen.add(document.documentId)) {
        documents.add(document);
      }
    }
    for (final filePath in workspaceController.files) {
      if (documents.length >= 100) {
        break;
      }
      if (!seen.add(filePath)) {
        continue;
      }
      try {
        documents.add(await documentStore.loadDocument(filePath));
      } on Object catch (error) {
        log('Workspace search skipped $filePath: $error');
      }
    }
    return documents;
  }

  void _handleWatcherSnapshot(WorkspaceSearchIndexWatcherSnapshot snapshot) {
    if (_disposed) {
      return;
    }
    _watcherSnapshot = snapshot;
    final telemetry = snapshot.backpressure;
    if (telemetry != null &&
        (telemetry.hasBackpressure || snapshot.recoveryPlan != null)) {
      final signature = <Object?>[
        snapshot.status.name,
        telemetry.batchCount,
        telemetry.droppedEventCount,
        telemetry.providerOverflowCount,
      ].join(':');
      if (_lastPublishedTelemetrySignature != signature) {
        _lastPublishedTelemetrySignature = signature;
        runtimeOutputBuffer?.addEvent(
          RuntimeOutputEvent(
            channelId: 'workspace.search',
            label: 'Workspace Search',
            kind: RuntimeOutputChannelKind.runtimeEvents,
            message:
                'watcher ${snapshot.status.name}: ${telemetry.state.name}, '
                '${telemetry.droppedEventCount} known dropped event(s)',
            timestamp: DateTime.now().toUtc(),
            metadata: <String, Object?>{
              'watcherStatus': snapshot.status.name,
              'backpressure': telemetry.toJson(),
              if (snapshot.recoveryPlan != null)
                'recoveryPlan': snapshot.recoveryPlan!.toJson(),
            },
          ),
        );
      }
    }
    notifyListeners();
  }

  void _handleWorkspaceChanged() {
    final nextRoot = workspaceController.activeProject.workspaceRoot;
    if (nextRoot != _watchedWorkspaceRoot) {
      unawaited(start());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _watcherGeneration += 1;
    workspaceController.removeListener(_handleWorkspaceChanged);
    unawaited(_watcherSubscription?.cancel());
    _watcherSubscription = null;
    super.dispose();
  }
}
