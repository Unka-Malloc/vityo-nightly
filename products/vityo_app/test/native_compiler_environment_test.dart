import 'package:test/test.dart';
import 'package:vityo_app/src/view_ide/environment/configuration/host_environment.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/file_system/file_system_facts.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/file_system/file_system_manager.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/platform_context/platform_context_model.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/platform_manager/platform_manager.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/process/process_facts.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/process/process_manager.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/shell/shell_facts.dart';
import 'package:vityo_app/src/view_ide/toolchain/native_compiler_toolchain_discovery_io.dart';

void main() {
  tearDown(() => debugOverrideHostEnvironment(null));

  for (final environment in <Map<String, String>?>[
    null,
    const <String, String>{},
    const <String, String>{'PATH': ''},
  ]) {
    test(
      'native catalog preserves omitted versus explicit context $environment',
      () async {
        debugOverrideHostEnvironment(const <String, String>{
          'VITYO_CLANG_BIN': '/selected/clang',
          'VITYO_CLANGXX_BIN': '/selected/clang++',
          'PATH': '/fixture/host-bin',
          'TOKEN': 'synthetic-fixture',
        });
        final process = _Process();
        final catalog = await createPlatformNativeCompilerToolchainCatalog(
          platformManagers: _Managers(process),
          environment: environment,
          cCompilerCandidatePaths: const <String>['/fixture/clang'],
          cxxCompilerCandidatePaths: const <String>['/fixture/clang++'],
        );
        final compiler = catalog.lookup('native-clang-cpp-compiler');
        expect(
          compiler?.executablePath,
          environment == null ? '/selected/clang++' : '/fixture/clang++',
        );
        expect(compiler?.version, '18.1.8');
        expect(process.requests, isNotEmpty);
        expect(
          process.requests.any(
            (request) => request.arguments.contains('--version'),
          ),
          isTrue,
        );
        for (final request in process.requests) {
          expect(
            request.environment,
            environment == null
                ? <String, String>{'PATH': '/fixture/host-bin'}
                : <String, String>{},
          );
        }
      },
    );
  }
}

class _Managers implements PlatformManagerBundle {
  _Managers(this.process);
  @override
  final ProcessManager process;
  @override
  final FileSystemManager fileSystem = _FileSystem();
  @override
  final PlatformContextSnapshot context = PlatformContextSnapshot.compose(
    fileSystem: FileSystemFacts.linuxDebianArm(),
    shell: ShellFacts.linuxDebianArm(),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FileSystem implements FileSystemManager {
  @override
  Future<bool> exists(String path) async => <String>{
    '/selected/clang',
    '/selected/clang++',
    '/fixture/clang',
    '/fixture/clang++',
  }.contains(path);
  @override
  Future<bool> isExecutable(String path) => exists(path);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Process extends UnsupportedProcessManager {
  _Process() : super(facts: ProcessFacts.linuxDebianArm());
  final requests = <ProcessCommandRequest>[];
  @override
  Future<ProcessCommandResult> run(ProcessCommandRequest request) async {
    requests.add(request);
    final version = request.arguments.contains('--version');
    return ProcessCommandResult(
      status: version
          ? ProcessCommandStatus.succeeded
          : ProcessCommandStatus.failed,
      executablePath: request.executablePath,
      arguments: request.arguments,
      exitCode: version ? 0 : 1,
      stdout: version
          ? 'clang version 18.1.8\nTarget: x86_64-unknown-linux-gnu\n'
          : '',
      stderr: '',
      duration: Duration.zero,
    );
  }
}
