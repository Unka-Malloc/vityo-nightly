import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../view_ide/environment/system_compatibility/file_system/file_system_manager.dart';
import 'workspace_controller.dart';
import 'workspace_file_operations.dart';
import 'workspace_file_explorer_state_store.dart';

enum WorkspaceFileExplorerNodeKind { directory, file }

extension WorkspaceFileExplorerNodeKindX on WorkspaceFileExplorerNodeKind {
  String get wireValue {
    return switch (this) {
      WorkspaceFileExplorerNodeKind.directory => 'directory',
      WorkspaceFileExplorerNodeKind.file => 'file',
    };
  }
}

class WorkspaceFileExplorerNode {
  const WorkspaceFileExplorerNode({
    required this.name,
    required this.path,
    required this.kind,
    this.children = const <WorkspaceFileExplorerNode>[],
  });

  final String name;
  final String path;
  final WorkspaceFileExplorerNodeKind kind;
  final List<WorkspaceFileExplorerNode> children;

  int get fileCount {
    if (kind == WorkspaceFileExplorerNodeKind.file) {
      return 1;
    }
    return children.fold<int>(0, (total, child) => total + child.fileCount);
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'name': name,
      'path': path,
      'kind': kind.wireValue,
      'fileCount': fileCount,
      if (children.isNotEmpty)
        'children': children
            .map((child) => child.toJson())
            .toList(growable: false),
    };
  }
}

class WorkspaceFileExplorerSnapshot {
  const WorkspaceFileExplorerSnapshot({
    required this.roots,
    required this.activeFilePath,
    required this.openFilePaths,
    this.state,
    this.discovery,
    this.watch,
  });

  final List<WorkspaceFileExplorerNode> roots;
  final String activeFilePath;
  final List<String> openFilePaths;
  final WorkspaceFileExplorerState? state;
  final WorkspaceFileExplorerDiscoveryResult? discovery;
  final WorkspaceFileExplorerWatchSnapshot? watch;

  int get fileCount {
    return roots.fold<int>(0, (total, root) => total + root.fileCount);
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'activeFilePath': activeFilePath,
      'openFilePaths': openFilePaths,
      'fileCount': fileCount,
      if (state != null) 'state': state!.toJson(),
      if (discovery != null) 'discovery': discovery!.toJson(),
      if (watch != null) 'watch': watch!.toJson(),
      'roots': roots.map((root) => root.toJson()).toList(growable: false),
    };
  }
}

class WorkspaceFileExplorerDiscoveryResult {
  const WorkspaceFileExplorerDiscoveryResult({
    required this.source,
    required this.filePaths,
    this.ignoredPaths = const <String>[],
    this.truncated = false,
  });

  factory WorkspaceFileExplorerDiscoveryResult.fromPaths({
    required Iterable<String> discoveredPaths,
    Iterable<String> seedPaths = const <String>[],
    String source = 'file-system-manager',
    int maxFiles = 5000,
  }) {
    final filePaths = <String>[];
    final ignoredPaths = <String>[];
    final seen = <String>{};
    var truncated = false;

    void collectPath(String rawPath) {
      final normalizedPath = _normalizeWorkspaceFileExplorerPath(rawPath);
      if (_validateWorkspaceFileExplorerPath(normalizedPath) != null) {
        ignoredPaths.add(rawPath);
        return;
      }
      if (!seen.add(normalizedPath)) {
        return;
      }
      if (filePaths.length >= maxFiles) {
        truncated = true;
        return;
      }
      filePaths.add(normalizedPath);
    }

    for (final seedPath in seedPaths) {
      collectPath(seedPath);
    }
    for (final discoveredPath in discoveredPaths) {
      collectPath(discoveredPath);
    }
    filePaths.sort();

    return WorkspaceFileExplorerDiscoveryResult(
      source: source,
      filePaths: List.unmodifiable(filePaths),
      ignoredPaths: List.unmodifiable(ignoredPaths),
      truncated: truncated,
    );
  }

  final String source;
  final List<String> filePaths;
  final List<String> ignoredPaths;
  final bool truncated;

  int get fileCount => filePaths.length;
  int get ignoredPathCount => ignoredPaths.length;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'source': source,
      'fileCount': fileCount,
      'ignoredPathCount': ignoredPathCount,
      'truncated': truncated,
      'filePaths': filePaths,
      if (ignoredPaths.isNotEmpty) 'ignoredPaths': ignoredPaths,
    };
  }
}

class WorkspaceFileExplorerIgnoreRules {
  const WorkspaceFileExplorerIgnoreRules({
    this.excludeGlobs = const <String>[],
  });

  final List<String> excludeGlobs;

  bool ignores(String path, {bool caseSensitive = true}) {
    var normalizedPath = _normalizeWorkspaceFileExplorerPath(path);
    if (normalizedPath.isEmpty) {
      return true;
    }
    for (final glob in excludeGlobs) {
      var normalizedGlob = _normalizeWorkspaceFileExplorerPath(glob);
      if (normalizedGlob.isEmpty) {
        continue;
      }
      if (!caseSensitive) {
        normalizedPath = normalizedPath.toLowerCase();
        normalizedGlob = normalizedGlob.toLowerCase();
      }
      if (normalizedGlob.endsWith('/**')) {
        final prefix = normalizedGlob.substring(0, normalizedGlob.length - 3);
        if (normalizedPath == prefix || normalizedPath.startsWith('$prefix/')) {
          return true;
        }
      } else if (normalizedPath == normalizedGlob) {
        return true;
      }
    }
    return false;
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{'excludeGlobs': excludeGlobs};
  }
}

enum WorkspaceFileExplorerWatchStatus { pending, active, blocked }

extension WorkspaceFileExplorerWatchStatusX
    on WorkspaceFileExplorerWatchStatus {
  String get wireValue {
    return switch (this) {
      WorkspaceFileExplorerWatchStatus.pending => 'pending',
      WorkspaceFileExplorerWatchStatus.active => 'active',
      WorkspaceFileExplorerWatchStatus.blocked => 'blocked',
    };
  }
}

enum WorkspaceFileExplorerWatchEventKind { created, modified, deleted, renamed }

extension WorkspaceFileExplorerWatchEventKindX
    on WorkspaceFileExplorerWatchEventKind {
  String get wireValue {
    return switch (this) {
      WorkspaceFileExplorerWatchEventKind.created => 'created',
      WorkspaceFileExplorerWatchEventKind.modified => 'modified',
      WorkspaceFileExplorerWatchEventKind.deleted => 'deleted',
      WorkspaceFileExplorerWatchEventKind.renamed => 'renamed',
    };
  }
}

class WorkspaceFileExplorerWatchPlan {
  const WorkspaceFileExplorerWatchPlan({
    required this.rootPath,
    this.source = 'file-system-manager',
    this.recursive = true,
    this.includeGlobs = const <String>['**/*'],
    this.excludeGlobs = const <String>['.git/**', 'build/**'],
    this.caseSensitivePaths = true,
    this.debouncePolicy = const WorkspaceFileExplorerWatchDebouncePolicy(),
    this.status = WorkspaceFileExplorerWatchStatus.pending,
    this.message = '',
  });

  final String rootPath;
  final String source;
  final bool recursive;
  final List<String> includeGlobs;
  final List<String> excludeGlobs;
  final bool caseSensitivePaths;
  final WorkspaceFileExplorerWatchDebouncePolicy debouncePolicy;
  final WorkspaceFileExplorerWatchStatus status;
  final String message;

  bool get active => status == WorkspaceFileExplorerWatchStatus.active;
  WorkspaceFileExplorerIgnoreRules get ignoreRules {
    return WorkspaceFileExplorerIgnoreRules(excludeGlobs: excludeGlobs);
  }

