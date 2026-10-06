import 'toolchain_catalog.dart';
import 'toolchain_health_check.dart';
import 'toolchain_resolver.dart';

typedef ToolchainProjectPathProbe = Future<bool> Function(String path);
typedef ToolchainProjectHealthProbe =
    Future<ToolchainHealthReport> Function(
      ToolchainRequirement requirement,
      List<String> arguments,
      String workingDirectory,
    );

enum ToolchainProjectValidationStatus {
  ready,
  invalidProject,
  unresolved,
  executableMissing,
  executableNotRunnable,
  probeFailed,
  failed,
}

extension ToolchainProjectValidationStatusX
    on ToolchainProjectValidationStatus {
  String get wireValue => switch (this) {
    ToolchainProjectValidationStatus.ready => 'ready',
    ToolchainProjectValidationStatus.invalidProject => 'invalid-project',
    ToolchainProjectValidationStatus.unresolved => 'unresolved',
    ToolchainProjectValidationStatus.executableMissing => 'executable-missing',
    ToolchainProjectValidationStatus.executableNotRunnable =>
      'executable-not-runnable',
    ToolchainProjectValidationStatus.probeFailed => 'probe-failed',
    ToolchainProjectValidationStatus.failed => 'failed',
  };
}

class ToolchainProjectValidationRequest {
  const ToolchainProjectValidationRequest({
    required this.projectId,
    required this.workspaceRoot,
    required this.requirement,
    this.probeArguments,
  });

  final String projectId;
  final String workspaceRoot;
  final ToolchainRequirement requirement;
  final List<String>? probeArguments;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'projectId': projectId,
      'workspaceRoot': workspaceRoot,
      'requirement': requirement.toJson(),
      if (probeArguments != null) 'probeArguments': probeArguments,
    };
  }
}

class ToolchainProjectValidationResult {
  const ToolchainProjectValidationResult({
    required this.status,
    required this.request,
    required this.resolution,
    required this.message,
    this.health,
  });

  final ToolchainProjectValidationStatus status;
  final ToolchainProjectValidationRequest request;
  final ToolchainResolution resolution;
  final ToolchainHealthReport? health;
  final String message;

  bool get ready => status == ToolchainProjectValidationStatus.ready;

  ToolchainDescriptor? get descriptor => resolution.descriptor;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'status': status.wireValue,
      'ready': ready,
      'request': request.toJson(),
      'resolution': resolution.toJson(),
      if (health != null) 'health': health!.toJson(),
      'message': message,
    };
  }
}

/// Validates the project root and resolved executable before an IDE workflow
/// claims that a toolchain is usable. An optional process probe can be supplied
/// for toolchains with a safe, explicit health command.
class ToolchainProjectValidationRunner {
  const ToolchainProjectValidationRunner({
    required this.pathExists,
    required this.pathIsExecutable,
    this.healthProbe,
    this.resolver = const ToolchainResolver(),
  });

  final ToolchainProjectPathProbe pathExists;
  final ToolchainProjectPathProbe pathIsExecutable;
  final ToolchainProjectHealthProbe? healthProbe;
  final ToolchainResolver resolver;

  Future<ToolchainProjectValidationResult> validate({
    required ToolchainCatalog catalog,
    required ToolchainProjectValidationRequest request,
  }) async {
    final resolution = resolver.resolve(catalog, request.requirement);
    final projectId = request.projectId.trim();
    final workspaceRoot = request.workspaceRoot.trim();
    if (projectId.isEmpty || workspaceRoot.isEmpty) {
      return ToolchainProjectValidationResult(
        status: ToolchainProjectValidationStatus.invalidProject,
        request: request,
        resolution: resolution,
        message: 'Project identity and workspace root are required.',
      );
    }

    try {
      if (!resolution.resolved) {
        return ToolchainProjectValidationResult(
          status: ToolchainProjectValidationStatus.unresolved,
          request: request,
          resolution: resolution,
          message: resolution.message ?? 'No matching toolchain is registered.',
        );
      }
      if (!await pathExists(workspaceRoot)) {
        return ToolchainProjectValidationResult(
          status: ToolchainProjectValidationStatus.invalidProject,
          request: request,
          resolution: resolution,
          message: 'Workspace root is unavailable.',
        );
      }
      final executablePath = resolution.descriptor!.executablePath.trim();
      if (executablePath.isEmpty || !await pathExists(executablePath)) {
        return ToolchainProjectValidationResult(
          status: ToolchainProjectValidationStatus.executableMissing,
          request: request,
          resolution: resolution,
          message: 'Resolved toolchain executable is unavailable.',
        );
      }
      if (!await pathIsExecutable(executablePath)) {
        return ToolchainProjectValidationResult(
          status: ToolchainProjectValidationStatus.executableNotRunnable,
          request: request,
          resolution: resolution,
          message: 'Resolved toolchain path is not executable.',
        );
      }

      final probeArguments = request.probeArguments;
      final probe = healthProbe;
      if (probeArguments != null && probe != null) {
        final health = await probe(
          request.requirement,
          List<String>.unmodifiable(probeArguments),
          workspaceRoot,
        );
        if (!health.healthy) {
          return ToolchainProjectValidationResult(
            status: ToolchainProjectValidationStatus.probeFailed,
            request: request,
            resolution: resolution,
            health: health,
            message: health.message ?? 'Toolchain process probe failed.',
          );
        }
        return ToolchainProjectValidationResult(
          status: ToolchainProjectValidationStatus.ready,
          request: request,
          resolution: resolution,
          health: health,
          message: 'Project toolchain is ready.',
        );
      }

      return ToolchainProjectValidationResult(
        status: ToolchainProjectValidationStatus.ready,
        request: request,
        resolution: resolution,
        message: 'Project toolchain path is ready.',
      );
    } on Object catch (error) {
      return ToolchainProjectValidationResult(
        status: ToolchainProjectValidationStatus.failed,
        request: request,
        resolution: resolution,
        message: 'Project toolchain validation failed: $error',
      );
    }
  }
}
