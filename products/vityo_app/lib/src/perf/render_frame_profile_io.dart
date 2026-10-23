import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FrameTiming, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'package:vityo_app/src/app/app_bootstrap.dart';
import 'package:vityo_app/src/ide/editor/editor.dart';
import 'package:vityo_app/src/ide/editor/input/editor_composition.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/project_graph_adapter_io.dart';
import 'package:vityo_app/src/view_render/shell/shell_model.dart';
import 'package:vityo_app/src/view_render/shell/shell_scope.dart';

import 'frame_timing_statistics.dart';

/// Frozen receipt identifier for the render frame-time diagnostic lane.
const String kRenderFrameProfileReceiptVersion = 'render-frame-profile-v1';

/// Keystroke lane measured against engine-delivered vsync frames.
///
/// Requires a visible, unoccluded window: macOS stops a window's display link
/// when it is occluded, minimized, or on another Space, and no frames are
/// produced at all in that state.
const String kVsyncDrivenScenario = 'frame_timing';

/// Keystroke lane that drives the frame callbacks itself.
///
/// Measures the UI-thread build, layout, paint and scene cost of one
/// keystroke with raster and vsync scheduling excluded, so it is deterministic
/// and needs no foreground window.
const String kUiThreadBuildCostScenario = 'ui_thread_build_cost';

const String _activationFlag = '--vityo-render-frame-profile';
const int _virtualFrameIntervalMicros = 16667;

RenderFrameProfileRun? _pendingRun;
int _commitSequence = 0;
int _virtualClockMicros = 0;

/// A parsed, self-contained render frame-time profile request.
final class RenderFrameProfileRun {
  RenderFrameProfileRun({
    required this.scenario,
    required this.workspaceRoot,
    required this.receiptPath,
    required this.label,
    required this.fixtureDocumentLines,
    required this.warmupKeystrokes,
    required this.measuredKeystrokes,
    required this.discardedWarmupFrames,
    required this.keystrokeInterval,
    required this.inputBudgetMicros,
  });

  final String scenario;
  final String workspaceRoot;
  final String receiptPath;
  final String label;
  final int fixtureDocumentLines;
  final int warmupKeystrokes;
  final int measuredKeystrokes;
  final int discardedWarmupFrames;
  final Duration keystrokeInterval;
  final int inputBudgetMicros;

  /// True when this lane supplies its own frame callbacks.
  bool get drivesFramesManually => scenario == kUiThreadBuildCostScenario;

  /// True when this lane reports engine raster and vsync numbers.
  bool get reportsRaster => scenario == kVsyncDrivenScenario;

  String get fixturePath {
    return '${Directory(workspaceRoot).path}${Platform.pathSeparator}scratch'
        '${Platform.pathSeparator}main.styio';
  }
}

/// Opt-in entry point. Redirects the project root before any bootstrap work so
/// the run never touches a real user workspace.
Future<bool> prepareRenderFrameProfile(List<String> arguments) async {
  _pendingRun = null;
  if (!arguments.contains(_activationFlag)) {
    return false;
  }
  final workspace = _value(arguments, '--workspace');
  final receipt = _value(arguments, '--out');
  if (workspace == null || receipt == null) {
    throw ArgumentError(
      '$_activationFlag requires --workspace and --out.',
    );
  }
  final scenario = _value(arguments, '--scenario') ?? kVsyncDrivenScenario;
  if (scenario != kVsyncDrivenScenario &&
      scenario != kUiThreadBuildCostScenario) {
    throw ArgumentError(
      'Unknown --scenario $scenario. Expected $kVsyncDrivenScenario or '
      '$kUiThreadBuildCostScenario.',
    );
  }
  // Every run gets a private root. Workspace documents are cached by the
  // vityod daemon across launches, so a shared root would let a previous run's
  // saved buffer silently replace the generated fixture.
  final runId = DateTime.now().microsecondsSinceEpoch;
  final root = Directory(
    '${Directory(workspace).absolute.path}${Platform.pathSeparator}r$runId',
  );
  await root.create(recursive: true);
  _pendingRun = RenderFrameProfileRun(
    scenario: scenario,
    workspaceRoot: root.path,
    receiptPath: File(receipt).absolute.path,
    label: _value(arguments, '--label') ?? 'unlabelled',
    fixtureDocumentLines: _positiveInt(arguments, '--document-lines', 2000),
    warmupKeystrokes: _nonNegativeInt(arguments, '--warmup-keystrokes', 20),
    measuredKeystrokes: _positiveInt(arguments, '--measured-keystrokes', 60),
    discardedWarmupFrames: _nonNegativeInt(
      arguments,
      '--discarded-warmup-frames',
      0,
    ),
    keystrokeInterval: Duration(
      microseconds: _positiveInt(
        arguments,
        '--keystroke-interval-micros',
        16000,
      ),
    ),
    inputBudgetMicros: _positiveInt(arguments, '--input-budget-micros', 16000),
  );
  debugOverrideProjectGraphEnvironment(<String, String>{
    ...Platform.environment,
    'PWD': root.path,
  });
  final fixture = File(_pendingRun!.fixturePath);
  await fixture.parent.create(recursive: true);
  await fixture.writeAsString(
    _fixtureSource(_pendingRun!.fixtureDocumentLines),
    flush: true,
  );
  return true;
}