  WorkspaceFileExplorerWatchPlan activate({String message = ''}) {
    return copyWith(
      status: WorkspaceFileExplorerWatchStatus.active,
      message: message,
    );
  }

  WorkspaceFileExplorerWatchPlan block(String message) {
    return copyWith(
      status: WorkspaceFileExplorerWatchStatus.blocked,
      message: message,
    );
  }

  WorkspaceFileExplorerWatchPlan copyWith({
    WorkspaceFileExplorerWatchStatus? status,
    String? message,
  }) {
    return WorkspaceFileExplorerWatchPlan(
      rootPath: rootPath,
      source: source,
      recursive: recursive,
      includeGlobs: includeGlobs,
      excludeGlobs: excludeGlobs,
      caseSensitivePaths: caseSensitivePaths,
      debouncePolicy: debouncePolicy,
      status: status ?? this.status,
      message: message ?? this.message,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'rootPath': rootPath,
      'source': source,
      'recursive': recursive,
      'includeGlobs': includeGlobs,
      'excludeGlobs': excludeGlobs,
      'caseSensitivePaths': caseSensitivePaths,
      'debouncePolicy': debouncePolicy.toJson(),
      'status': status.wireValue,
      'active': active,
      if (message.isNotEmpty) 'message': message,
    };
  }
}

class WorkspaceFileExplorerWatchDebouncePolicy {
  const WorkspaceFileExplorerWatchDebouncePolicy({
    this.window = const Duration(milliseconds: 150),
    this.maxBatchEvents = 64,
  });

  final Duration window;
  final int maxBatchEvents;

  bool shouldFlush({
    required DateTime firstEventAt,
    required DateTime latestEventAt,
    required int eventCount,
  }) {
    if (eventCount <= 0) {
      return false;
    }
    if (maxBatchEvents > 0 && eventCount >= maxBatchEvents) {
      return true;
    }
    return latestEventAt.difference(firstEventAt) >= window;
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'windowMs': window.inMilliseconds,
      'maxBatchEvents': maxBatchEvents,
    };
  }
}

class WorkspaceFileExplorerWatchEvent {
  const WorkspaceFileExplorerWatchEvent({
    required this.kind,
    required this.path,
    required this.timestamp,
    this.nextPath = '',
    this.source = 'file-system-manager',
  });

  final WorkspaceFileExplorerWatchEventKind kind;
  final String path;
  final String nextPath;
  final String source;
  final DateTime timestamp;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'kind': kind.wireValue,
      'path': path,
      if (nextPath.isNotEmpty) 'nextPath': nextPath,
      'source': source,
      'timestamp': timestamp.toIso8601String(),
    };
  }
}

class WorkspaceFileExplorerWatchEventBatch {
  const WorkspaceFileExplorerWatchEventBatch({
    required this.events,
    required this.firstEventAt,
    required this.flushedAt,
  });

  final List<WorkspaceFileExplorerWatchEvent> events;
  final DateTime firstEventAt;
  final DateTime flushedAt;

  int get eventCount => events.length;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'eventCount': eventCount,
      'firstEventAt': firstEventAt.toIso8601String(),
      'flushedAt': flushedAt.toIso8601String(),
      'events': events.map((event) => event.toJson()).toList(growable: false),
    };
  }
}

class WorkspaceFileExplorerWatchTelemetry {
  const WorkspaceFileExplorerWatchTelemetry({
    this.totalEventCount = 0,
    this.batchCount = 0,
    this.overflowCount = 0,
    this.droppedEventCount = 0,
    this.backpressurePauseCount = 0,
    this.maxBatchEventCount = 0,
    this.lastBatchLatency = Duration.zero,
  });

  final int totalEventCount;
  final int batchCount;
  final int overflowCount;
  final int droppedEventCount;
  final int backpressurePauseCount;
  final int maxBatchEventCount;
  final Duration lastBatchLatency;

  bool get overflowed => overflowCount > 0;
  bool get backpressureObserved => backpressurePauseCount > 0;

  WorkspaceFileExplorerWatchTelemetry recordBatch(
    WorkspaceFileExplorerWatchEventBatch batch, {
    required int backpressurePauseCount,
  }) {
    return WorkspaceFileExplorerWatchTelemetry(
      totalEventCount: totalEventCount + batch.eventCount,
      batchCount: batchCount + 1,
      overflowCount: overflowCount,
      droppedEventCount: droppedEventCount,
      backpressurePauseCount: backpressurePauseCount,
      maxBatchEventCount: batch.eventCount > maxBatchEventCount
          ? batch.eventCount
          : maxBatchEventCount,
      lastBatchLatency: batch.flushedAt.difference(batch.firstEventAt),
    );
  }

  WorkspaceFileExplorerWatchTelemetry recordOverflow(
    FileSystemWatchOverflowException overflow, {
    required int backpressurePauseCount,
  }) {
    return WorkspaceFileExplorerWatchTelemetry(
      totalEventCount: totalEventCount,
      batchCount: batchCount,
      overflowCount: overflowCount + 1,
      droppedEventCount: droppedEventCount + (overflow.droppedEventCount ?? 0),
      backpressurePauseCount: backpressurePauseCount,
      maxBatchEventCount: maxBatchEventCount,
      lastBatchLatency: lastBatchLatency,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'totalEventCount': totalEventCount,
      'batchCount': batchCount,
      'overflowCount': overflowCount,
      'droppedEventCount': droppedEventCount,
      'backpressurePauseCount': backpressurePauseCount,
      'maxBatchEventCount': maxBatchEventCount,
      'lastBatchLatencyMs': lastBatchLatency.inMilliseconds,
      'overflowed': overflowed,
      'backpressureObserved': backpressureObserved,
      'historyMode': 'checkpointed-latest-batch',
    };
  }
}

class WorkspaceFileExplorerWatchEventBatcher {
  WorkspaceFileExplorerWatchEventBatcher({
    this.policy = const WorkspaceFileExplorerWatchDebouncePolicy(),
  });

  final WorkspaceFileExplorerWatchDebouncePolicy policy;
  final List<WorkspaceFileExplorerWatchEvent> _events =
      <WorkspaceFileExplorerWatchEvent>[];
  DateTime? _firstEventAt;

  int get pendingEventCount => _events.length;

  WorkspaceFileExplorerWatchEventBatch? add(
    WorkspaceFileExplorerWatchEvent event,
  ) {
    _firstEventAt ??= event.timestamp;
    _events.add(event);
    if (!policy.shouldFlush(
      firstEventAt: _firstEventAt!,
      latestEventAt: event.timestamp,
      eventCount: _events.length,
    )) {
      return null;
    }
    return flush(flushedAt: event.timestamp);
  }

  WorkspaceFileExplorerWatchEventBatch? flush({required DateTime flushedAt}) {
    final firstEventAt = _firstEventAt;
    if (firstEventAt == null || _events.isEmpty) {
      return null;
    }
    final batch = WorkspaceFileExplorerWatchEventBatch(
      events: List<WorkspaceFileExplorerWatchEvent>.unmodifiable(_events),
      firstEventAt: firstEventAt,
      flushedAt: flushedAt,
    );
    _events.clear();
    _firstEventAt = null;
    return batch;
  }
}

class WorkspaceFileExplorerWatchStreamBatcher {
  const WorkspaceFileExplorerWatchStreamBatcher({
    this.policy = const WorkspaceFileExplorerWatchDebouncePolicy(),
    DateTime Function()? clock,
    this.onBackpressureChanged,
  }) : _clock = clock ?? _defaultWorkspaceFileExplorerWatchClock;

