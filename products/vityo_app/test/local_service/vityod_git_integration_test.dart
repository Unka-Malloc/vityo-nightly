import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/ide/local_service/vityod_source_control_command_runner.dart';
import 'package:vityo_app/src/ide/workspace/source_control_merge_editor.dart';
import 'package:vityo_app/src/ide/workspace/source_control_status.dart';
import 'package:vityo_app/src/ide/workspace/workspace_document_store_io.dart';

import '../support/vityod_test_harness.dart';

void main() {
  test('Git status, diff, and actions use typed vityod contracts', () async {
    final root = await Directory.systemTemp.createTemp('vityod-git-test-');
    final harness = await VityodTestHarness.start(clientId: 'git-test');
    addTearDown(() async {
      await harness.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    await _git(root, const <String>['init']);
    await _git(root, const <String>['config', 'user.name', 'Vityo Test']);
    await _git(root, const <String>[
      'config',
      'user.email',
      'vityo-test@example.invalid',
    ]);
    final source = File('${root.path}${Platform.pathSeparator}main.styio');
    await source.writeAsString('before\n');
    await _git(root, const <String>['add', '--', 'main.styio']);
    await _git(root, const <String>['commit', '-m', 'initial']);
    await source.writeAsString('after\n');

    final opened = await harness.client.request(
      method: 'workspace.open',
      idempotencyKey: 'git-workspace-open',
      workspaceId: 'git-workspace',
      params: <String, Object?>{'rootPath': root.path},
    );
    expect(opened.method, 'workspace.open.result');
    final runner = VityodSourceControlCommandRunner(
      client: harness.client,
      workspaceId: 'git-workspace',
    ).call;
    final status = await GitPorcelainStatusProvider(
      runner: runner,
    ).status(workspaceRoot: root.path);
    expect(status.available, isTrue);
    expect(status.changes.single.path, 'main.styio');
    expect(
      status.changes.single.unstagedStatus,
      SourceControlFileStatus.modified,
    );

    final diff = await GitSourceControlDiffProvider(
      runner: runner,
    ).diff(workspaceRoot: root.path, path: 'main.styio');
    expect(diff.available, isTrue);
    expect(diff.unifiedDiff, contains('+after'));

    final action = await GitSourceControlActionProvider(runner: runner)
        .runAction(
          workspaceRoot: root.path,
          request: const SourceControlActionRequest(
            kind: SourceControlActionKind.stage,
            paths: <String>['main.styio'],
          ),
        );
    expect(action.applied, isTrue);
    final staged = await GitPorcelainStatusProvider(
      runner: runner,
    ).status(workspaceRoot: root.path);
    expect(
      staged.changes.single.stagedStatus,
      SourceControlFileStatus.modified,
    );
  });

  test(
    'Git merge editor resolves a real daemon-backed index conflict',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'vityod-git-merge-test-',
      );
      final harness = await VityodTestHarness.start(clientId: 'git-merge-test');
      addTearDown(() async {
        await harness.close();
        if (await root.exists()) await root.delete(recursive: true);
      });

      await _git(root, const <String>['init']);
      await _git(root, const <String>['config', 'user.name', 'Vityo Test']);
      await _git(root, const <String>[
        'config',
        'user.email',
        'vityo-test@example.invalid',
      ]);
      final source = File('${root.path}${Platform.pathSeparator}merge.styio');
      await source.writeAsString('base\n');
      await _git(root, const <String>['add', '--', 'merge.styio']);
      await _git(root, const <String>['commit', '-m', 'base']);
      await _git(root, const <String>['switch', '-c', 'incoming']);
      await source.writeAsString('incoming\n');
      await _git(root, const <String>['commit', '-am', 'incoming']);
      await _git(root, const <String>['switch', '-c', 'current', 'HEAD~1']);
      await source.writeAsString('current\n');
      await _git(root, const <String>['commit', '-am', 'current']);
      final merge = await Process.run('git', const <String>[
        'merge',
        'incoming',
      ], workingDirectory: root.path);
      expect(merge.exitCode, isNot(0));

      final openedWorkspace = await harness.client.request(
        method: 'workspace.open',
        idempotencyKey: 'git-merge-workspace-open',
        workspaceId: 'git-merge-workspace',
        params: <String, Object?>{'rootPath': root.path},
      );
      expect(openedWorkspace.method, 'workspace.open.result');
      final runner = VityodSourceControlCommandRunner(
        client: harness.client,
        workspaceId: 'git-merge-workspace',
      ).call;
      final documentStore = VityodWorkspaceDocumentStore(
        client: harness.client,
        workspaceId: 'git-merge-workspace',
        workspaceRoot: root.path,
      );
      final mergeProvider = GitSourceControlMergeProvider(
        runner: runner,
        documentStore: documentStore,
        workspaceRoot: root.path,
      );
      final statusProvider = GitPorcelainStatusProvider(runner: runner);
      final conflicted = await statusProvider.status(workspaceRoot: root.path);
      final workflow = SourceControlMergeWorkflowPlan.fromStatus(conflicted);
      final editor = await mergeProvider.openMergeEditor(
        workspaceRoot: root.path,
        path: 'merge.styio',
      );

      expect(workflow.conflictCount, 1);
      expect(editor.available, isTrue, reason: editor.message);
      expect(editor.baseText, 'base\n');
      expect(editor.currentText, 'current\n');
      expect(editor.incomingText, 'incoming\n');
      expect(editor.hasUnresolvedMarkers, isTrue);

      final request = SourceControlConflictResolutionRequest.fromPlan(
        workflowPlan: workflow,
        conflictPlan: workflow.conflictPlans.single,
        kind: SourceControlConflictResolutionKind.markResolved,
        resultText: 'current\nincoming\n',
        expectedWorkingRevision: editor.workingRevision,
      );
      final result = await mergeProvider.resolve(request);
      final resolved = await statusProvider.status(workspaceRoot: root.path);

      expect(result.accepted, isTrue);
      expect(resolved.changes.single.conflicted, isFalse);
      expect(resolved.changes.single.staged, isTrue);
      expect(await source.readAsString(), 'current\nincoming\n');
    },
  );
}

Future<void> _git(Directory root, List<String> arguments) async {
  final result = await Process.run(
    'git',
    arguments,
    workingDirectory: root.path,
  );
  if (result.exitCode != 0) {
    throw StateError('Git fixture command failed with ${result.exitCode}.');
  }
}
