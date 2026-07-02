import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:styio_view_app/src/backend_toolchain/dependency_source_adapter.dart';
import 'package:styio_view_app/src/backend_toolchain/project_graph_contract.dart';
import 'package:styio_view_app/src/platform/platform_target.dart';

void main() {
  test('dependency source adapter executes published pafio fetch', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'styio_view_dependency_source_test_',
    );
    addTearDown(() => tempRoot.delete(recursive: true));

    File('${tempRoot.path}${Platform.pathSeparator}pafio.toml')
      ..createSync(recursive: true)
      ..writeAsStringSync('[package]\nname = "demo/app"\nversion = "0.1.0"\n');
    final pafioBinary = File(
      '${tempRoot.path}${Platform.pathSeparator}.pafio${Platform.pathSeparator}bin${Platform.pathSeparator}pafio',
    );
    pafioBinary.createSync(recursive: true);
    pafioBinary.writeAsStringSync('''#!/usr/bin/env python3
import json, sys

if sys.argv[1:] == ['--json', 'fetch', '--manifest-path', '${tempRoot.path}${Platform.pathSeparator}pafio.toml', '--locked', '--offline']:
    print(json.dumps({
        'command': 'fetch',
        'message': 'materialized dependency sources under local pafio cache',
        'packages': 3,
        'git_packages': 1,
        'registry_packages': 1,
        'locked': True,
        'offline': True,
    }))
    raise SystemExit(0)

raise SystemExit(64)
''');
    Process.runSync('chmod', <String>['+x', pafioBinary.path]);

    final adapter = await createDependencySourceAdapter(
      platformTarget: PlatformTarget.macos,
    );
    final result = await adapter.fetchDependencies(
      projectGraph: _projectGraphFor(tempRoot.path),
      locked: true,
      offline: true,
    );

    expect(result.succeeded, isTrue);
    expect(result.command, 'fetch');
    expect(result.payload?['packages'], 3);
    expect(result.payload?['offline'], isTrue);
  });

  test('dependency source adapter blocks vendor without manifest', () async {
    final adapter = await createDependencySourceAdapter(
      platformTarget: PlatformTarget.macos,
    );
    final result = await adapter.vendorDependencies(
      projectGraph: ProjectGraphSnapshot.scratch(
        workspaceRoot: '/workspace/scratch',
        activeFilePath: '/workspace/scratch/main.styio',
        title: 'Scratch',
        notes: const <String>[],
      ),
    );

    expect(result.status, DependencySourceCommandStatus.blocked);
    expect(result.statusMessage, contains('requires a resolved pafio manifest'));
  });
}

ProjectGraphSnapshot _projectGraphFor(String workspaceRoot) {
  final manifestPath = '$workspaceRoot${Platform.pathSeparator}pafio.toml';
  return ProjectGraphSnapshot(
    id: manifestPath,
    title: 'demo/app',
    kind: ProjectKind.package,
    workspaceRoot: workspaceRoot,
    workspaceMembers: const <String>[],
    manifestPath: manifestPath,
    packages: const <ProjectPackageSnapshot>[],
    dependencies: const <ProjectDependencySnapshot>[],
    targets: const <ProjectTargetDescriptor>[],
    editorFiles: <String>[
      '$workspaceRoot${Platform.pathSeparator}src${Platform.pathSeparator}main.styio',
    ],
    toolchain: const ToolchainStatusSnapshot(
      source: ToolchainResolutionSource.unavailable,
      detail: 'No toolchain resolved for this test fixture.',
    ),
    lockState: ProjectLockState.unknown,
    vendorState: ProjectVendorState.missing,
    notes: const <String>[],
  );
}