  final WorkspaceFileExplorerWatchDebouncePolicy policy;
  final DateTime Function() _clock;
  final void Function(bool paused)? onBackpressureChanged;

  Stream<WorkspaceFileExplorerWatchEventBatch> bind(
    Stream<WorkspaceFileExplorerWatchEvent> events,
  ) {
    final batcher = WorkspaceFileExplorerWatchEventBatcher(policy: policy);
    late final StreamController<WorkspaceFileExplorerWatchEventBatch> output;
    StreamSubscription<WorkspaceFileExplorerWatchEvent>? subscription;
    Timer? timer;

    void cancelTimer() {
      timer?.cancel();
      timer = null;
    }

    void flush(DateTime flushedAt) {
      final batch = batcher.flush(flushedAt: flushedAt);
      if (batch != null && !output.isClosed) {
        output.add(batch);
      }
    }

    void scheduleFlush() {
      cancelTimer();
      timer = Timer(policy.window, () {
        cancelTimer();
        flush(_clock());
      });
    }

    output = StreamController<WorkspaceFileExplorerWatchEventBatch>(
      onListen: () {
        subscription = events.listen(
          (event) {
            final batch = batcher.add(event);
            if (batch != null) {
              cancelTimer();
              output.add(batch);
              return;
            }
            scheduleFlush();
          },
          onError: output.addError,
          onDone: () async {
            cancelTimer();
            flush(_clock());
            await output.close();
          },
        );
      },
      onCancel: () async {
        cancelTimer();
        await subscription?.cancel();
      },
      onPause: () {
        subscription?.pause();
        onBackpressureChanged?.call(true);
      },
      onResume: () {
        subscription?.resume();
        onBackpressureChanged?.call(false);
      },
    );

    return output.stream;
  }
}

class WorkspaceFileExplorerWatchSnapshot {
  const WorkspaceFileExplorerWatchSnapshot({
    required this.plan,
    this.baseFilePaths = const <String>[],
    this.events = const <WorkspaceFileExplorerWatchEvent>[],
    this.telemetry = const WorkspaceFileExplorerWatchTelemetry(),
  });

  final WorkspaceFileExplorerWatchPlan plan;
  final List<String> baseFilePaths;
  final List<WorkspaceFileExplorerWatchEvent> events;
  final WorkspaceFileExplorerWatchTelemetry telemetry;

  List<String> get filePaths {
    final ignoreRules = plan.ignoreRules;
    final paths = <String>{};
    for (final basePath in baseFilePaths) {
      final normalizedPath = _normalizeWorkspaceFileExplorerPath(basePath);
      final relativePath = _workspaceFileExplorerPathRelativeToRoot(
        rootPath: plan.rootPath,
        path: normalizedPath,
        caseSensitive: plan.caseSensitivePaths,
      );
      if (_isWorkspaceFileExplorerWatchPathAllowed(
            normalizedPath,
            rootPath: plan.rootPath,
            caseSensitive: plan.caseSensitivePaths,
          ) &&
          !ignoreRules.ignores(
            relativePath,
            caseSensitive: plan.caseSensitivePaths,
          )) {
        paths.add(normalizedPath);
      }
    }
    for (final event in events) {
      final path = _normalizeWorkspaceFileExplorerPath(event.path);
      final nextPath = _normalizeWorkspaceFileExplorerPath(event.nextPath);
      final relativePath = _workspaceFileExplorerPathRelativeToRoot(
        rootPath: plan.rootPath,
        path: path,
        caseSensitive: plan.caseSensitivePaths,
      );
      if (!_isWorkspaceFileExplorerWatchPathAllowed(
            path,
            rootPath: plan.rootPath,
            caseSensitive: plan.caseSensitivePaths,
          ) ||
          ignoreRules.ignores(
            relativePath,
            caseSensitive: plan.caseSensitivePaths,
          )) {
        continue;
      }
      switch (event.kind) {
        case WorkspaceFileExplorerWatchEventKind.created:
          paths.add(path);
        case WorkspaceFileExplorerWatchEventKind.modified:
          paths.add(path);
        case WorkspaceFileExplorerWatchEventKind.deleted:
          paths.remove(path);
        case WorkspaceFileExplorerWatchEventKind.renamed:
          paths.remove(path);
          final relativeNextPath = _workspaceFileExplorerPathRelativeToRoot(
            rootPath: plan.rootPath,
            path: nextPath,
            caseSensitive: plan.caseSensitivePaths,
          );
          if (_isWorkspaceFileExplorerWatchPathAllowed(
                nextPath,
                rootPath: plan.rootPath,
                caseSensitive: plan.caseSensitivePaths,
              ) &&
              !ignoreRules.ignores(
                relativeNextPath,
                caseSensitive: plan.caseSensitivePaths,
              )) {
            paths.add(nextPath);
          }
      }
    }
    final result = paths.toList(growable: false)..sort();
    return List<String>.unmodifiable(result);
  }

  int get eventCount => events.length;

  WorkspaceFileExplorerDiscoveryResult toDiscoveryResult() {
    return WorkspaceFileExplorerDiscoveryResult(
      source: '${plan.source}.watch',
      filePaths: filePaths,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'plan': plan.toJson(),
      'eventCount': eventCount,
      'fileCount': filePaths.length,
      'filePaths': filePaths,
      'events': events.map((event) => event.toJson()).toList(growable: false),
      'telemetry': telemetry.toJson(),
    };
  }
}

class WorkspaceFileExplorerFileSystemDiscoveryBinding {
  const WorkspaceFileExplorerFileSystemDiscoveryBinding({
    required this.fileSystemManager,
    required this.rootPath,
    this.seedPaths = const <String>[],
    this.ignoreRules = const WorkspaceFileExplorerIgnoreRules(
      excludeGlobs: <String>['.git/**', 'build/**'],
    ),
    this.maxFiles = 5000,
  });

  final FileSystemManager fileSystemManager;
  final String rootPath;
  final List<String> seedPaths;
  final WorkspaceFileExplorerIgnoreRules ignoreRules;
  final int maxFiles;

  Future<WorkspaceFileExplorerDiscoveryResult> discover() async {
    final entities = await fileSystemManager.list(rootPath, recursive: true);
    final candidates = <String>[
      for (final seedPath in seedPaths)
        _workspaceFileExplorerRelativePath(
          rootPath: rootPath,
          path: seedPath,
          fileSystemManager: fileSystemManager,
        ),
      for (final entity in entities)
        if (entity.isFile)
          _workspaceFileExplorerRelativePath(
            rootPath: rootPath,
            path: entity.normalizedPath.isEmpty
                ? entity.path
                : entity.normalizedPath,
            fileSystemManager: fileSystemManager,
          ),
    ];
    final visibleCandidates = <String>[];
    final ignoredPaths = <String>[];
    for (final path in candidates) {
      if (ignoreRules.ignores(
        path,
        caseSensitive: fileSystemManager.compatibility.caseSensitive,
      )) {
        ignoredPaths.add(path);
      } else {
        visibleCandidates.add(path);
      }
    }
    final normalized = WorkspaceFileExplorerDiscoveryResult.fromPaths(
      discoveredPaths: visibleCandidates,
      source: 'file-system-manager.list',
      maxFiles: maxFiles,
    );
    return WorkspaceFileExplorerDiscoveryResult(
      source: normalized.source,
      filePaths: normalized.filePaths,
      ignoredPaths: List<String>.unmodifiable(<String>[
        ...normalized.ignoredPaths,
        ...ignoredPaths,
      ]),
      truncated: normalized.truncated,
    );
  }
}

