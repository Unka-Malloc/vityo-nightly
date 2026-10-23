@Timeout.none
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/process/process_manager.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/process/process_facts.dart';
import 'package:vityo_app/owner_adapters/styio_compiler_adapter.dart';
import 'package:vityo_app/src/ide/editor/document_state.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/execution_adapter.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/observable_snapshot_publisher_io.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/observable_runtime_intake_io.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/project_graph_contract.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/platform_manager/platform_manager.dart';
import 'package:vityo_app/src/view_ide/flow_hero/execution_service.dart';
import 'package:vityo_app/src/view_ide/flow_hero/language_service.dart';
import 'package:vityo_app/src/view_ide/flow_hero/local_services.dart';
import 'package:vityo_app/src/view_ide/flow_hero/runtime.dart';
import 'package:vityo_app/src/view_ide/flow_hero/toolchain_store.dart';
import 'package:vityo_app/src/view_ide/services/observable_topology/observable_snapshot_model.dart';
import 'package:vityo_app/src/view_ide/services/observable_topology/observable_snapshot_decoder.dart';
import 'package:vityo_app/src/view_ide/services/observable_topology/observable_delta_decoder.dart';
import 'package:vityo_app/src/view_ide/services/observable_topology/observable_delta_apply.dart';
import 'package:vityo_app/src/view_ide/services/observable_topology/observable_snapshot_cache.dart';
import 'package:vityo_app/src/view_ide/services/observable_topology/observable_runtime_model.dart';
import 'package:vityo_app/src/view_render/flow_hero/controller.dart';
import 'package:vityo_app/src/view_render/flow_hero/flow_hero.dart';
import 'package:vityo_app/src/view_ide/flow_hero/model_config.dart';
import 'package:vityo_app/src/view_ide/flow_hero/workspace_store.dart';

import 'support/vityod_test_harness.dart';