/// Drives the scripted keystroke lane and writes the receipt.
Future<void> runPreparedRenderFrameProfile({
  required AppBootstrap bootstrap,
}) async {
  final run = _pendingRun;
  if (run == null) {
    return;
  }
  _pendingRun = null;
  final recorder = _FrameTimingRecorder();
  SchedulerBinding.instance.addTimingsCallback(recorder.add);
  ShellModel? shell;
  Map<String, Object?> receipt;
  try {
    shell = await _awaitShell(run);
    final controller = bootstrap.editorController;
    _requireFixtureDocument(controller.document, run);
    controller.selectCollapsed(_caretOffsetFor(controller.document));
    await _settle(const Duration(milliseconds: 600), run);
    for (var index = 0; index < run.warmupKeystrokes; index += 1) {
      await _typeOneKeystroke(controller, _scriptCharacter(index), run);
    }
    await _settle(const Duration(milliseconds: 400), run);
    recorder.reset();
    final latencies = <int>[];
    for (var index = 0; index < run.measuredKeystrokes; index += 1) {
      latencies.add(
        await _typeOneKeystroke(
          controller,
          _scriptCharacter(run.warmupKeystrokes + index),
          run,
        ),
      );
    }
    await _settle(const Duration(milliseconds: 400), run);
    receipt = _buildReceipt(run, controller, recorder, latencies);
  } catch (error, stackTrace) {
    receipt = <String, Object?>{
      'receipt': kRenderFrameProfileReceiptVersion,
      'status': 'failed',
      'label': run.label,
      'scenario': run.scenario,
      'error': error.toString(),
      'stackTrace': stackTrace.toString(),
      if (shell != null) 'workspaceFiles': shell.workspaceController.files,
      'documentId': bootstrap.editorController.document.documentId,
      'documentLength': bootstrap.editorController.document.text.length,
    };
  } finally {
    SchedulerBinding.instance.removeTimingsCallback(recorder.add);
  }
  await _writeReceipt(run.receiptPath, receipt);
  exit(receipt['status'] == 'completed' ? 0 : 2);
}

/// Collects the four parallel `FrameTiming` series the statistics layer needs.
final class _FrameTimingRecorder {
  final List<int> buildMicros = <int>[];
  final List<int> rasterMicros = <int>[];
  final List<int> totalSpanMicros = <int>[];
  final List<int> vsyncOverheadMicros = <int>[];

  void add(List<FrameTiming> timings) {
    for (final timing in timings) {
      buildMicros.add(timing.buildDuration.inMicroseconds);
      rasterMicros.add(timing.rasterDuration.inMicroseconds);
      totalSpanMicros.add(timing.totalSpan.inMicroseconds);
      vsyncOverheadMicros.add(timing.vsyncOverhead.inMicroseconds);
    }
  }

  void reset() {
    buildMicros.clear();
    rasterMicros.clear();
    totalSpanMicros.clear();
    vsyncOverheadMicros.clear();
  }
}