class WorkspaceFileExplorerFileSystemWatcherBinding {
  WorkspaceFileExplorerFileSystemWatcherBinding({
    required this.fileSystemManager,
    required this.plan,
    this.baseFilePaths = const <String>[],
    DateTime Function()? clock,
  }) : clock = clock ?? _defaultWorkspaceFileExplorerWatchClock;

  final FileSystemManager fileSystemManager;
  final WorkspaceFileExplorerWatchPlan plan;
  final List<String> baseFilePaths;
  final DateTime Function() clock;

  Stream<WorkspaceFileExplorerWatchSnapshot> watch() async* {
    final activePlan = plan.activate(
      message: 'File System Manager watch attached.',
    );
    var checkpointPaths = List<String>.unmodifiable(baseFilePaths);
    var telemetry = const WorkspaceFileExplorerWatchTelemetry();
    var backpressurePauseCount = 0;
    yield WorkspaceFileExplorerWatchSnapshot(
      plan: activePlan,
      baseFilePaths: checkpointPaths,
      telemetry: telemetry,
    );
    try {
      final batches = WorkspaceFileExplorerWatchStreamBatcher(
        policy: plan.debouncePolicy,
        clock: clock,
        onBackpressureChanged: (paused) {
          if (paused) {
            backpressurePauseCount += 1;
          }
        },
      ).bind(_watchExplorerEvents(activePlan));
      await for (final batch in batches) {
        telemetry = telemetry.recordBatch(
          batch,
          backpressurePauseCount: backpressurePauseCount,
        );
        final snapshot = WorkspaceFileExplorerWatchSnapshot(
          plan: activePlan,
          baseFilePaths: checkpointPaths,
          events: batch.events,
          telemetry: telemetry,
        );
        checkpointPaths = snapshot.filePaths;
        yield snapshot;
      }
    } on Object catch (error) {
      if (error is FileSystemWatchOverflowException) {
        telemetry = telemetry.recordOverflow(
          error,
          backpressurePauseCount: backpressurePauseCount,
        );
      }
      yield WorkspaceFileExplorerWatchSnapshot(
        plan: plan.block(
          error is FileSystemWatchOverflowException
              ? 'File System Manager watch overflowed; refresh the explorer to rebuild its authoritative snapshot.'
              : 'File System Manager watch failed; refresh the explorer to reconnect.',
        ),
        baseFilePaths: checkpointPaths,
        telemetry: telemetry,
      );
    }
  }

  Stream<WorkspaceFileExplorerWatchEvent> _watchExplorerEvents(
    WorkspaceFileExplorerWatchPlan activePlan,
  ) async* {
    final preserveAbsolutePaths = baseFilePaths.any(
      _isAbsoluteWorkspaceFileExplorerPath,
    );
    await for (final event in fileSystemManager.watch(
      plan.rootPath,
      recursive: plan.recursive,
    )) {
      final explorerEvent = _workspaceFileExplorerEventFromFileSystem(
        event,
        rootPath: plan.rootPath,
        fileSystemManager: fileSystemManager,
        timestamp: clock(),
      );
      if (explorerEvent == null) {
        continue;
      }
      if (!_isWorkspaceFileExplorerWatchPathAllowed(
        explorerEvent.path,
        rootPath: plan.rootPath,
        caseSensitive: activePlan.caseSensitivePaths,
      )) {
        continue;
      }
      if (activePlan.ignoreRules.ignores(
        explorerEvent.path,
        caseSensitive: activePlan.caseSensitivePaths,
      )) {
        continue;
      }
      if (!preserveAbsolutePaths) {
        yield explorerEvent;
        continue;
      }
      yield WorkspaceFileExplorerWatchEvent(
        kind: explorerEvent.kind,
        path: _workspaceFileExplorerAbsolutePath(
          rootPath: plan.rootPath,
          path: explorerEvent.path,
        ),
        nextPath: explorerEvent.nextPath.isEmpty
            ? ''
            : _workspaceFileExplorerAbsolutePath(
                rootPath: plan.rootPath,
                path: explorerEvent.nextPath,
              ),
        source: explorerEvent.source,
        timestamp: explorerEvent.timestamp,
      );
    }
  }
}

DateTime _defaultWorkspaceFileExplorerWatchClock() => DateTime.now().toUtc();

WorkspaceFileExplorerWatchEvent? _workspaceFileExplorerEventFromFileSystem(
  FileSystemManagerEvent event, {
  required String rootPath,
  required FileSystemManager fileSystemManager,
  required DateTime timestamp,
}) {
  final kind = switch (event.kind) {
    FileSystemManagerEventKind.created =>
      WorkspaceFileExplorerWatchEventKind.created,
    FileSystemManagerEventKind.modified ||
    FileSystemManagerEventKind.metadataChanged ||
    FileSystemManagerEventKind.moved =>
      WorkspaceFileExplorerWatchEventKind.modified,
    FileSystemManagerEventKind.deleted =>
      WorkspaceFileExplorerWatchEventKind.deleted,
    FileSystemManagerEventKind.unknown => null,
  };
  if (kind == null || event.isDirectory) {
    return null;
  }
  return WorkspaceFileExplorerWatchEvent(
    kind: kind,
    path: _workspaceFileExplorerRelativePath(
      rootPath: rootPath,
      path: event.normalizedPath.isEmpty ? event.path : event.normalizedPath,
      fileSystemManager: fileSystemManager,
    ),
    source: 'file-system-manager.watch',
    timestamp: timestamp,
  );
}

String _workspaceFileExplorerRelativePath({
  required String rootPath,
  required String path,
  required FileSystemManager fileSystemManager,
}) {
  final managerRoot = fileSystemManager.normalizePath(rootPath);
  final managerPath = fileSystemManager.normalizePath(path);
  final normalizedRoot = _normalizeWorkspaceFileExplorerPath(managerRoot);
  final normalizedPath = _normalizeWorkspaceFileExplorerPath(managerPath);
  if (!fileSystemManager.compatibility.isAbsolutePath(managerPath)) {
    return normalizedPath;
  }
  if (!fileSystemManager.isWithin(managerPath, managerRoot)) {
    return normalizedPath;
  }
  final prefix = normalizedRoot.endsWith('/')
      ? normalizedRoot
      : '$normalizedRoot/';
  final pathStartsWithRoot = fileSystemManager.compatibility.caseSensitive
      ? normalizedPath.startsWith(prefix)
      : normalizedPath.toLowerCase().startsWith(prefix.toLowerCase());
  if (pathStartsWithRoot) {
    return normalizedPath.substring(prefix.length);
  }
  return normalizedPath;
}

String _normalizeWorkspaceFileExplorerPath(String path) {
  return path.trim().replaceAll('\\', '/');
}

bool _isAbsoluteWorkspaceFileExplorerPath(String path) {
  final normalizedPath = _normalizeWorkspaceFileExplorerPath(path);
  return normalizedPath.startsWith('/') ||
      RegExp(r'^[A-Za-z]:/').hasMatch(normalizedPath);
}

bool _workspaceFileExplorerPathsEqual(
  String left,
  String right, {
  required bool caseSensitive,
}) {
  final normalizedLeft = _normalizeWorkspaceFileExplorerPath(left);
  final normalizedRight = _normalizeWorkspaceFileExplorerPath(right);
  return caseSensitive
      ? normalizedLeft == normalizedRight
      : normalizedLeft.toLowerCase() == normalizedRight.toLowerCase();
}

bool _usesCaseInsensitiveWorkspaceFileExplorerPaths(String rootPath) {
  final normalizedRoot = _normalizeWorkspaceFileExplorerPath(rootPath);
  return RegExp(r'^[A-Za-z]:/').hasMatch(normalizedRoot) ||
      normalizedRoot.startsWith('//');
}