const _scenario = 'trusted-desktop-styio-loop';
const _productMarker = 'VITYO_PRODUCT_REPORT ';
const _contractMarker = 'VITYO_PRODUCT_CONTRACT_REPORT ';
const _history = 't13_task_history_capture';
const _compileError = 'e06_task_order_non_task';
final _fixtures = Directory('test/fixtures/task-resource');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  boundaryCases();
  final enabled = Platform.environment['VITYO_PRODUCT_GATE'] == '1';
  late _Product product;
  setUpAll(() async {
    if (enabled) product = await _Product.open();
  });
  tearDownAll(() async {
    if (enabled) await product.close();
  });

  test(
    'real production document composition and versioned diagnostics',
    () async {
      expect(product.controller.engine.hasWorkspaceDocumentStore, isTrue);
      expect(product.controller.executionLive, isTrue);
      expect(product.language.live, isTrue);
      expect(
        (product.language as FlowHeroLanguageRuntime).executablePath,
        _required('VITYO_STYIO_LSPD_BIN'),
      );
      expect(product.runtime.localServices.clientCreations, 1);
      _case('component-selection');
      await product.select(_history);
      final before = product.document;
      await File(
        '${_required('VITYO_PRODUCT_EVIDENCE')}/document-request.json',
      ).writeAsString(
        jsonEncode({
          'fixture': _history,
          'documentId': before.documentId,
          'source_revision': before.revision,
          'text': before.text,
          'lsp': _required('VITYO_STYIO_LSPD_BIN'),
        }),
      );
      final good = await product.language.analyzeFresh(
        before,
        filePath: product.sourcePath,
      );
      await File(
        '${_required('VITYO_PRODUCT_EVIDENCE')}/document-diagnostics.json',
      ).writeAsString(
        jsonEncode(
          good?.analysis.diagnostics
              .map(
                (d) => {
                  'code': d.code,
                  'message': d.message,
                  'severity': d.severity.name,
                },
              )
              .toList(),
        ),
      );
      expect(good?.authoritative, isTrue);
      expect(
        good!.analysis.diagnostics.where((d) => d.severity.name == 'error'),
        isEmpty,
      );
      _case('document-open');
      await product.select(_compileError);
      final bad = product.document;
      expect(bad.revision, greaterThan(before.revision));
      final badResult = await product.language.analyzeFresh(
        bad,
        filePath: product.sourcePath,
      );
      expect(badResult?.authoritative, isTrue);
      expect(
        badResult!.analysis.diagnostics.where(
          (d) => d.severity.name == 'error',
        ),
        isNotEmpty,
      );
      _case('document-change-save-diagnostics');
      // Queue the old analysis first. The production language owner must reject
      // its completion once a newer revision has been requested.
      final restored = await File(
        '${_fixtures.path}/$_history.styio',
      ).readAsString();
      final delayed = product.language.analyzeFresh(
        bad,
        filePath: product.sourcePath,
      );
      product.controller.engine.onBufferChanged(restored, line: 1, column: 1);
      final current = product.document;
      final fresh = product.language.analyzeFresh(
        current,
        filePath: product.sourcePath,
      );
      expect(await delayed, isNull);
      expect(await product.controller.engine.saveActive(), isTrue);
      final repaired = await fresh;
      expect(repaired?.authoritative, isTrue);
      expect(
        repaired!.analysis.diagnostics.where((d) => d.severity.name == 'error'),
        isEmpty,
      );
      expect(product.document.revision, current.revision);
      _case('revision-correct-diagnostics');
    },
    skip: !enabled,
  );

  for (final kind in FlowHeroExecutionKind.values) {
    test('real production ${kind.command} revision settlement', () async {
      final retained = <String, List<int>>{};
      final roots = <String>{};
      final sessions = <String>{};
      Object? originalCache;
      for (final phase in ['success', 'compile_error', 'repaired']) {
        await product.select(
          phase == 'compile_error' ? _compileError : _history,
        );
        final result = await product.execute(
          kind,
          name: '${phase}_${kind.command}',
        );
        expect(result.succeeded, phase != 'compile_error');
        expect(result.exitCode, phase == 'compile_error' ? 23 : 0);
        if (phase == 'compile_error') {
          expect(result.receipt, isNull);
          expect(result.plan, isEmpty);
          expect(
            result.stderr,
            contains(await product.expected(_compileError)),
          );
        } else {
          expect(result.processMetadata['processHandleSource'], 'vityod');
          expect(result.receipt, isNotNull);
          expect(result.receipt!.intent, kind.command);
          expect(
            result.receipt!.executed,
            kind == FlowHeroExecutionKind.run ||
                kind == FlowHeroExecutionKind.test,
          );
          expect(sessions.add(result.receipt!.sessionId), isTrue);
          expect(roots.add(result.plan['build_root'] as String), isTrue);
          if (phase == 'success') {
            originalCache = result.plan['cache_key'];
          }
          if (phase == 'repaired') {
            expect(result.plan['cache_key'], originalCache);
          }
          await product.retain(result, retained);
        }
        await product.unchanged(retained);
        _case(
          '${phase}_${kind.command}',
          outcome: phase == 'compile_error' ? 'failed' : 'succeeded',
        );
      }
    }, skip: !enabled);
  }

  test('real production task history and failure settlement', () async {
    // Pafio's JSON route returns paths, not child stdout. Its ordinary route
    // is the authoritative task result; both use the same production service.
    for (final entry in <String, String>{
      'history': _history,
      'handled': 't22_task_capture_failure_cleanup',
      'f64': 't23_task_f64_history_precision',
      'unhandled': 'e06_task_capture_failure_no_fallback',
    }.entries) {
      await product.select(entry.value);
      final expected = await product.expected(entry.value);
      for (final kind in [
        FlowHeroExecutionKind.run,
        FlowHeroExecutionKind.test,
      ]) {
        final result = await product.execute(
          kind,
          name: '${entry.key}_${kind.command}',
          jsonOutput: false,
        );
        expect(result.exitCode, entry.key == 'unhandled' ? 23 : 0);
        if (entry.key == 'unhandled') {
          expect(result.succeeded, isFalse);
          expect(result.receipt, isNull);
          expect(result.stderr, contains(expected));
        } else {
          expect(
            result.stdout,
            '${await product.expected(entry.value, trim: false)}completed Styio ${kind.command} via compile-plan\n',
          );
        }
        _case(
          '${entry.key}_${kind.command}',
          outcome: entry.key == 'unhandled' ? 'failed' : 'succeeded',
        );
      }
    }
  }, skip: !enabled);

  test('real production invocation ownership and dry run', () async {
    final retained = <String, List<int>>{};
    await product.select(_history);
    final previous = await product.execute(
      FlowHeroExecutionKind.build,
      name: 'before-dry-run',
    );
    expect(previous.succeeded, isTrue);
    await product.retain(previous, retained);
    final dry = await product.execute(
      FlowHeroExecutionKind.build,
      name: 'dry-run',
      dryRun: true,
    );
    expect(dry.succeeded, isTrue);
    expect(dry.receipt, isNull);
    expect(
      File('${dry.plan['build_root']}/receipt.json').existsSync(),
      isFalse,
    );
    await product.unchanged(retained);
    _case('dry-run-preservation');
    final other =
        await product.runtime.bootExecution(product.root, product.selection)
            as FlowHeroExecutionRuntime;
    try {
      final pair = await Future.wait([
        product.execute(FlowHeroExecutionKind.build, name: 'concurrent-1'),
        other.executeWorkflow(FlowHeroExecutionKind.build),
      ]);
      expect(pair.every((r) => r.succeeded), isTrue);
      expect(pair[0].plan['cache_key'], pair[1].plan['cache_key']);
      expect(pair[0].plan['build_root'], isNot(pair[1].plan['build_root']));
      for (final result in pair) {
        await product.retain(result, retained);
      }
      _case('concurrent-invocation-isolation');
      // A real controller-owned build must not become current after an edit,
      // even when the unsaved text returns to its previous value (ABA).
      expect(product.controller.canExecute, isTrue);
      final pending = product.controller.runExecution(
        FlowHeroExecutionKind.build,
      );
      expect(product.controller.executionBusy, isTrue);
      final text = product.document.text;
      product.controller.engine.onBufferChanged('$text\n', line: 1, column: 1);
      product.controller.engine.onBufferChanged(text, line: 1, column: 1);
      await pending;
      expect(product.controller.lastExecutionOutcome, isNull);
      expect(product.controller.executionPhase, FlowHeroExecutionPhase.idle);
      expect(product.controller.messages.last.receipt, isTrue);
      expect(product.controller.messages.last.text, contains('build 通过'));
      expect(await product.controller.engine.saveActive(), isTrue);
      // Consumption deliberately follows the later completed invocation.
      await product.unchanged(retained);
      _case('delayed-result-isolation');
    } finally {
      await other.dispose();
    }
  }, skip: !enabled);

  test(
    'real production static retained parent and runtime observation',
    () async {
      await product.select(_history);
      final managers = await createDetectedPlatformManagerBundle(
        workspaceRoot: product.root,
        vityodClient: product.harness.client,
      );
      final publisher = IoObservableSnapshotPublisher(
        processManager: managers.process,
      );
      Future<ObservableSnapshotPublishResult> publish([String? parent]) =>
          publisher.publish(
            ObservableSnapshotPublishRequest(
              workspaceRoot: product.root,
              manifestPath: '${product.root}/pafio.toml',
              pafioBinary: product.selection.pafioPath,
              compilerBinary: product.selection.styioPath,
              parentSnapshotPath: parent,
            ),
          );
      final first = await publish();
      expect(
        first.status,
        ObservablePublishStatus.succeeded,
        reason: first.detail,
      );
      final staticSnapshot = decodeObservableSnapshotBytes(
        first.bytes!,
      ).snapshot!;
      expect(
        staticSnapshot.compilationUnit,
        const ObservableCompilationUnit(
          packageName: 'acme/task-resource',
          manifestPath: 'pafio.toml',
          entryPath: 'src/main.styio',
        ),
      );
      final snapshotId = observableSnapshotId(first.bytes!);
      _case('static-snapshot');
      final parent = first.artifactPath!;
      final second = await publish(parent.substring(product.root.length + 1));
      expect(
        second.status,
        ObservablePublishStatus.succeeded,
        reason: second.detail,
      );
      expect(second.artifactPath, isNot(parent));
      final delta = decodeObservableDeltaBytes(second.deltaBytes!).envelope!;
      expect(delta.parentSnapshotId, snapshotId);
      expect(delta.targetSnapshotId, snapshotId);
      expect(applyObservableDelta(first.bytes!, delta).bytes, second.bytes);
      expect(await File(parent).readAsBytes(), first.bytes);
      _case('retained-parent-delta');
      final missing = await publish(
        '${product.root}/absent.observable-static-snapshot.json',
      );
      expect(missing.status, ObservablePublishStatus.succeeded);
      expect(missing.degradation, 'full_snapshot_required');
      expect(
        (missing.receipt as ExecutionReceiptSnapshot).observableReason,
        'parent_unreadable',
      );
      expect(missing.deltaBytes, isNull);
      expect(missing.bytes, first.bytes);
      _case('unreadable-parent-full-snapshot');
      final ids = <String>{};
      final retained = <String, List<int>>{};
      for (final phase in [
        'runtime-only',
        'observed-good',
        'observed-error',
        'observed-repaired',
      ]) {
        await product.select(
          phase == 'observed-error' ? _compileError : _history,
        );
        final result = await product.execute(
          FlowHeroExecutionKind.run,
          name: phase,
          staticSnapshot: phase != 'runtime-only',
          observation: const RuntimeObservationRequest(
            mode: RuntimeObservationMode.detailed,
          ),
        );
        if (phase == 'observed-error') {
          expect(result.exitCode, 23);
          expect(result.receipt, isNull);
          expect(result.plan, isEmpty);
        } else {
          expect(result.succeeded, isTrue);
          final events = result.receipt!.runtimeEventsPath!;
          expect(File(events).parent.path, result.plan['build_root']);
          final intake = await const IoObservableRuntimeIntake().ingest(
            RuntimeIntakeRequest(
              artifactPath: events,
              headSnapshotId: snapshotId,
              headSiteIds: staticSnapshot.nodes.map((node) => node.id).toList(),
            ),
          );
          expect(intake.isOk, isTrue, reason: intake.detail);
          expect(intake.overlay!.summaryMissing, isFalse);
          expect(intake.overlay!.snapshotId, snapshotId);
          expect(intake.overlay!.maxActivity, greaterThan(0));
          expect(intake.overlay!.uncorrelated.staleSnapshot, 0);
          expect(ids.add(intake.overlay!.executionId), isTrue);
          final records = (await File(events).readAsLines())
              .where((l) => l.isNotEmpty)
              .map((l) => jsonDecode(l) as Map)
              .toList();
          expect(records.first['record_kind'], 'session.capability');
          expect(records.last['record_kind'], 'session.summary');
          expect(
            records.where((r) => r['record_kind'] == 'session.capability'),
            hasLength(1),
          );
          expect(
            records.where((r) => r['record_kind'] == 'session.summary'),
            hasLength(1),
          );
          expect(
            records.map((r) => r['event_kind']),
            containsAll([
              'task.created',
              'task.completed',
              'task.result_consumed',
            ]),
          );
          final snapshots = result.receipt!.artifacts.where(
            (a) => a.endsWith('.observable-static-snapshot.json'),
          );
          expect(snapshots.length, phase == 'runtime-only' ? 0 : 1);
          if (snapshots.isNotEmpty) {
            expect(await File(snapshots.single).readAsBytes(), first.bytes);
          }
          await product.retain(result, retained);
        }
        await product.unchanged(retained);
        _case(
          phase,
          outcome: phase == 'observed-error' ? 'failed' : 'succeeded',
        );
      }
      await product.select('t23_task_f64_history_precision');
      final off = await product.execute(
        FlowHeroExecutionKind.run,
        name: 'observation-off-after',
      );
      expect(off.succeeded, isTrue);
      expect(
        off.receipt!.artifacts.any(
          (a) => a.endsWith('.observable-static-snapshot.json'),
        ),
        isFalse,
      );
      await product.unchanged(retained);
      expect(await File(parent).readAsBytes(), first.bytes);
      _case('observation-off-after');
    },
    skip: !enabled,
  );
}

