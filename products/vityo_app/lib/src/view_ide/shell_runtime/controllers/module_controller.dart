import 'package:flutter/foundation.dart';

import '../../module_host/module_host.dart';
import '../../platform/platform.dart';

/// Owns module-host projections and refresh behavior.
final class ModuleController extends ChangeNotifier {
  ModuleController({
    required this.registry,
    required this.nativeModuleLoader,
    required this.platformTarget,
    required this.refreshProjectGraph,
    required this.log,
  }) {
    for (final module in registry.visibleModules) {
      _states[module.manifest.moduleId] = defaultModuleLifecycleState(module);
    }
  }

  final ModuleRegistry registry;
  final NativeModuleLoader nativeModuleLoader;
  final PlatformTarget platformTarget;
  final Future<void> Function(String reason) refreshProjectGraph;
  final void Function(String message) log;
  final Map<String, ModuleLifecycleState> _states =
      <String, ModuleLifecycleState>{};

  List<ModuleDefinition> get mountedModules => registry.mountedModules;
  List<ModuleDefinition> get visibleModules => registry.visibleModules;
  List<ModuleLifecycleState> get moduleStates => List.unmodifiable(
    visibleModules.map(
      (module) =>
          _states[module.manifest.moduleId] ??
          defaultModuleLifecycleState(module),
    ),
  );

  Future<void> enable(String moduleId) async {
    _updateState(
      moduleId,
      (state) => state.copyWith(
        enabled: true,
        message: 'Module enabled for this IDE session.',
      ),
    );
  }

  Future<void> disable(String moduleId) async {
    final module = registry.findById(moduleId);
    if (module?.manifest.kind == ModuleKind.core) {
      log('Core module $moduleId cannot be disabled.');
      return;
    }
    _updateState(
      moduleId,
      (state) => state.copyWith(
        enabled: false,
        message: 'Module disabled for this IDE session.',
      ),
    );
  }

  Future<void> trust(String moduleId) async {
    _updateState(
      moduleId,
      (state) => state.copyWith(
        trustState: ModuleTrustState.trusted,
        message: 'Module trust granted by the user.',
      ),
    );
  }

  void _updateState(
    String moduleId,
    ModuleLifecycleState Function(ModuleLifecycleState state) update,
  ) {
    final module = registry.findById(moduleId);
    if (module == null) {
      log('Module lifecycle action ignored: $moduleId is not registered.');
      return;
    }
    final current = _states[moduleId] ?? defaultModuleLifecycleState(module);
    final next = update(current);
    _states[moduleId] = next;
    log('${next.message} ($moduleId)');
    notifyListeners();
  }

  Future<void> refresh() async {
    log('Module host refresh requested on ${platformTarget.label}.');
    await refreshProjectGraph(
      'manual refresh requested from the shell command registry',
    );
    final bridge = await nativeModuleLoader.describe('local.runtime.desktop');
    log(
      'Native bridge ${bridge.moduleId}: ${bridge.state.name} '
      '(${bridge.detail})',
    );
    notifyListeners();
  }

  Future<Map<String, Object?>> agentRefreshMetadata() async {
    final bridge = await nativeModuleLoader.describe('local.runtime.desktop');
    return <String, Object?>{
      'visibleModuleCount': visibleModules.length,
      'mountedModuleCount': mountedModules.length,
      'visibleModuleIds': visibleModules
          .map((module) => module.manifest.moduleId)
          .toList(growable: false),
      'mountedModuleIds': mountedModules
          .map((module) => module.manifest.moduleId)
          .toList(growable: false),
      'nativeBridge': <String, Object?>{
        'moduleId': bridge.moduleId,
        'state': bridge.state.name,
        'detail': bridge.detail,
      },
    };
  }
}
