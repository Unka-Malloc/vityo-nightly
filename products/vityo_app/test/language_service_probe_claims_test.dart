import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/adapter_contracts.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/project_graph_contract.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/required_handoff_summary.dart';
import 'package:vityo_app/src/view_ide/platform/platform_target.dart';

/// The handoff/contract claims must follow the real route: a live LSP language
/// service retires them, and with no service they stay truthful.
void main() {
  test('a live language-service probe retires the mock-layer handoff', () {
    final handoffs = summarizeRequiredHandoffs(
      platformTarget: PlatformTarget.macos,
      projectGraph: _project(),
      adapterCapabilities: const <AdapterCapabilitySnapshot>[],
      languageServiceProbe: const StyioLanguageServiceProbe(
        realServiceAvailable: true,
        providerId: 'styio_lspd',
        version: '0.4.1',
      ),
    );

    expect(
      handoffs.map((handoff) => handoff.title),
      isNot(contains('Publish language-service machine contract')),
    );
    expect(
      handoffs.map((handoff) => handoff.title),
      contains('Publish compile-plan consumer and live execution contract'),
    );
  });

  test('without a probe the handoff still fires', () {
    final handoffs = summarizeRequiredHandoffs(
      platformTarget: PlatformTarget.macos,
      projectGraph: _project(),
      adapterCapabilities: const <AdapterCapabilitySnapshot>[],
      languageServiceProbe: const StyioLanguageServiceProbe.absent(),
    );

    expect(
      handoffs.map((handoff) => handoff.title),
      contains('Publish language-service machine contract'),
    );
  });

  test('the cloud contract line reflects the real local route', () {
    final unavailable = buildCloudAdapterCapability(
      supportsCloudExecution: false,
      supportsHostedProjectGraph: false,
      detail: 'cloud',
    );
    expect(unavailable.languageService.level, AdapterCapabilityLevel.partial);
    expect(unavailable.languageService.detail, contains('local mock layers'));

    final live = buildCloudAdapterCapability(
      supportsCloudExecution: false,
      supportsHostedProjectGraph: false,
      detail: 'cloud',
      languageServiceProbe: const StyioLanguageServiceProbe(
        realServiceAvailable: true,
        providerId: 'styio_lspd',
        version: '0.4.1',
      ),
    );
    expect(live.languageService.level, AdapterCapabilityLevel.available);
    expect(live.languageService.detail, contains('styio_lspd 0.4.1'));
    expect(live.languageService.detail, isNot(contains('mock layers')));
  });
}

ProjectGraphSnapshot _project() {
  return const ProjectGraphSnapshot(
    id: '/workspace/demo/pafio.toml',
    title: 'demo/app',
    kind: ProjectKind.package,
    workspaceRoot: '/workspace/demo',
    workspaceMembers: <String>[],
    manifestPath: '/workspace/demo/pafio.toml',
    packages: <ProjectPackageSnapshot>[],
    dependencies: <ProjectDependencySnapshot>[],
    targets: <ProjectTargetDescriptor>[],
    editorFiles: <String>[],
    toolchain: ToolchainStatusSnapshot(
      source: ToolchainResolutionSource.unavailable,
      detail: 'system Styio unavailable',
    ),
    lockState: ProjectLockState.unknown,
    vendorState: ProjectVendorState.unknown,
    notes: <String>[],
  );
}