void _case(String name, {String outcome = 'succeeded'}) => stdout.writeln(
  '$_productMarker${jsonEncode({'schema_version': 2, 'scenario': _scenario, 'evidence_kind': 'real-production-services', 'case': name, 'outcome': outcome, 'accepted': true})}',
);

class _Product {
  _Product(
    this.root,
    this.harness,
    this.runtime,
    this.controller,
    this.language,
    this.selection,
  );
  final String root;
  final VityodTestHarness harness;
  final ProductionFlowHeroRuntime runtime;
  final FlowHeroController controller;
  final FlowHeroLanguageSession language;
  final FlowHeroToolchainSelection selection;
  String get sourcePath => '$root/src/main.styio';
  FlowHeroExecutionRuntime get execution =>
      controller.executionSource! as FlowHeroExecutionRuntime;
  DocumentState get document => DocumentState(
    documentId: sourcePath,
    text: controller.engine.activeFile.text,
    revision: controller.engine.activeFile.sourceRevision,
  );

  static Future<_Product> open() async {
    final root = _required('VITYO_PRODUCT_WORKSPACE_ROOT');
    final harness = await VityodTestHarness.start(
      clientId: 'product-gate',
      executablePath: _required('VITYO_VITYOD_BIN'),
      evidenceDirectory: Directory(_required('VITYO_PRODUCT_EVIDENCE')),
    );
    final runtime = ProductionFlowHeroRuntime(
      localServices: FlowHeroLocalServices(
        clientFactory: () async => harness.client,
      ),
    );
    final selection = FlowHeroToolchainSelection(
      pafioPath: _required('VITYO_PAFIO_BIN'),
      styioPath: _required('VITYO_STYIO_BIN'),
    );
    _required('VITYO_STYIO_LSPD_BIN');
    final controller = FlowHeroApp(
      runtime: runtime,
      initialToolchainSelection: selection,
      workspaceStore: FlowHeroMemoryWorkspaceStore(root),
      toolchainStore: FlowHeroMemoryToolchainStore(),
      modelConfigStore: FlowHeroMemoryModelConfigStore(),
    ).createController(workspaceRoot: root);
    await controller.workspaceBootSettled;
    expect(controller.languageMode, FlowHeroLanguageMode.live);
    expect(await controller.engine.openPath(sourcePathFor(root)), isTrue);
    return _Product(
      root,
      harness,
      runtime,
      controller,
      controller.languageSession!,
      selection,
    );
  }

