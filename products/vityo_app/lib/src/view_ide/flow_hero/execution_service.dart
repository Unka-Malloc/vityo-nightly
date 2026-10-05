/// Flow Hero's slice of the real project execution stack.
///
/// Mirrors `language_service.dart`: probe the toolchain, build a real route,
/// degrade honestly. The route spawns `pafio --json run|test` in the real
/// workspace through the platform process manager (vityod-owned where one is
/// wired) and reads the schema-v1 receipt pafio wrote under `plan.build_root`.
/// Nothing here is simulated: when the workspace, the manifest, the pafio
/// binary, or the Styio compiler is missing, the runtime stays `unavailable`
/// and names the reason so the RUN control can disable itself honestly.
library;

import 'package:flutter/foundation.dart';

import '../../ide/local_service/vityod_client.dart';
import '../backend_toolchain/bundled_toolchain_candidates.dart';
import '../backend_toolchain/execution_adapter.dart';
import '../backend_toolchain/pafio_cli_discovery.dart';
import '../backend_toolchain/pafio_cli_support.dart';
import '../environment/configuration/host_environment.dart';
import '../environment/system_compatibility/file_system/file_system_manager.dart';
import '../environment/system_compatibility/platform_manager/platform_manager.dart';
import '../environment/system_compatibility/process/process_manager.dart';
import '../toolchain/toolchain.dart';
import 'toolchain_store.dart';

/// Catalog id under which `styio_toolchain_discovery_io.dart` registers the
/// discovered Styio CLI. Pafio needs it as `--styio-bin`.
const String _styioCliToolchainId = 'local-styio-language-service';

/// Workspace manifest pafio reads; the same file the project graph uses.
const String kFlowHeroPafioManifestName = 'pafio.toml';

/// What Flow Hero asks pafio to do. One entry per real `pafio` subcommand.
enum FlowHeroExecutionKind {
  run('run'),
  test('test');

  const FlowHeroExecutionKind(this.command);

  final String command;
}

/// Honest state of Flow Hero's execution route.
enum FlowHeroExecutionMode {
  /// A pafio binary, a Styio compiler, and a manifest were all resolved.
  live,

  /// Nothing was resolved; RUN/TEST must disable itself and say why.
  unavailable,
}

/// How far a real execution has progressed in this session.
enum FlowHeroExecutionPhase { idle, pending, running, succeeded, failed }

/// Why an execution route cannot run, classified by the route that failed to
/// boot. The RUN strip renders its missing state from this instead of parsing
/// prose or assuming the cause was pafio.
enum FlowHeroExecutionUnavailableCause {
  /// No workspace root is configured.
  workspace,

  /// The workspace has no `pafio.toml`.
  manifest,

  /// One or more local tool binaries could not be resolved.
  toolchain,

  /// The toolchain probe itself failed before resolving anything.
  probeFailed,
}

/// One finished pafio invocation, described only by the facts pafio returned.
class FlowHeroExecutionOutcome {
  const FlowHeroExecutionOutcome({
    required this.kind,
    required this.phase,
    required this.statusLine,
    required this.receiptText,
    required this.duration,
    this.exitCode,
    this.receipt,
  });

  final FlowHeroExecutionKind kind;
  final FlowHeroExecutionPhase phase;

  /// Short label for the run strip and the settings row.
  final String statusLine;

  /// The chat-rail receipt: a summary of the real receipt/session, never a
  /// claim about work that did not happen.
  final String receiptText;

  final Duration duration;
  final int? exitCode;
  final ExecutionReceiptSnapshot? receipt;

  bool get succeeded => phase == FlowHeroExecutionPhase.succeeded;
}

/// The execution route Flow Hero's controller drives. A fake stands in for
/// tests and for embedding; the production implementation spawns pafio.
abstract class FlowHeroExecutionSource {
  FlowHeroExecutionMode get mode;

  /// True only when a real pafio invocation can be started right now.
  bool get live;

  /// Human-readable route label for the settings panel.
  String get statusLine;

  /// Why execution is unavailable; empty while [live].
  String get unavailableReason;