Map<String, Object?> _buildReceipt(
  RenderFrameProfileRun run,
  EditorSessionController controller,
  _FrameTimingRecorder recorder,
  List<int> latencies,
) {
  final display = PlatformDispatcher.instance.implicitView?.display;
  final refreshRate = display?.refreshRate ?? 0;
  final budgetMicros =
      refreshRate > 0 ? (1000000 / refreshRate).round() : run.inputBudgetMicros;
  final receipt = <String, Object?>{
    'receipt': kRenderFrameProfileReceiptVersion,
    'status': 'completed',
    'label': run.label,
    'scenario': run.scenario,
    'buildMode': _buildModeLabel,
    'timeDilation': timeDilation,
    'frameSource': run.drivesFramesManually ? 'harness' : 'engine_vsync',
    'rasterIncluded': run.reportsRaster,
    'keystrokeIntervalMicros': run.keystrokeInterval.inMicroseconds,
    'fixture': <String, Object?>{
      'workspaceRoot': run.workspaceRoot,
      'documentId': controller.document.documentId,
      'documentLines': '\n'.allMatches(controller.document.text).length + 1,
      'documentLength': controller.document.text.length,
    },
    'keystrokes': <String, Object?>{
      'warmup': run.warmupKeystrokes,
      'measured': run.measuredKeystrokes,
    },
  };
  if (display != null) {
    receipt['display'] = <String, Object?>{
      'id': display.id,
      'devicePixelRatio': display.devicePixelRatio,
      'width': display.size.width,
      'height': display.size.height,
      'refreshRate': refreshRate,
      'budgetMicros': budgetMicros,
    };
  }
  if (latencies.isNotEmpty) {
    receipt['keystrokeCost'] = summarizeLatencies(
      latencies,
      budgetMicros: run.inputBudgetMicros,
    ).toJson();
  }
  if (run.reportsRaster && recorder.buildMicros.isNotEmpty) {
    receipt['frameTimings'] = summarizeFrameTimings(
      buildMicros: recorder.buildMicros,
      rasterMicros: recorder.rasterMicros,
      totalSpanMicros: recorder.totalSpanMicros,
      vsyncOverheadMicros: recorder.vsyncOverheadMicros,
      warmupFrameCount: run.discardedWarmupFrames,
      budgetMicros: budgetMicros,
    ).toJson();
  }
  return receipt;
}

String get _buildModeLabel {
  if (kReleaseMode) {
    return 'release';
  }
  if (kProfileMode) {
    return 'profile';
  }
  return 'debug';
}

Future<ShellModel> _awaitShell(RenderFrameProfileRun run) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    final shell = _shellModelOrNull();
    if (shell != null) {
      await _settle(const Duration(milliseconds: 200), run);
      return shell;
    }
    await _settle(const Duration(milliseconds: 16), run);
  }
  throw StateError('The workbench shell never mounted.');
}

ShellModel? _shellModelOrNull() {
  final root = WidgetsBinding.instance.rootElement;
  if (root == null) {
    return null;
  }
  final pending = <Element>[root];
  while (pending.isNotEmpty) {
    final element = pending.removeAt(0);
    final widget = element.widget;
    if (widget is ShellScope) {
      final notifier = widget.notifier;
      if (notifier != null) {
        return notifier;
      }
    }
    element.visitChildren(pending.add);
  }
  return null;
}

/// Fails loudly unless the editor really holds the generated fixture.
///
/// Reporting frame costs for a document other than the fixture would make the
/// whole before/after comparison meaningless, so an unread fixture is a hard
/// failure rather than a quietly different measurement.
void _requireFixtureDocument(
  DocumentState document,
  RenderFrameProfileRun run,
) {
  final expected = _fixtureSource(run.fixtureDocumentLines);
  if (document.text.length != expected.length) {
    throw StateError(
      'The editor did not load the generated fixture. Expected '
      '${expected.length} code units, found ${document.text.length} in '
      '${document.documentId}.',
    );
  }
}

/// Commits one scripted character and returns the UI-thread cost of the frame
/// that rendered it.
///
/// A pending frame is drained first so the measurement can never land on a
/// frame that predates the commit.
Future<int> _typeOneKeystroke(
  EditorSessionController controller,
  String character,
  RenderFrameProfileRun run,
) async {
  if (run.drivesFramesManually) {
    _drainPendingFrame();
  } else if (SchedulerBinding.instance.hasScheduledFrame) {
    await _awaitFrame(const Duration(seconds: 5), 'drain');
  }
  final document = controller.document;
  final clock = Stopwatch()..start();
  final committed = controller.commitEditorInput(
    EditorCompositionCommitIntent(
      documentId: document.documentId,
      expectedRevision: document.revision,
      selectionSet: controller.selectionSet,
      text: character,
      connectionGeneration: 0,
      sequence: _commitSequence++,
      reason: EditorCompositionTransitionReason.directCommit,
    ),
  );
  if (!committed) {
    throw StateError(
      'The scripted keystroke was rejected at revision ${document.revision}.',
    );
  }
  if (run.drivesFramesManually) {
    clock.stop();
    final cost = _driveOneFrame();
    await _settle(run.keystrokeInterval, run);
    return cost;
  }
  await _awaitFrame(const Duration(seconds: 5), 'render');
  clock.stop();
  await _settle(run.keystrokeInterval, run);
  return clock.elapsedMicroseconds;
}