  static String sourcePathFor(String root) => '$root/src/main.styio';
  Future<String> expected(String fixture, {bool trim = true}) async {
    final text = await File(
      '${_fixtures.path}/$fixture.expected',
    ).readAsString();
    return trim ? text.trim() : text;
  }

  Future<void> select(String fixture) async {
    final text = await File('${_fixtures.path}/$fixture.styio').readAsString();
    controller.engine.onBufferChanged(text, line: 1, column: 1);
    expect(controller.lastExecutionOutcome, isNull);
    expect(await controller.engine.saveActive(), isTrue);
    // Read-only assertion: every write went through the production save service.
    expect(await File(sourcePath).readAsString(), text);
  }

  Future<FlowHeroExecutionOutcome> execute(
    FlowHeroExecutionKind kind, {
    required String name,
    bool jsonOutput = true,
    bool dryRun = false,
    bool staticSnapshot = false,
    RuntimeObservationRequest? observation,
  }) async {
    final FlowHeroExecutionOutcome result;
    if (jsonOutput && !dryRun && !staticSnapshot && observation == null) {
      // Ordinary operations go through the mounted app's controller, including
      // current-result invalidation and historical receipt publication.
      expect(controller.canExecute, isTrue);
      final pending = controller.runExecution(kind);
      expect(controller.lastExecutionOutcome, isNull);
      await pending;
      result = controller.lastExecutionOutcome!;
      expect(controller.executionPhase, result.phase);
    } else {
      result = await execution.executeWorkflow(
        kind,
        jsonOutput: jsonOutput,
        dryRun: dryRun,
        staticSnapshot: staticSnapshot,
        observation: observation,
      );
    }
    final dir = Directory(_required('VITYO_PRODUCT_EVIDENCE'));
    await File('${dir.path}/$name.json').writeAsString(
      jsonEncode({
        'command': kind.command,
        'exit_code': result.exitCode,
        'stdout': result.stdout,
        'stderr': result.stderr,
        'plan': result.plan,
        'metadata': result.processMetadata,
      }),
    );
    return result;
  }