  /// Runs [kind] and reports what actually happened.
  ///
  /// [onStarted] fires once the child process is live, so the caller can move
  /// from `pending` to `running` on a real event rather than a timer.
  Future<FlowHeroExecutionOutcome> execute(
    FlowHeroExecutionKind kind, {
    VoidCallback? onStarted,
  });

  /// Asks the running child to stop. Returns false when the platform process
  /// manager cannot cancel, so the caller can say so instead of pretending.
  Future<bool> cancel();

  Future<void> dispose();
}

/// One location a run's toolchain probe looked at, reported so the install
/// dialog can show where pafio/styio were sought instead of guessing.
class FlowHeroToolchainCheck {
  const FlowHeroToolchainCheck({required this.source, required this.path});

  /// Which slot this is: the environment variable, the stored selection, the
  /// app-bundled component, or the system locations.
  final String source;

  /// The concrete path(s) checked, or an honest placeholder when unset.
  final String path;
}

/// A route that can say *which* tool is missing and where it looked. Separate
/// from [FlowHeroExecutionSource] so a scripted source stays simple.
abstract interface class FlowHeroToolchainDiagnosis {
  /// The tools this route could not resolve. Empty while live.
  Set<FlowHeroToolchainKind> get missingToolchains;

  /// Where each tool was sought during the last boot.
  Map<FlowHeroToolchainKind, List<FlowHeroToolchainCheck>> get toolchainChecks;

  /// The class of cause behind the unavailable route; null while live or when
  /// the route could not classify its own failure.
  FlowHeroExecutionUnavailableCause? get unavailableCause;
}

/// System locations the Styio CLI discovery probes after the bundled copy.
///
/// Mirrors `styio_toolchain_discovery_io.dart`'s own defaults, which are not
/// exported; the install dialog lists them so the user sees the real search
/// order. The environment variable and a stored selection both outrank them.
const List<String> kFlowHeroStyioSystemCandidatePaths = <String>[
  '/usr/local/bin/styio',
  '/usr/bin/styio',
  '/opt/homebrew/bin/styio',
];

