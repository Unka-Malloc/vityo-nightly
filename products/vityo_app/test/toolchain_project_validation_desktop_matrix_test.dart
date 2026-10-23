import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/toolchain/toolchain.dart';

void main() {
  test(
    'Linux and Windows project toolchain paths validate hermetically',
    () async {
      const cases = <({String projectRoot, String executable})>[
        (projectRoot: '/workspace/demo', executable: '/opt/tools/styio'),
        (
          projectRoot: r'C:\workspace\demo',
          executable: r'C:\Tools\Styio\styio.exe',
        ),
      ];

      for (final fixture in cases) {
        final catalog = ToolchainCatalog()
          ..register(
            ToolchainDescriptor(
              id: 'styio-${fixture.projectRoot}',
              kind: ToolchainKind.languageService,
              displayName: 'Styio Language Service',
              executablePath: fixture.executable,
            ),
            activate: true,
          );
        final existingPaths = <String>{fixture.projectRoot, fixture.executable};
        final checkedPaths = <String>[];
        final result =
            await ToolchainProjectValidationRunner(
              pathExists: (path) async {
                checkedPaths.add(path);
                return existingPaths.contains(path);
              },
              pathIsExecutable: (path) async => path == fixture.executable,
            ).validate(
              catalog: catalog,
              request: ToolchainProjectValidationRequest(
                projectId: 'demo',
                workspaceRoot: fixture.projectRoot,
                requirement: const ToolchainRequirement(
                  kind: ToolchainKind.languageService,
                ),
              ),
            );

        expect(result.ready, isTrue, reason: fixture.projectRoot);
        expect(result.status, ToolchainProjectValidationStatus.ready);
        expect(result.descriptor?.executablePath, fixture.executable);
        expect(checkedPaths, <String>[fixture.projectRoot, fixture.executable]);
        expect(result.toJson()['status'], 'ready');
      }
    },
  );

  test(
    'project validation distinguishes missing and non-runnable binaries',
    () async {
      final catalog = ToolchainCatalog()
        ..register(
          const ToolchainDescriptor(
            id: 'broken',
            kind: ToolchainKind.compiler,
            displayName: 'Broken compiler',
            executablePath: '/tools/broken',
          ),
          activate: true,
        );
      const request = ToolchainProjectValidationRequest(
        projectId: 'demo',
        workspaceRoot: '/workspace/demo',
        requirement: ToolchainRequirement(kind: ToolchainKind.compiler),
      );

      final missing = await ToolchainProjectValidationRunner(
        pathExists: (path) async => path == request.workspaceRoot,
        pathIsExecutable: (_) async => false,
      ).validate(catalog: catalog, request: request);
      final notRunnable = await ToolchainProjectValidationRunner(
        pathExists: (_) async => true,
        pathIsExecutable: (_) async => false,
      ).validate(catalog: catalog, request: request);

      expect(
        missing.status,
        ToolchainProjectValidationStatus.executableMissing,
      );
      expect(
        notRunnable.status,
        ToolchainProjectValidationStatus.executableNotRunnable,
      );
    },
  );

  test('ready bootstrap plans still dispatch project validation', () async {
    const plan = ToolchainBootstrapExecutionPlan(
      ready: true,
      steps: <ToolchainBootstrapActionStep>[
        ToolchainBootstrapActionStep(
          stepId: 'toolchain-bootstrap.validation',
          actionId: 'validate-project-toolchain',
          surface: ToolchainBootstrapActionSurface.project,
          required: true,
        ),
      ],
    );
    var validationRuns = 0;
    final result = await ToolchainBootstrapExecutionBridge(
      router: ToolchainBootstrapActionRouter(
        onProjectAction: (step) async {
          validationRuns += 1;
          return ToolchainBootstrapActionDispatchResult.dispatched(step);
        },
      ),
    ).execute(plan);

    expect(validationRuns, 1);
    expect(result.completed, isTrue);
    expect(result.blocked, isFalse);
  });
}