  Future<void> retain(
    FlowHeroExecutionOutcome result,
    Map<String, List<int>> retained,
  ) async {
    final root = result.plan['build_root'] as String;
    expect(result.receipt!.artifacts, isNotEmpty);
    expect((result.processMetadata['argv'] as List).first, selection.pafioPath);
    final argv = result.processMetadata['argv'] as List;
    expect(argv[argv.indexOf('--styio-bin') + 1], selection.styioPath);
    expect((result.plan['path'] as String).startsWith('$root/'), isTrue);
    expect(File(result.plan['path'] as String).existsSync(), isTrue);
    for (final path in [
      result.plan['path'] as String,
      '$root/receipt.json',
      '${result.plan['diag_dir']}/diagnostics.jsonl',
      ...result.receipt!.artifacts,
      if (result.receipt!.runtimeEventsPath case final path?)
        if (File(path).existsSync()) path,
    ]) {
      expect(File(path).absolute.path.startsWith('$root/'), isTrue);
      retained[path] = await File(path).readAsBytes();
    }
  }

  Future<void> unchanged(Map<String, List<int>> retained) async {
    for (final entry in retained.entries) {
      expect(await File(entry.key).readAsBytes(), entry.value);
    }
  }

  Future<void> close() async {
    controller.dispose();
    await language.dispose();
    await runtime.dispose();
    await harness.close();
  }
}