String _workspaceFileExplorerAbsolutePath({
  required String rootPath,
  required String path,
}) {
  final normalizedPath = _normalizeWorkspaceFileExplorerPath(path);
  if (_isAbsoluteWorkspaceFileExplorerPath(normalizedPath)) {
    return normalizedPath;
  }
  final normalizedRoot = _normalizeWorkspaceFileExplorerPath(
    rootPath,
  ).replaceFirst(RegExp(r'/+$'), '');
  return normalizedRoot.isEmpty
      ? normalizedPath
      : '$normalizedRoot/$normalizedPath';
}

String _workspaceFileExplorerPathRelativeToRoot({
  required String rootPath,
  required String path,
  required bool caseSensitive,
}) {
  final normalizedRoot = _normalizeWorkspaceFileExplorerPath(
    rootPath,
  ).replaceFirst(RegExp(r'/+$'), '');
  final normalizedPath = _normalizeWorkspaceFileExplorerPath(path);
  final rootPrefix = '$normalizedRoot/';
  final pathStartsWithRoot = caseSensitive
      ? normalizedPath.startsWith(rootPrefix)
      : normalizedPath.toLowerCase().startsWith(rootPrefix.toLowerCase());
  if (normalizedRoot.isNotEmpty && pathStartsWithRoot) {
    return normalizedPath.substring(normalizedRoot.length + 1);
  }
  return normalizedPath;
}

bool _isWorkspaceFileExplorerWatchPathAllowed(
  String path, {
  required String rootPath,
  required bool caseSensitive,
}) {
  if (!_isAbsoluteWorkspaceFileExplorerPath(path)) {
    return _validateWorkspaceFileExplorerPath(path) == null;
  }
  final relativePath = _workspaceFileExplorerPathRelativeToRoot(
    rootPath: rootPath,
    path: path,
    caseSensitive: caseSensitive,
  );
  return relativePath != path &&
      _validateWorkspaceFileExplorerPath(relativePath) == null;
}

String? _validateWorkspaceFileExplorerPath(String path) {
  if (path.isEmpty) {
    return 'Workspace file path is empty.';
  }
  if (_isAbsoluteWorkspaceFileExplorerPath(path) ||
      path.split('/').contains('..')) {
    return 'Workspace file path must stay inside the workspace.';
  }
  return null;
}

class WorkspaceFileExplorerActionRequest {
  const WorkspaceFileExplorerActionRequest({
    required this.kind,
    required this.path,
    this.nextPath = '',
    this.text = '',
    this.open = false,
  });

  final WorkspaceFileOperationKind kind;
  final String path;
  final String nextPath;
  final String text;
  final bool open;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'kind': kind.wireValue,
      'path': path,
      if (nextPath.isNotEmpty) 'nextPath': nextPath,
      if (text.isNotEmpty) 'textLength': text.length,
      'open': open,
    };
  }
}

enum WorkspaceFileExplorerActionRisk {
  safe,
  createsFile,
  writesFile,
  destructive,
}

extension WorkspaceFileExplorerActionRiskX on WorkspaceFileExplorerActionRisk {
  String get wireValue {
    return switch (this) {
      WorkspaceFileExplorerActionRisk.safe => 'safe',
      WorkspaceFileExplorerActionRisk.createsFile => 'creates-file',
      WorkspaceFileExplorerActionRisk.writesFile => 'writes-file',
      WorkspaceFileExplorerActionRisk.destructive => 'destructive',
    };
  }
}

WorkspaceFileExplorerActionRisk _workspaceFileExplorerRiskFor(
  WorkspaceFileOperationKind kind,
) {
  return switch (kind) {
    WorkspaceFileOperationKind.create =>
      WorkspaceFileExplorerActionRisk.createsFile,
    WorkspaceFileOperationKind.rename =>
      WorkspaceFileExplorerActionRisk.writesFile,
    WorkspaceFileOperationKind.delete =>
      WorkspaceFileExplorerActionRisk.destructive,
    WorkspaceFileOperationKind.reveal => WorkspaceFileExplorerActionRisk.safe,
  };
}

class WorkspaceFileExplorerConfirmationPlan {
  const WorkspaceFileExplorerConfirmationPlan({
    required this.planId,
    required this.request,
    required this.title,
    required this.message,
    this.requiresConfirmation = true,
    this.risk = WorkspaceFileExplorerActionRisk.safe,
  });

  factory WorkspaceFileExplorerConfirmationPlan.fromRequest(
    WorkspaceFileExplorerActionRequest request,
  ) {
    final planId = 'workspace-file.${request.kind.wireValue}.${request.path}';
    return switch (request.kind) {
      WorkspaceFileOperationKind.create =>
        WorkspaceFileExplorerConfirmationPlan(
          planId: planId,
          request: request,
          title: 'Create workspace file',
          message: 'Create ${request.path} in the workspace file tree.',
          risk: _workspaceFileExplorerRiskFor(request.kind),
        ),
      WorkspaceFileOperationKind.rename =>
        WorkspaceFileExplorerConfirmationPlan(
          planId: planId,
          request: request,
          title: 'Rename workspace file',
          message: 'Rename ${request.path} to ${request.nextPath}.',
          risk: _workspaceFileExplorerRiskFor(request.kind),
        ),
      WorkspaceFileOperationKind.delete =>
        WorkspaceFileExplorerConfirmationPlan(
          planId: planId,
          request: request,
          title: 'Delete workspace file',
          message: 'Delete ${request.path} from the workspace.',
          risk: _workspaceFileExplorerRiskFor(request.kind),
        ),
      WorkspaceFileOperationKind.reveal =>
        WorkspaceFileExplorerConfirmationPlan(
          planId: planId,
          request: request,
          title: 'Reveal workspace file',
          message: 'Reveal ${request.path} in the workspace file tree.',
          requiresConfirmation: false,
          risk: _workspaceFileExplorerRiskFor(request.kind),
        ),
    };
  }

  final String planId;
  final WorkspaceFileExplorerActionRequest request;
  final String title;
  final String message;
  final bool requiresConfirmation;
  final WorkspaceFileExplorerActionRisk risk;

  bool get destructive => risk == WorkspaceFileExplorerActionRisk.destructive;
  bool get canRunWithoutDialog => !requiresConfirmation;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'planId': planId,
      'request': request.toJson(),
      'title': title,
      'message': message,
      'requiresConfirmation': requiresConfirmation,
      'risk': risk.wireValue,
      'destructive': destructive,
      'canRunWithoutDialog': canRunWithoutDialog,
    };
  }
}

class WorkspaceFileExplorerBatchActionPlan {
  const WorkspaceFileExplorerBatchActionPlan({
    required this.planId,
    required this.confirmationPlans,
    this.blockedReason = '',
  });

  factory WorkspaceFileExplorerBatchActionPlan.fromRequests(
    List<WorkspaceFileExplorerActionRequest> requests,
  ) {
    final confirmationPlans = requests
        .map(WorkspaceFileExplorerConfirmationPlan.fromRequest)
        .toList(growable: false);
    return WorkspaceFileExplorerBatchActionPlan(
      planId: 'workspace-file.batch.${confirmationPlans.length}',
      confirmationPlans:
          List<WorkspaceFileExplorerConfirmationPlan>.unmodifiable(
            confirmationPlans,
          ),
      blockedReason: confirmationPlans.isEmpty
          ? 'Workspace file batch action requires at least one request.'
          : '',
    );
  }

  final String planId;
  final List<WorkspaceFileExplorerConfirmationPlan> confirmationPlans;
  final String blockedReason;