/// Runs one complete frame and returns its UI-thread cost in microseconds.
///
/// The two callbacks run synchronously back to back, so a concurrently
/// delivered engine frame can never interleave with them: Dart is single
/// threaded and an engine callback can only run while this lane is awaiting.
/// That is also why a visible window is not required. Profile builds compile
/// framework asserts out, so driving the callbacks with no pending engine frame
/// is legal, and the virtual clock keeps ticker timestamps monotonic.
int _driveOneFrame() {
  _virtualClockMicros += _virtualFrameIntervalMicros;
  final clock = Stopwatch()..start();
  SchedulerBinding.instance.handleBeginFrame(
    Duration(microseconds: _virtualClockMicros),
  );
  SchedulerBinding.instance.handleDrawFrame();
  clock.stop();
  return clock.elapsedMicroseconds;
}

void _drainPendingFrame() {
  if (SchedulerBinding.instance.hasScheduledFrame) {
    _driveOneFrame();
  }
}

/// Awaits the end of the next engine-delivered frame with a hard deadline.
///
/// A macOS window that is fully occluded, minimized, or on another Space stops
/// its display link, so the engine never ticks and `endOfFrame` would wait
/// forever. Numbers collected in that state are meaningless, so the lane fails
/// with an actionable message instead of hanging.
Future<void> _awaitFrame(Duration timeout, String phase) {
  return Future.any<void>(<Future<void>>[
    SchedulerBinding.instance.endOfFrame,
    Future<void>.delayed(timeout).then<void>((_) {
      throw StateError(
        'No engine frame was produced during $phase within '
        '${timeout.inMilliseconds}ms. An occluded, minimized or backgrounded '
        'macOS window stops its display link. Bring the Vityo window to the '
        'front, or rerun with --scenario $kUiThreadBuildCostScenario which '
        'needs no visible window.',
      );
    }),
  ]);
}

Future<void> _settle(Duration duration, RenderFrameProfileRun run) async {
  final deadline = DateTime.now().add(duration);
  while (DateTime.now().isBefore(deadline)) {
    if (run.drivesFramesManually) {
      _drainPendingFrame();
    }
    await Future<void>.delayed(const Duration(milliseconds: 4));
  }
}

String _scriptCharacter(int index) {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz';
  return alphabet[index % alphabet.length];
}

int _caretOffsetFor(DocumentState document) {
  final text = document.text;
  if (text.isEmpty) {
    return 0;
  }
  final middle = text.length ~/ 2;
  final boundary = text.indexOf('\n', middle);
  return boundary < 0 ? text.length : boundary;
}

String _fixtureSource(int lineCount) {
  final buffer = StringBuffer();
  var written = 0;
  for (var task = 0; written < lineCount; task += 1) {
    if (task > 0) {
      buffer.writeln();
      written += 1;
    }
    if (written >= lineCount) {
      break;
    }
    for (final line in <String>[
      'fn task_$task(input: stream) {',
      '  let stage_$task = input |> normalize -> shade -> commit',
      '  when stage_$task.ready -> emit stage_$task',
      '  emit stage_$task',
      '}',
    ]) {
      if (written >= lineCount) {
        break;
      }
      buffer.writeln(line);
      written += 1;
    }
  }
  return buffer.toString();
}

Future<void> _writeReceipt(String path, Map<String, Object?> receipt) async {
  final target = File(path);
  await target.parent.create(recursive: true);
  final temporary = File('$path.tmp');
  await temporary.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(receipt)}\n',
    flush: true,
  );
  await temporary.rename(target.path);
}

String? _value(List<String> arguments, String option) {
  final index = arguments.indexOf(option);
  if (index < 0 || index + 1 >= arguments.length) {
    return null;
  }
  return arguments[index + 1];
}

int _positiveInt(List<String> arguments, String option, int fallback) {
  final value = int.tryParse(_value(arguments, option) ?? '');
  if (value == null || value <= 0) {
    return fallback;
  }
  return value;
}

int _nonNegativeInt(List<String> arguments, String option, int fallback) {
  final value = int.tryParse(_value(arguments, option) ?? '');
  if (value == null || value < 0) {
    return fallback;
  }
  return value;
}