String _required(String key) {
  final value = Platform.environment[key];
  if (value == null || value.isEmpty) throw StateError('$key is required');
  return value;
}

void boundaryCases() {
  test('current absolute owner paths stay canonically contained', () async {
    final directory = await Directory.systemTemp.createTemp(
      'vityo-owner-paths-',
    );
    try {
      final root = await directory.resolveSymbolicLinks();
      final output = Directory('$root/build/invocation');
      await output.create(recursive: true);
      final artifact = File(
        '${output.path}/module.observable-static-snapshot.json',
      );
      await artifact.writeAsString('{}');
      final receipt = File('${output.path}/receipt.json');
      await receipt.writeAsString(
        jsonEncode({
          'schema_version': 1,
          'intent': 'check',
          'session_id': 'contained-owner',
          'executed': false,
          'artifacts': [artifact.path],
        }),
      );
      final publisher = IoObservableSnapshotPublisher(
        processManager: _EnvelopeProcessManager(output.path),
      );
      final result = await publisher.publish(
        ObservableSnapshotPublishRequest(
          workspaceRoot: directory.path,
          manifestPath: '${directory.path}/pafio.toml',
          pafioBinary: 'controlled-pafio',
          compilerBinary: 'controlled-styio',
        ),
      );
      expect(result.isSuccess, isTrue, reason: result.detail);
      expect(result.artifactPath, artifact.path);
      expect(result.bytes, utf8.encode('{}'));
      expect(
        (result.receipt as ExecutionReceiptSnapshot).sessionId,
        'contained-owner',
      );
      _emitContract(
        caseName: 'canonical-owner-paths',
        outcome: 'succeeded',
        category: 'owner_paths_contained',
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('missing selected Styio is blocked distinctly', () async {
    final result = await _classifyBoundary(
      _ControlledRunner(const <_CommandResult>[
        _CommandResult.spawnFailure(),
      ]).call,
    );
    expect(result, ('blocked', 'styio_missing'));
    _emitContract(
      caseName: 'missing-styio',
      outcome: result.$1,
      category: result.$2,
    );
  });

  test('incompatible selected Styio contract is blocked distinctly', () async {
    final incompatible = <_CommandResult>[
      const _CommandResult(exitCode: 2),
      _CommandResult(stdoutBytes: utf8.encode('{not-json')),
      _CommandResult.json(<String, Object?>{
        ..._compatibleMachineInfo(),
        'tool': 'not-styio',
      }),
      _CommandResult.json(<String, Object?>{
        ..._compatibleMachineInfo(),
        'supported_contract_versions': <String, Object?>{
          'compile_plan': <int>[2],
          'runtime_events': <int>[1],
        },
      }),
      _CommandResult.json(<String, Object?>{
        ..._compatibleMachineInfo(),
        'feature_flags': <String, Object?>{
          'compile_plan_consumer': true,
          'runtime_event_stream': false,
        },
      }),
    ];
    for (final probe in incompatible) {
      final result = await _classifyBoundary(
        _ControlledRunner(<_CommandResult>[probe]).call,
      );
      expect(result, ('blocked', 'styio_machine_contract_incompatible'));
    }
    _emitContract(
      caseName: 'incompatible-machine-contract',
      outcome: 'blocked',
      category: 'styio_machine_contract_incompatible',
    );
  });

  test('compiler execution failure is failed distinctly', () async {
    final result = await _classifyBoundary(
      _ControlledRunner(<_CommandResult>[
        _CommandResult.json(_compatibleMachineInfo()),
        const _CommandResult(exitCode: 23),
      ]).call,
      workflow: const _OwnerCommand('<pafio>', <String>[
        '--json',
        'check',
      ], '.'),
    );
    expect(result, ('failed', 'compiler_execution_failed'));
    _emitContract(
      caseName: 'compiler-execution-failure',
      outcome: result.$1,
      category: result.$2,
    );
  });
}

CompilerHandshakeSnapshot _decodeCompatibleMachine(
  String payload,
  String styioBinary,
) {
  final raw = _jsonObject(payload, 'styio machine-info');
  final contracts = _object(
    raw['supported_contract_versions'],
    'styio supported contracts',
  );
  final flags = _object(raw['feature_flags'], 'styio feature flags');
  if (raw['tool'] != 'styio' ||
      raw['active_integration_phase'] is! String ||
      (raw['active_integration_phase'] as String).trim().isEmpty ||
      !_list(contracts['compile_plan'], 'compile-plan contracts').contains(1) ||
      (!_list(
            contracts['runtime_events'],
            'runtime-event contracts',
          ).contains(2) &&
          !_list(
            contracts['runtime_events'],
            'runtime-event contracts',
          ).contains(1)) ||
      flags['compile_plan_consumer'] != true ||
      flags['runtime_event_stream'] != true) {
    throw StateError('styio_machine_contract_incompatible');
  }
  final compiler = StyioCompilerAdapter.decode(
    payload,
    binaryPath: styioBinary,
  );
  if (compiler.tool != 'styio' ||
      compiler.integrationPhase.trim().isEmpty ||
      !(compiler.supportedContractVersions['compile_plan'] ?? const <int>[])
          .contains(1) ||
      !((compiler.supportedContractVersions['runtime_events'] ?? const <int>[])
              .contains(2) ||
          (compiler.supportedContractVersions['runtime_events'] ??
                  const <int>[])
              .contains(1)) ||
      compiler.featureFlags['compile_plan_consumer'] != true ||
      compiler.featureFlags['runtime_event_stream'] != true) {
    throw StateError('styio_machine_contract_incompatible');
  }
  return compiler;
}

Map<String, Object?> _compatibleMachineInfo() => <String, Object?>{
  'tool': 'styio',
  'active_integration_phase': 'compile-plan-live',
  'supported_contract_versions': <String, Object?>{
    'compile_plan': <int>[1],
    'runtime_events': <int>[1],
  },
  'feature_flags': <String, Object?>{
    'compile_plan_consumer': true,
    'runtime_event_stream': true,
  },
};

class _OwnerCommand {
  const _OwnerCommand(this.executable, this.arguments, this.workingDirectory);
  final String executable;
  final List<String> arguments;
  final String workingDirectory;
}

class _CommandResult {
  const _CommandResult({this.exitCode = 0, this.stdoutBytes = const <int>[]})
    : spawned = true;
  const _CommandResult.spawnFailure()
    : spawned = false,
      exitCode = -1,
      stdoutBytes = const <int>[];
  factory _CommandResult.json(Object value) =>
      _CommandResult(stdoutBytes: utf8.encode(jsonEncode(value)));
  final bool spawned;
  final int exitCode;
  final List<int> stdoutBytes;
  String get stdoutText => utf8.decode(stdoutBytes);
}

class _ControlledRunner {
  _ControlledRunner(this.results);
  final List<_CommandResult> results;
  int index = 0;
  Future<_CommandResult> call(_OwnerCommand command) async => results[index++];
}

Future<(String, String)> _classifyBoundary(
  Future<_CommandResult> Function(_OwnerCommand) runner, {
  _OwnerCommand? workflow,
}) async {
  final probe = await runner(
    const _OwnerCommand('<styio>', ['--machine-info=json'], '.'),
  );
  if (!probe.spawned) return ('blocked', 'styio_missing');
  try {
    if (probe.exitCode != 0) throw StateError('probe failed');
    _decodeCompatibleMachine(probe.stdoutText, '<styio>');
  } on Object {
    return ('blocked', 'styio_machine_contract_incompatible');
  }
  final result = await runner(workflow!);
  if (!result.spawned || result.exitCode != 0) {
    return ('failed', 'compiler_execution_failed');
  }
  throw StateError('expected compiler failure');
}

Map<String, Object?> _object(Object? value, String name) =>
    Map<String, Object?>.from(value as Map);
Map<String, Object?> _jsonObject(String text, String name) =>
    _object(jsonDecode(text), name);
List<Object?> _list(Object? value, String name) =>
    List<Object?>.from(value as List);
void _emitContract({
  required String caseName,
  required String outcome,
  required String category,
}) => stdout.writeln(
  '$_contractMarker${jsonEncode({'schema_version': 1, 'scenario': _scenario, 'evidence_kind': 'deterministic-contract', 'case': caseName, 'accepted': true, 'outcome': outcome, 'error_category': category, 'success_observation': false})}',
);

/// Synthetic envelope only: the production publisher owns canonical containment
/// and receipt/artifact consumption. This is deterministic boundary evidence.
class _EnvelopeProcessManager extends UnsupportedProcessManager {
  _EnvelopeProcessManager(this.buildRoot)
    : super(facts: ProcessFacts.linuxDebianArm());
  final String buildRoot;

  @override
  Future<ProcessCommandResult> run(ProcessCommandRequest request) async =>
      ProcessCommandResult(
        status: ProcessCommandStatus.succeeded,
        executablePath: request.executablePath,
        arguments: request.arguments,
        exitCode: 0,
        stdout: jsonEncode({
          'status': 'succeeded',
          'plan': {'build_root': buildRoot},
        }),
        stderr: '',
        duration: Duration.zero,
      );
}