  List<WorkspaceFileExplorerActionRequest> get requests {
    return confirmationPlans
        .map((plan) => plan.request)
        .toList(growable: false);
  }

  int get actionCount => confirmationPlans.length;
  int get destructiveActionCount {
    return confirmationPlans.where((plan) => plan.destructive).length;
  }

  bool get canRun => blockedReason.isEmpty;
  bool get destructive => destructiveActionCount > 0;
  bool get requiresConfirmation {
    return confirmationPlans.any((plan) => plan.requiresConfirmation);
  }

  bool get canRunWithoutDialog => canRun && !requiresConfirmation;

  String get summary {
    if (!canRun) {
      return blockedReason;
    }
    return 'workspace file batch: $actionCount action(s), '
        '$destructiveActionCount destructive.';
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'planId': planId,
      'actionCount': actionCount,
      'destructiveActionCount': destructiveActionCount,
      'requiresConfirmation': requiresConfirmation,
      'destructive': destructive,
      'canRun': canRun,
      'canRunWithoutDialog': canRunWithoutDialog,
      'summary': summary,
      if (blockedReason.isNotEmpty) 'blockedReason': blockedReason,
      'confirmationPlans': confirmationPlans
          .map((plan) => plan.toJson())
          .toList(growable: false),
    };
  }
}

class WorkspaceFileExplorerController extends ChangeNotifier {
  WorkspaceFileExplorerController({
    required this.workspaceController,
    required this.operationService,
    this.stateStore,
    this.fileSystemManager,
    String? stateWorkspaceId,
  }) {
    final initialRoots = buildWorkspaceFileExplorerTree(
      workspaceController.files,
    );
    _state = WorkspaceFileExplorerState(
      workspaceId: stateWorkspaceId ?? workspaceController.activeProject.id,
      expandedPaths: initialRoots
          .where((node) => node.kind == WorkspaceFileExplorerNodeKind.directory)
          .map((node) => node.path)
          .toList(growable: false),
    );
    _workspaceContextRootPath = _normalizeWorkspaceFileExplorerPath(
      workspaceController.activeProject.workspaceRoot,
    );
    _workspaceContextId = workspaceController.activeProject.id;
    workspaceController.addListener(_handleWorkspaceChanged);
  }

  final WorkspaceController workspaceController;
  final WorkspaceFileOperationService operationService;
  final WorkspaceFileExplorerStateStore? stateStore;
  final FileSystemManager? fileSystemManager;

  WorkspaceFileOperationResult? _lastResult;
  WorkspaceFileExplorerConfirmationPlan? _pendingConfirmationPlan;
  WorkspaceFileExplorerBatchActionPlan? _pendingBatchActionPlan;
  WorkspaceFileExplorerDiscoveryResult? _discovery;
  WorkspaceFileExplorerWatchSnapshot? _watchSnapshot;
  StreamSubscription<WorkspaceFileExplorerWatchSnapshot>? _watchSubscription;
  String _watchedRootPath = '';
  String _workspaceContextId = '';
  String _workspaceContextRootPath = '';
  int _syncGeneration = 0;
  bool _disposed = false;
  late WorkspaceFileExplorerState _state;

  WorkspaceFileOperationResult? get lastResult => _lastResult;
  WorkspaceFileExplorerConfirmationPlan? get pendingConfirmationPlan =>
      _pendingConfirmationPlan;
  WorkspaceFileExplorerBatchActionPlan? get pendingBatchActionPlan =>
      _pendingBatchActionPlan;
  WorkspaceFileExplorerDiscoveryResult? get discovery => _discovery;
  WorkspaceFileExplorerWatchSnapshot? get watchSnapshot => _watchSnapshot;
  WorkspaceFileExplorerState get state => _state;
  String get watchedRootPath => _watchedRootPath;

  String resolveWorkspacePath(String path) =>
      operationService.resolvePath(path);

  bool containsWorkspacePath(String path) =>
      operationService.containsPath(path);

  bool observesWorkspacePath(String path) {
    final observedPaths =
        _watchSnapshot?.filePaths ??
        _discovery?.filePaths ??
        workspaceController.files;
    final caseSensitive =
        fileSystemManager?.compatibility.caseSensitive ??
        !_usesCaseInsensitiveWorkspaceFileExplorerPaths(
          workspaceController.activeProject.workspaceRoot,
        );
    return observedPaths.any(
      (candidate) => _workspaceFileExplorerPathsEqual(
        candidate,
        path,
        caseSensitive: caseSensitive,
      ),
    );
  }

  String? registerObservedWorkspacePath(String path) {
    if (!observesWorkspacePath(path)) {
      return null;
    }
    final resolvedPath = resolveWorkspacePath(path);
    if (!containsWorkspacePath(resolvedPath)) {
      workspaceController.registerFile(resolvedPath);
    }
    return resolvedPath;
  }

  WorkspaceFileExplorerSnapshot get snapshot {
    final filePaths =
        _watchSnapshot?.filePaths ??
        _discovery?.filePaths ??
        workspaceController.files;
    return WorkspaceFileExplorerSnapshot(
      roots: buildWorkspaceFileExplorerTree(
        filePaths,
        sortMode: _state.sortMode,
      ),
      activeFilePath: workspaceController.activeFilePath,
      openFilePaths: workspaceController.openFilePaths,
      state: _state,
      discovery: _discovery,
      watch: _watchSnapshot,
    );
  }

  WorkspaceFileExplorerSnapshot snapshotFromDiscovery(
    WorkspaceFileExplorerDiscoveryResult discovery,
  ) {
    return WorkspaceFileExplorerSnapshot(
      roots: buildWorkspaceFileExplorerTree(
        discovery.filePaths,
        sortMode: _state.sortMode,
      ),
      activeFilePath: workspaceController.activeFilePath,
      openFilePaths: workspaceController.openFilePaths,
      state: _state,
      discovery: discovery,
    );
  }

  WorkspaceFileExplorerSnapshot snapshotFromWatch(
    WorkspaceFileExplorerWatchSnapshot watch,
  ) {
    return WorkspaceFileExplorerSnapshot(
      roots: buildWorkspaceFileExplorerTree(
        watch.filePaths,
        sortMode: _state.sortMode,
      ),
      activeFilePath: workspaceController.activeFilePath,
      openFilePaths: workspaceController.openFilePaths,
      state: _state,
      discovery: watch.toDiscoveryResult(),
      watch: watch,
    );
  }

  Future<WorkspaceFileExplorerState> restoreState() async {
    final store = stateStore;
    if (store == null) {
      return _state;
    }
    final workspaceId = _state.workspaceId;
    final restored = await store.readState(workspaceId: workspaceId);
    if (_disposed || _state.workspaceId != workspaceId) {
      return _state;
    }
    _state = restored;
    _notifyListeners();
    return _state;
  }

  Future<void> startFileSystemSync({required String rootPath}) async {
    await restoreState();
    if (_disposed) {
      return;
    }
    await refreshFileSystem(rootPath: rootPath);
  }

