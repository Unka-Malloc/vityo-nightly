/// Process and file-system operations behind Flow Hero's local-toolchain UI.
library;

import '../../ide/local_service/vityod_client.dart';
import '../environment/configuration/host_environment.dart';
import '../environment/system_compatibility/platform_manager/platform_manager.dart';
import '../environment/system_compatibility/process/process_manager.dart';
import 'toolchain_install_contract.dart';
import 'toolchain_store.dart';

/// Runs the actual verification used when a user selects a local binary.
Future<FlowHeroToolchainProbeResult> probeFlowHeroToolchainBinary({
  required FlowHeroToolchainKind kind,
  required String path,
  PlatformManagerBundle? platformManagers,
  VityodClient? vityodClient,
  Map<String, String>? environment,
  Duration? timeout,
}) async {
  final String trimmed = path.trim();
  if (trimmed.isEmpty) {
    return const FlowHeroToolchainProbeResult(
      ok: false,
      detail: '未填写二进制路径',
      failure: '未填写二进制路径',
    );
  }
  try {
    final managers =
        platformManagers ??
        await createDetectedPlatformManagerBundle(
          workspaceRoot: _directoryOf(trimmed),
          vityodClient: vityodClient,
        );
    final probe = await _runVersionProbe(
      managers.process,
      kind: kind,
      path: trimmed,
      environment: environment ?? readHostEnvironment(),
      timeout: timeout,
    );
    final String versionOutput = probe.result?.stdout.trim() ?? '';
    if (kind == FlowHeroToolchainKind.pafio) {
      if (probe.result?.succeeded ?? false) {
        return FlowHeroToolchainProbeResult(
          ok: true,
          detail: versionOutput.isEmpty ? 'pafio --version 通过' : versionOutput,
          versionOutput: versionOutput,
          exitCode: probe.result?.exitCode,
        );
      }
      final String failure = probe.failure.isNotEmpty
          ? probe.failure
          : '--version 退出码 ${probe.result?.exitCode ?? '?'}';
      return FlowHeroToolchainProbeResult(
        ok: false,
        detail: 'pafio 验证失败 · $failure',
        failure: failure,
        exitCode: probe.result?.exitCode,
      );
    }
    final bool executable = await _isExecutableFile(managers, trimmed);
    if (!executable) {
      return const FlowHeroToolchainProbeResult(
        ok: false,
        detail: '文件不存在或不可执行',
        failure: '文件不存在或不可执行',
      );
    }
    if (probe.result?.succeeded ?? false) {
      return FlowHeroToolchainProbeResult(
        ok: true,
        detail: versionOutput.isEmpty ? '可执行' : '可执行 · $versionOutput',
        versionOutput: versionOutput,
        exitCode: probe.result?.exitCode,
      );
    }
    return const FlowHeroToolchainProbeResult(
      ok: true,
      detail: '可执行 · 未返回 --version 输出',
    );
  } on Object catch (error) {
    final String message = '无法探测该二进制 · ${_sanitize('$error')}';
    return FlowHeroToolchainProbeResult(
      ok: false,
      detail: message,
      failure: message,
    );
  }
}

class _VersionProbe {
  const _VersionProbe({this.result, this.failure = ''});

  final ProcessCommandResult? result;
  final String failure;
}

Future<_VersionProbe> _runVersionProbe(
  ProcessManager process, {
  required FlowHeroToolchainKind kind,
  required String path,
  required Map<String, String> environment,
  required Duration? timeout,
}) async {
  try {
    final result = await process.run(
      ProcessCommandRequest(
        executablePath: path,
        arguments: const <String>['--version'],
        environment: environment,
        timeout: timeout,
        serviceKind: kind == FlowHeroToolchainKind.pafio
            ? ProcessServiceKind.pafio
            : ProcessServiceKind.styio,
      ),
    );
    return _VersionProbe(result: result);
  } on Object catch (error) {
    return _VersionProbe(failure: _sanitize('$error'));
  }
}

Future<bool> _isExecutableFile(
  PlatformManagerBundle managers,
  String path,
) async {
  try {
    if (!await managers.fileSystem.exists(path)) return false;
    return await managers.fileSystem.isExecutable(path);
  } on Object {
    return false;
  }
}

String _sanitize(String message) => message.replaceAllMapped(
  RegExp(r'(?:[A-Za-z]:[\\/]|/)\S*'),
  (_) => '<path>',
);

String? _directoryOf(String path) {
  final String normalized = path.replaceAll(r'\', '/');
  final int separator = normalized.lastIndexOf('/');
  if (separator <= 0) return null;
  return normalized.substring(0, separator);
}