/// Boots the real pafio route and, while live, executes through it.
class FlowHeroExecutionRuntime
    implements FlowHeroExecutionSource, FlowHeroToolchainDiagnosis {
  FlowHeroExecutionRuntime._({
    required this.mode,
    required this.statusLine,
    required this.unavailableReason,
    required String workspaceRoot,
    ProcessManager? process,
    FileSystemManager? fileSystem,
    String pafioBinaryPath = '',
    String styioBinaryPath = '',
    String manifestPath = '',
    Set<FlowHeroToolchainKind> missingToolchains =
        const <FlowHeroToolchainKind>{},
    Map<FlowHeroToolchainKind, List<FlowHeroToolchainCheck>> toolchainChecks =
        const <FlowHeroToolchainKind, List<FlowHeroToolchainCheck>>{},
    FlowHeroExecutionUnavailableCause? unavailableCause,
  }) : _workspaceRoot = workspaceRoot,
       _process = process,
       _fileSystem = fileSystem,
       _pafioBinaryPath = pafioBinaryPath,
       _styioBinaryPath = styioBinaryPath,
       _manifestPath = manifestPath,
       _missingToolchains = missingToolchains,
       _toolchainChecks = toolchainChecks,
       _unavailableCause = unavailableCause;

  /// Probes for pafio and the Styio compiler independently, then checks
  /// `pafio.toml`, and reports one honest state. Never throws: any failure
  /// yields an unavailable runtime.
  ///
  /// Tool resolution order (highest first):
  ///
  /// 1. `VITYO_PAFIO_BIN` / `VITYO_STYIO_BIN` from the environment.
  /// 2. [toolchainSelection] — the binary the user picked in the install
  ///    dialog and that Flow Hero stored in `toolchain.json`.
  /// 3. The app-bundled component beside the Vityo executable.
  /// 4. System locations.
  ///
  /// The Styio discovery only understands "environment, bundled, candidate
  /// list", so the stored selection is delivered as that probe's explicit
  /// override when the real environment set none. That is the one slot that
  /// sits between the environment and the bundled copy; `candidatePaths` is
  /// checked last and would put the user's pick below the bundled copy.
  ///
  /// [platformManagers], [environment] and [pafioSystemCandidatePaths] exist so
  /// tests can boot hermetically; production callers leave them alone.
  ///
  /// [vityodClient] is the app-shared local-service client. Without it the
  /// detected bundle's process manager is the unsupported variant, so the
  /// `pafio --version` probe can never spawn and every boot reports "未发现
  /// pafio" no matter where the binary actually is.
  static Future<FlowHeroExecutionRuntime> boot({
    required String workspaceRoot,
    PlatformManagerBundle? platformManagers,
    VityodClient? vityodClient,
    FlowHeroToolchainSelection toolchainSelection =
        const FlowHeroToolchainSelection(),
    Map<String, String>? environment,
    Iterable<String> pafioSystemCandidatePaths =
        kDefaultPafioSystemCandidatePaths,
  }) async {
    if (workspaceRoot.trim().isEmpty) {
      return FlowHeroExecutionRuntime._(
        mode: FlowHeroExecutionMode.unavailable,
        statusLine: '未配置工作区',
        unavailableReason: '未配置工作区 · 无法执行项目',
        workspaceRoot: workspaceRoot,
        unavailableCause: FlowHeroExecutionUnavailableCause.workspace,
      );
    }
    try {
      final managers =
          platformManagers ??
          await createDetectedPlatformManagerBundle(
            workspaceRoot: workspaceRoot,
            vityodClient: vityodClient,
          );
      final hostEnvironment = environment ?? readHostEnvironment();
      final checks = _checksByKind(
        environment: hostEnvironment,
        selection: toolchainSelection,
      );
      final pafioBinary = await resolvePafioBinary(
        managers,
        environment: hostEnvironment,
        extraCandidatePaths: <String>[toolchainSelection.pafioPath],
        systemCandidatePaths: pafioSystemCandidatePaths,
      );
      final styioEnvironment = Map<String, String>.of(hostEnvironment);
      if (toolchainSelection.styioPath.isNotEmpty &&
          (styioEnvironment['VITYO_STYIO_BIN'] ?? '').isEmpty) {
        styioEnvironment['VITYO_STYIO_BIN'] = toolchainSelection.styioPath;
      }
      final catalog = await createPlatformStyioLanguageToolchainCatalog(
        platformManagers: managers,
        environment: styioEnvironment,
      );
      final styioBinary =
          catalog.lookup(_styioCliToolchainId)?.executablePath.trim() ?? '';
      if (pafioBinary == null) {
        // Both tools are probed before reporting, so the install dialog can
        // offer a section for each one that is actually missing.
        return FlowHeroExecutionRuntime._(
          mode: FlowHeroExecutionMode.unavailable,
          statusLine: '未发现 pafio',
          unavailableReason: '未发现 pafio · 请安装或设置 VITYO_PAFIO_BIN',
          workspaceRoot: workspaceRoot,
          missingToolchains: <FlowHeroToolchainKind>{
            FlowHeroToolchainKind.pafio,
            if (styioBinary.isEmpty) FlowHeroToolchainKind.styio,
          },
          toolchainChecks: checks,
          unavailableCause: FlowHeroExecutionUnavailableCause.toolchain,
        );
      }
      if (styioBinary.isEmpty) {
        return FlowHeroExecutionRuntime._(
          mode: FlowHeroExecutionMode.unavailable,
          statusLine: '未发现 styio 编译器',
          unavailableReason: '未发现 styio 编译器 · 设置 VITYO_STYIO_BIN',
          workspaceRoot: workspaceRoot,
          missingToolchains: const <FlowHeroToolchainKind>{
            FlowHeroToolchainKind.styio,
          },
          toolchainChecks: checks,
          unavailableCause: FlowHeroExecutionUnavailableCause.toolchain,
        );
      }
      final String manifestPath = managers.fileSystem.joinPath(<String>[
        workspaceRoot,
        kFlowHeroPafioManifestName,
      ]);
      if (!await managers.fileSystem.exists(manifestPath)) {
        return FlowHeroExecutionRuntime._(
          mode: FlowHeroExecutionMode.unavailable,
          statusLine: '工作区缺少 pafio.toml',
          unavailableReason: '工作区缺少 $kFlowHeroPafioManifestName',
          workspaceRoot: workspaceRoot,
          toolchainChecks: checks,
          unavailableCause: FlowHeroExecutionUnavailableCause.manifest,
        );
      }
      return FlowHeroExecutionRuntime._(
        mode: FlowHeroExecutionMode.live,
        statusLine: 'pafio run/test',
        unavailableReason: '',
        workspaceRoot: workspaceRoot,
        process: managers.process,
        fileSystem: managers.fileSystem,
        pafioBinaryPath: pafioBinary,
        styioBinaryPath: styioBinary,
        manifestPath: manifestPath,
        toolchainChecks: checks,
      );
    } on Object {
      return FlowHeroExecutionRuntime._(
        mode: FlowHeroExecutionMode.unavailable,
        statusLine: '执行服务不可用',
        unavailableReason: '执行服务不可用 · 无法探测本地工具链',
        workspaceRoot: workspaceRoot,
        unavailableCause: FlowHeroExecutionUnavailableCause.probeFailed,
      );
    }
  }

  /// The four slots each tool was probed in, in resolution order.
  static Map<FlowHeroToolchainKind, List<FlowHeroToolchainCheck>>
  _checksByKind({
    required Map<String, String> environment,
    required FlowHeroToolchainSelection selection,
  }) {
    return <FlowHeroToolchainKind, List<FlowHeroToolchainCheck>>{
      FlowHeroToolchainKind.pafio: _checksFor(
        kind: FlowHeroToolchainKind.pafio,
        environment: environment,
        selectedPath: selection.pafioPath,
        bundledPaths: <String>[
          if (bundledPafioComponentManifestPath() case final String path) path,
        ],
        systemPaths: kDefaultPafioSystemCandidatePaths,
      ),
      FlowHeroToolchainKind.styio: _checksFor(
        kind: FlowHeroToolchainKind.styio,
        environment: environment,
        selectedPath: selection.styioPath,
        bundledPaths: bundledToolchainCandidatePaths('styio'),
        systemPaths: kFlowHeroStyioSystemCandidatePaths,
      ),
    };
  }

  static List<FlowHeroToolchainCheck> _checksFor({
    required FlowHeroToolchainKind kind,
    required Map<String, String> environment,
    required String selectedPath,
    required List<String> bundledPaths,
    required List<String> systemPaths,
  }) {
    final String environmentPath = (environment[kind.environmentVariable] ?? '')
        .trim();
    return <FlowHeroToolchainCheck>[
      FlowHeroToolchainCheck(
        source: '环境变量 ${kind.environmentVariable}',
        path: environmentPath.isEmpty ? '（未设置）' : environmentPath,
      ),
      FlowHeroToolchainCheck(
        source: '已保存的用户选择',
        path: selectedPath.isEmpty ? '（未保存）' : selectedPath,
      ),
      FlowHeroToolchainCheck(
        source: '应用内置',
        path: bundledPaths.isEmpty ? '（无法确定）' : bundledPaths.join(' · '),
      ),
      FlowHeroToolchainCheck(
        source: '系统路径',
        path: systemPaths.isEmpty ? '（无）' : systemPaths.join(' · '),
      ),
    ];
  }

  /// Route built from already-resolved facts. Tests use it to exercise the
  /// envelope/receipt path against a scripted process manager and a host
  /// filesystem fixture, without building a whole platform bundle.
  @visibleForTesting
  factory FlowHeroExecutionRuntime.forTesting({
    required ProcessManager process,
    required FileSystemManager fileSystem,
    required String workspaceRoot,
    required String pafioBinaryPath,
    required String styioBinaryPath,
    required String manifestPath,
  }) {
    return FlowHeroExecutionRuntime._(
      mode: FlowHeroExecutionMode.live,
      statusLine: 'pafio run/test',
      unavailableReason: '',
      workspaceRoot: workspaceRoot,
      process: process,
      fileSystem: fileSystem,
      pafioBinaryPath: pafioBinaryPath,
      styioBinaryPath: styioBinaryPath,
      manifestPath: manifestPath,
    );
  }

  @override
  final FlowHeroExecutionMode mode;

  @override
  final String statusLine;

  @override
  final String unavailableReason;

  final String _workspaceRoot;
  final ProcessManager? _process;
  final FileSystemManager? _fileSystem;
  final String _pafioBinaryPath;
  final String _styioBinaryPath;
  final String _manifestPath;
  final Set<FlowHeroToolchainKind> _missingToolchains;
  final Map<FlowHeroToolchainKind, List<FlowHeroToolchainCheck>>
  _toolchainChecks;
  final FlowHeroExecutionUnavailableCause? _unavailableCause;

  ProcessCommandHandle? _handle;
  bool _running = false;
  bool _cancelled = false;
  bool _disposed = false;

  /// The pafio executable this route resolved; empty while unavailable. Exposed
  /// so a caller can verify *which* binary a boot actually picked.
  String get pafioBinaryPath => _pafioBinaryPath;

  /// The Styio compiler this route resolved; empty while unavailable.
  String get styioBinaryPath => _styioBinaryPath;

  @override
  Set<FlowHeroToolchainKind> get missingToolchains => _missingToolchains;

  @override
  Map<FlowHeroToolchainKind, List<FlowHeroToolchainCheck>>
  get toolchainChecks => _toolchainChecks;

  @override
  FlowHeroExecutionUnavailableCause? get unavailableCause => _unavailableCause;

  @override
  bool get live => mode == FlowHeroExecutionMode.live && _process != null;

  @override
  Future<FlowHeroExecutionOutcome> execute(
    FlowHeroExecutionKind kind, {
    VoidCallback? onStarted,
  }) async {
    final process = _process;
    if (_disposed || !live || process == null) {
      return FlowHeroExecutionOutcome(
        kind: kind,
        phase: FlowHeroExecutionPhase.failed,
        statusLine: unavailableReason.isEmpty ? '执行路由不可用' : unavailableReason,
        receiptText:
            '$kind 未执行 · ${unavailableReason.isEmpty ? '执行路由不可用' : unavailableReason}',
        duration: Duration.zero,
      );
    }
    if (_running) {
      return FlowHeroExecutionOutcome(
        kind: kind,
        phase: FlowHeroExecutionPhase.failed,
        statusLine: '已有一次执行在进行',
        receiptText: '未启动新的执行 · 上一次仍在进行',
        duration: Duration.zero,
      );
    }
    _running = true;
    _cancelled = false;
    final Stopwatch clock = Stopwatch()..start();
    try {
      final result = await process.run(
        ProcessCommandRequest(
          executablePath: _pafioBinaryPath,
          arguments: <String>[
            '--json',
            kind.command,
            '--manifest-path',
            _manifestPath,
            '--styio-bin',
            _styioBinaryPath,
          ],
          workingDirectory: _workspaceRoot,
          serviceKind: ProcessServiceKind.pafio,
          onStarted: (ProcessCommandHandle handle) {
            _handle = handle;
            onStarted?.call();
          },
        ),
      );
      clock.stop();
      _handle = null;
      if (_cancelled) {
        return FlowHeroExecutionOutcome(
          kind: kind,
          phase: FlowHeroExecutionPhase.failed,
          statusLine: '已中断',
          receiptText: '${kind.command} 已中断 · ${_seconds(clock.elapsed)}',
          duration: clock.elapsed,
          exitCode: result.exitCode,
        );
      }
      return _outcomeFromResult(
        kind,
        result,
        duration: result.duration > Duration.zero
            ? result.duration
            : clock.elapsed,
      );
    } on Object catch (error) {
      clock.stop();
      _handle = null;
      return FlowHeroExecutionOutcome(
        kind: kind,
        phase: FlowHeroExecutionPhase.failed,
        statusLine: '启动失败',
        receiptText:
            '${kind.command} 启动失败 · ${_sanitize('$error')} · ${_seconds(clock.elapsed)}',
        duration: clock.elapsed,
      );
    } finally {
      _running = false;
    }
  }

  Future<FlowHeroExecutionOutcome> _outcomeFromResult(
    FlowHeroExecutionKind kind,
    ProcessCommandResult result, {
    required Duration duration,
  }) async {
    final successPayload = parseJsonObjectPayload(result.stdout);
    final failurePayload = parseJsonObjectPayload(result.stderr);
    if (!result.succeeded) {
      final message =
          _stringValue(failurePayload?['message']) ??
          (result.exitCode == null
              ? 'pafio ${kind.command} 未返回退出码'
              : 'pafio ${kind.command} 退出码 ${result.exitCode}');
      return FlowHeroExecutionOutcome(
        kind: kind,
        phase: FlowHeroExecutionPhase.failed,
        statusLine: '失败 · exit ${result.exitCode ?? '?'}',
        receiptText:
            '${kind.command} 失败 · ${_sanitize(message)} · ${_seconds(duration)}',
        duration: duration,
        exitCode: result.exitCode,
      );
    }
    final plan = successPayload?['plan'];
    final buildRoot = await _resolveBuildRoot(
      plan is Map ? _stringValue(plan['build_root']) : null,
    );
    final receipt = await _readReceipt(buildRoot);
    final String summary = receipt == null
        ? '${kind.command} 通过 · ${_seconds(duration)}'
        : '${kind.command} 通过 · ${_seconds(duration)} · 阶段 '
              '${receipt.phases.length} · 产物 ${receipt.artifacts.length}'
              ' · 会话 ${receipt.sessionId}';
    return FlowHeroExecutionOutcome(
      kind: kind,
      phase: FlowHeroExecutionPhase.succeeded,
      statusLine: '通过 · ${_seconds(duration)}',
      receiptText: summary,
      duration: duration,
      exitCode: result.exitCode,
      receipt: receipt,
    );
  }

  /// Re-expresses pafio's reported build root under the workspace root and
  /// rejects anything outside the tree pafio owns.
  Future<String?> _resolveBuildRoot(String? reported) async {
    final fileSystem = _fileSystem;
    if (fileSystem == null || reported == null || reported.isEmpty) {
      return null;
    }
    final joined = _isAbsolutePath(reported)
        ? reported
        : fileSystem.joinPath(<String>[_workspaceRoot, reported]);
    try {
      if (!await fileSystem.exists(joined)) {
        return null;
      }
      if (!fileSystem.isWithin(joined, _workspaceRoot)) {
        return null;
      }
      return joined;
    } on Object {
      return null;
    }
  }

  Future<ExecutionReceiptSnapshot?> _readReceipt(String? buildRoot) async {
    final fileSystem = _fileSystem;
    if (fileSystem == null || buildRoot == null || buildRoot.isEmpty) {
      return null;
    }
    final receiptPath = fileSystem.joinPath(<String>[
      buildRoot,
      'receipt.json',
    ]);
    try {
      if (!await fileSystem.exists(receiptPath)) {
        return null;
      }
      final raw = parseJsonObjectPayload(
        await fileSystem.readText(receiptPath),
      );
      return ExecutionReceiptSnapshot.decode(
        raw,
        fallbackSessionId: 'flow-hero',
      );
    } on Object {
      return null;
    }
  }

  @override
  Future<bool> cancel() async {
    _cancelled = true;
    final handle = _handle;
    final process = _process;
    if (handle == null || process == null) {
      return false;
    }
    if (process is! CancellableProcessManager) {
      return false;
    }
    try {
      final result = await (process as CancellableProcessManager).cancelProcess(
        handle.processHandleId,
      );
      return result.accepted;
    } on Object {
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await cancel();
  }
}

String _seconds(Duration duration) =>
    '${(duration.inMilliseconds / 1000).toStringAsFixed(2)}s';

String? _stringValue(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (value is num || value is bool) {
    return '$value';
  }
  return null;
}

bool _isAbsolutePath(String path) {
  return path.startsWith('/') ||
      path.startsWith(r'\') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
}

/// Producer messages can embed absolute paths; the workbench never shows them.
String _sanitize(String message) {
  return message.replaceAllMapped(
    RegExp(r'(?:[A-Za-z]:[\\/]|/)\S*'),
    (match) => '<path>',
  );
}