  Future<WorkspaceFileExplorerDiscoveryResult?> refreshFileSystem({
    String? rootPath,
  }) async {
    final manager = fileSystemManager;
    final resolvedRootPath = (rootPath ?? _watchedRootPath).trim();
    _watchedRootPath = resolvedRootPath;
    final generation = ++_syncGeneration;
    final previousSubscription = _watchSubscription;
    _watchSubscription = null;
    await previousSubscription?.cancel();
    if (!_isCurrentSync(generation, resolvedRootPath) ||
        manager == null ||
        resolvedRootPath.isEmpty) {
      return null;
    }
    try {
      final plan = WorkspaceFileExplorerWatchPlan(
        rootPath: resolvedRootPath,
        caseSensitivePaths: manager.compatibility.caseSensitive,
      );
      final discovered = await WorkspaceFileExplorerFileSystemDiscoveryBinding(
        fileSystemManager: manager,
        rootPath: resolvedRootPath,
        seedPaths: workspaceController.files,
        ignoreRules: plan.ignoreRules,
      ).discover();
      if (!_isCurrentSync(generation, resolvedRootPath)) {
        return null;
      }
      applyDiscoveryResult(_canonicalizeDiscovery(discovered));
      if (_state.updatedAt == null) {
        await expandDirectories(
          snapshot.roots
              .where(
                (node) => node.kind == WorkspaceFileExplorerNodeKind.directory,
              )
              .map((node) => node.path),
        );
      }
      if (!_isCurrentSync(generation, resolvedRootPath)) {
        return null;
      }
      _watchSubscription =
          WorkspaceFileExplorerFileSystemWatcherBinding(
            fileSystemManager: manager,
            plan: plan,
            baseFilePaths: _discovery!.filePaths,
          ).watch().listen((watch) {
            if (_isCurrentSync(generation, resolvedRootPath)) {
              applyWatchSnapshot(watch);
            }
          });
      return _discovery;
    } on Object {
      if (!_isCurrentSync(generation, resolvedRootPath)) {
        return null;
      }
      applyWatchSnapshot(
        WorkspaceFileExplorerWatchSnapshot(
          plan:
              WorkspaceFileExplorerWatchPlan(
                rootPath: resolvedRootPath,
                caseSensitivePaths: manager.compatibility.caseSensitive,
              ).block(
                'File System Manager discovery failed; refresh the explorer to retry.',
              ),
          baseFilePaths: workspaceController.files,
        ),
      );
      return null;
    }
  }

  Future<void> persistState() async {
    await stateStore?.saveState(_state);
  }

  Future<void> toggleDirectory(String path) async {
    _state = _state.toggleExpanded(path);
    await persistState();
    _notifyListeners();
  }

  Future<void> expandDirectories(Iterable<String> paths) async {
    final expandedPaths = <String>{..._state.expandedPaths};
    var changed = false;
    for (final path in paths) {
      final normalizedPath = _normalizeWorkspaceFileExplorerPath(path);
      if (normalizedPath.isNotEmpty && expandedPaths.add(normalizedPath)) {
        changed = true;
      }
    }
    if (!changed) {
      return;
    }
    _state = _state.copyWith(
      expandedPaths: expandedPaths.toList(growable: false),
      updatedAt: DateTime.now().toUtc(),
    );
    await persistState();
    _notifyListeners();
  }

  Future<void> selectPath(String path) async {
    _state = _state.selectPath(path);
    await persistState();
    _notifyListeners();
  }

  Future<void> revealPath(String path) async {
    _state = _state.revealPath(path);
    await persistState();
    _notifyListeners();
  }

  void applyDiscoveryResult(WorkspaceFileExplorerDiscoveryResult discovery) {
    if (_disposed) {
      return;
    }
    _discovery = discovery;
    _watchSnapshot = null;
    _notifyListeners();
  }

  void applyWatchSnapshot(WorkspaceFileExplorerWatchSnapshot watch) {
    if (_disposed) {
      return;
    }
    _watchSnapshot = watch;
    _discovery = watch.toDiscoveryResult();
    _notifyListeners();
  }

  Future<void> setSortMode(WorkspaceFileExplorerSortMode sortMode) async {
    _state = _state.withSortMode(sortMode);
    await persistState();
    _notifyListeners();
  }

  Future<WorkspaceFileOperationResult> run(
    WorkspaceFileExplorerActionRequest request,
  ) async {
    late final WorkspaceFileOperationResult result;
    try {
      result = switch (request.kind) {
        WorkspaceFileOperationKind.create => await operationService.createFile(
          path: request.path,
          text: request.text,
          open: request.open,
        ),
        WorkspaceFileOperationKind.rename => await operationService.renameFile(
          path: request.path,
          nextPath: request.nextPath,
          open: request.open,
        ),
        WorkspaceFileOperationKind.delete => await operationService.deleteFile(
          request.path,
        ),
        WorkspaceFileOperationKind.reveal => operationService.revealFile(
          request.path,
        ),
      };
    } on Object {
      result = WorkspaceFileOperationResult(
        kind: request.kind,
        applied: false,
        path: request.path,
        nextPath: request.nextPath,
        message:
            'Workspace file ${request.kind.wireValue} failed. Check the file provider and retry.',
      );
    }
    if (result.applied && request.kind == WorkspaceFileOperationKind.reveal) {
      _state = _state.revealPath(result.path);
      await persistState();
    }
    if (result.applied && request.kind != WorkspaceFileOperationKind.reveal) {
      _applyOperationToObservedPaths(result);
    }
    _lastResult = result;
    _notifyListeners();
    return result;
  }

  WorkspaceFileExplorerConfirmationPlan confirmationPlanFor(
    WorkspaceFileExplorerActionRequest request,
  ) {
    return WorkspaceFileExplorerConfirmationPlan.fromRequest(request);
  }

  WorkspaceFileExplorerBatchActionPlan batchPlanFor(
    List<WorkspaceFileExplorerActionRequest> requests,
  ) {
    return WorkspaceFileExplorerBatchActionPlan.fromRequests(requests);
  }

  WorkspaceFileExplorerConfirmationPlan stageAction(
    WorkspaceFileExplorerActionRequest request,
  ) {
    final plan = confirmationPlanFor(request);
    _pendingConfirmationPlan = plan;
    _pendingBatchActionPlan = null;
    _notifyListeners();
    return plan;
  }

  WorkspaceFileExplorerBatchActionPlan stageBatchActions(
    List<WorkspaceFileExplorerActionRequest> requests,
  ) {
    final plan = batchPlanFor(requests);
    _pendingBatchActionPlan = plan;
    _pendingConfirmationPlan = null;
    _notifyListeners();
    return plan;
  }

  void cancelPendingAction() {
    if (_pendingConfirmationPlan == null && _pendingBatchActionPlan == null) {
      return;
    }
    _pendingConfirmationPlan = null;
    _pendingBatchActionPlan = null;
    _notifyListeners();
  }

  Future<WorkspaceFileOperationResult?> runPendingAction({
    required bool confirmed,
  }) async {
    final plan = _pendingConfirmationPlan;
    if (plan == null) {
      return null;
    }
    if (plan.requiresConfirmation && !confirmed) {
      return null;
    }
    _pendingConfirmationPlan = null;
    return run(plan.request);
  }

  Future<List<WorkspaceFileOperationResult>> runPendingBatchAction({
    required bool confirmed,
  }) async {
    final plan = _pendingBatchActionPlan;
    if (plan == null || !plan.canRun) {
      return const <WorkspaceFileOperationResult>[];
    }
    if (plan.requiresConfirmation && !confirmed) {
      return const <WorkspaceFileOperationResult>[];
    }
    _pendingBatchActionPlan = null;
    final results = <WorkspaceFileOperationResult>[];
    for (final request in plan.requests) {
      results.add(await run(request));
    }
    return List<WorkspaceFileOperationResult>.unmodifiable(results);
  }

  void _handleWorkspaceChanged() {
    final project = workspaceController.activeProject;
    final nextRoot = _normalizeWorkspaceFileExplorerPath(project.workspaceRoot);
    if (_workspaceContextId != project.id ||
        _workspaceContextRootPath != nextRoot) {
      _workspaceContextId = project.id;
      _workspaceContextRootPath = nextRoot;
      _syncGeneration += 1;
      final previousSubscription = _watchSubscription;
      _watchSubscription = null;
      unawaited(previousSubscription?.cancel());
      _discovery = null;
      _watchSnapshot = null;
      _pendingConfirmationPlan = null;
      _pendingBatchActionPlan = null;
      final roots = buildWorkspaceFileExplorerTree(workspaceController.files);
      _state = WorkspaceFileExplorerState(
        workspaceId: project.id,
        expandedPaths: roots
            .where(
              (node) => node.kind == WorkspaceFileExplorerNodeKind.directory,
            )
            .map((node) => node.path)
            .toList(growable: false),
      );
      _notifyListeners();
      unawaited(startFileSystemSync(rootPath: project.workspaceRoot));
      return;
    }
    _notifyListeners();
  }

  bool _isCurrentSync(int generation, String rootPath) {
    return !_disposed &&
        generation == _syncGeneration &&
        rootPath == _watchedRootPath;
  }

  void _notifyListeners() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  WorkspaceFileExplorerDiscoveryResult _canonicalizeDiscovery(
    WorkspaceFileExplorerDiscoveryResult discovery,
  ) {
    final usesAbsolutePaths = workspaceController.files.any(
      (path) => _isAbsoluteWorkspaceFileExplorerPath(
        _normalizeWorkspaceFileExplorerPath(path),
      ),
    );
    if (!usesAbsolutePaths) {
      return discovery;
    }
    final rootPath = workspaceController.activeProject.workspaceRoot;
    final filePaths =
        discovery.filePaths
            .map(
              (path) => _workspaceFileExplorerAbsolutePath(
                rootPath: rootPath,
                path: path,
              ),
            )
            .toSet()
            .toList(growable: false)
          ..sort();
    return WorkspaceFileExplorerDiscoveryResult(
      source: discovery.source,
      filePaths: List<String>.unmodifiable(filePaths),
      ignoredPaths: discovery.ignoredPaths,
      truncated: discovery.truncated,
    );
  }

  void _applyOperationToObservedPaths(WorkspaceFileOperationResult result) {
    final paths = <String>{
      for (final path
          in _watchSnapshot?.filePaths ??
              _discovery?.filePaths ??
              workspaceController.files)
        _normalizeWorkspaceFileExplorerPath(path),
    };
    final path = _normalizeWorkspaceFileExplorerPath(result.path);
    final nextPath = _normalizeWorkspaceFileExplorerPath(result.nextPath);
    switch (result.kind) {
      case WorkspaceFileOperationKind.create:
        paths.add(path);
      case WorkspaceFileOperationKind.rename:
        paths
          ..remove(path)
          ..add(nextPath);
      case WorkspaceFileOperationKind.delete:
        paths.remove(path);
      case WorkspaceFileOperationKind.reveal:
        break;
    }
    final sortedPaths = paths.toList(growable: false)..sort();
    final watch = _watchSnapshot;
    if (watch != null) {
      _watchSnapshot = WorkspaceFileExplorerWatchSnapshot(
        plan: watch.plan,
        baseFilePaths: List<String>.unmodifiable(sortedPaths),
        telemetry: watch.telemetry,
      );
      _discovery = _watchSnapshot!.toDiscoveryResult();
      return;
    }
    if (_discovery != null) {
      _discovery = WorkspaceFileExplorerDiscoveryResult(
        source: _discovery!.source,
        filePaths: List<String>.unmodifiable(sortedPaths),
        ignoredPaths: _discovery!.ignoredPaths,
        truncated: _discovery!.truncated,
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _syncGeneration += 1;
    unawaited(_watchSubscription?.cancel());
    _watchSubscription = null;
    workspaceController.removeListener(_handleWorkspaceChanged);
    super.dispose();
  }
}

List<WorkspaceFileExplorerNode> buildWorkspaceFileExplorerTree(
  Iterable<String> filePaths, {
  WorkspaceFileExplorerSortMode sortMode =
      WorkspaceFileExplorerSortMode.foldersFirst,
}) {
  final root = _MutableWorkspaceFileExplorerNode.directory('', '');
  final sortedPaths =
      filePaths
          .map((path) => path.trim().replaceAll('\\', '/'))
          .where((path) => path.isNotEmpty)
          .toList(growable: false)
        ..sort();

  final prefix = _workspaceFileExplorerCommonDirectoryPrefix(sortedPaths);

  for (final filePath in sortedPaths) {
    final relativePath = prefix.isNotEmpty && filePath.startsWith('$prefix/')
        ? filePath.substring(prefix.length + 1)
        : filePath;
    final parts = relativePath
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    var cursor = root;
    var currentPath = prefix;
    for (var index = 0; index < parts.length; index += 1) {
      final part = parts[index];
      currentPath = currentPath.isEmpty ? part : '$currentPath/$part';
      final isFile = index == parts.length - 1;
      cursor = cursor.child(
        name: part,
        path: isFile ? filePath : currentPath,
        kind: isFile
            ? WorkspaceFileExplorerNodeKind.file
            : WorkspaceFileExplorerNodeKind.directory,
      );
    }
  }

  return root.freeze(sortMode).children;
}

String _workspaceFileExplorerCommonDirectoryPrefix(List<String> filePaths) {
  if (filePaths.isEmpty) {
    return '';
  }
  final pathSegments = filePaths
      .map(
        (path) => path
            .split('/')
            .where((segment) => segment.isNotEmpty)
            .toList(growable: false),
      )
      .toList(growable: false);
  final first = pathSegments.first;
  final prefix = <String>[];
  for (var index = 0; index < first.length - 1; index += 1) {
    final segment = first[index];
    if (!pathSegments.every(
      (segments) => segments.length > index + 1 && segments[index] == segment,
    )) {
      break;
    }
    prefix.add(segment);
  }
  if (prefix.isEmpty) {
    return '';
  }
  final joined = prefix.join('/');
  if (filePaths.first.startsWith('//')) {
    return '//$joined';
  }
  return filePaths.first.startsWith('/') ? '/$joined' : joined;
}

class _MutableWorkspaceFileExplorerNode {
  _MutableWorkspaceFileExplorerNode({
    required this.name,
    required this.path,
    required this.kind,
  });

  factory _MutableWorkspaceFileExplorerNode.directory(
    String name,
    String path,
  ) {
    return _MutableWorkspaceFileExplorerNode(
      name: name,
      path: path,
      kind: WorkspaceFileExplorerNodeKind.directory,
    );
  }

  final String name;
  final String path;
  final WorkspaceFileExplorerNodeKind kind;
  final Map<String, _MutableWorkspaceFileExplorerNode> _childrenByPath =
      <String, _MutableWorkspaceFileExplorerNode>{};

  _MutableWorkspaceFileExplorerNode child({
    required String name,
    required String path,
    required WorkspaceFileExplorerNodeKind kind,
  }) {
    return _childrenByPath.putIfAbsent(
      '${kind.wireValue}:$path',
      () =>
          _MutableWorkspaceFileExplorerNode(name: name, path: path, kind: kind),
    );
  }

  WorkspaceFileExplorerNode freeze(WorkspaceFileExplorerSortMode sortMode) {
    final sortedChildren = _childrenByPath.values.toList(growable: false)
      ..sort((left, right) {
        if (sortMode == WorkspaceFileExplorerSortMode.foldersFirst &&
            left.kind != right.kind) {
          return left.kind == WorkspaceFileExplorerNodeKind.directory ? -1 : 1;
        }
        return left.name.toLowerCase().compareTo(right.name.toLowerCase());
      });
    return WorkspaceFileExplorerNode(
      name: name,
      path: path,
      kind: kind,
      children: sortedChildren
          .map((child) => child.freeze(sortMode))
          .toList(growable: false),
    );
  }
}
