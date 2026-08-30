import '../clipboard/clipboard.dart';
import '../file_system/file_system.dart';
import '../local_service/local_service.dart';
import '../network/network.dart';
import '../notification/notification.dart';
import '../platform_adapter/platform_adapter.dart';
import '../platform_context/platform_context_model.dart';
import '../platform_detector/platform_detector.dart';
import '../process/process.dart';
import '../pty/pty.dart';
import '../resource/resource.dart';
import '../shell/shell.dart';
import '../../../../ide/local_service/vityod_client.dart';

enum PlatformManagerHealthProbeKind { factReadiness, managerLiveOperation }

class PlatformManagerBundle {
  const PlatformManagerBundle({
    required this.context,
    required this.compatibility,
    required this.fileSystem,
    required this.shell,
    required this.process,
    required this.resource,
    required this.network,
    required this.clipboard,
    required this.notification,
    required this.localService,
    required this.pty,
  });

  final PlatformContextSnapshot context;
  final PlatformCompatibilitySnapshot compatibility;
  final FileSystemManager fileSystem;
  final ShellManager shell;
  final ProcessManager process;
  final ResourceManager resource;
  final NetworkManager network;
  final ClipboardManager clipboard;
  final NotificationManager notification;
  final LocalServiceManager localService;
  final PtyManager pty;

  PlatformManagerBundleSnapshot snapshot() {
    return PlatformManagerBundleSnapshot(
      targetId: context.targetId,
      contextSource: context.source,
      schemaVersion: context.schemaVersion,
      supportsLinuxDebianArmTarget: compatibility.supportsLinuxDebianArmTarget,
      managerKeys: const <String>[
        'fileSystem',
        'shell',
        'process',
        'resource',
        'network',
        'clipboard',
        'notification',
        'localService',
        'pty',
      ],
    );
  }

  PlatformManagerHealthSnapshot healthSnapshot() {
    final components = <PlatformManagerComponentHealth>[
      PlatformManagerComponentHealth(
        managerKey: 'fileSystem',
        ready: _isSupportedCompatibilityTarget(
          context.fileSystem.compatibilityTarget,
        ),
        message: 'File system manager compatibility is available.',
      ),
      PlatformManagerComponentHealth(
        managerKey: 'shell',
        ready: _isSupportedCompatibilityTarget(
          context.shell.compatibilityTarget,
        ),
        message: 'Shell manager compatibility is available.',
      ),
      PlatformManagerComponentHealth(
        managerKey: 'process',
        ready: _isSupportedCompatibilityTarget(
          context.process.compatibilityTarget,
        ),
        message: 'Process manager compatibility is available.',
      ),
      PlatformManagerComponentHealth(
        managerKey: 'resource',
        ready: _isSupportedCompatibilityTarget(
          context.resource.compatibilityTarget,
        ),
        message: 'Resource manager compatibility is available.',
      ),
      PlatformManagerComponentHealth(
        managerKey: 'network',
        ready: _isSupportedCompatibilityTarget(
          context.network.compatibilityTarget,
        ),
        message: 'Network manager compatibility is available.',
      ),
      PlatformManagerComponentHealth(
        managerKey: 'clipboard',
        ready: _isSupportedCompatibilityTarget(
          context.clipboard.compatibilityTarget,
        ),
        message: 'Clipboard manager compatibility is available.',
      ),
      PlatformManagerComponentHealth(
        managerKey: 'notification',
        ready: _isSupportedCompatibilityTarget(
          context.notification.compatibilityTarget,
        ),
        message: 'Notification manager compatibility is available.',
      ),
      PlatformManagerComponentHealth(
        managerKey: 'localService',
        ready: _isSupportedCompatibilityTarget(
          context.localService.compatibilityTarget,
        ),
        message: 'Local service manager compatibility is available.',
      ),
      PlatformManagerComponentHealth(
        managerKey: 'pty',
        ready: _isSupportedCompatibilityTarget(context.pty.compatibilityTarget),
        message: 'PTY manager compatibility is available.',
      ),
    ];
    return PlatformManagerHealthSnapshot(
      targetId: context.targetId,
      ready: components.every((component) => component.ready),
      components: components,
    );
  }

  PlatformManagerHealthSnapshot probeHealthSnapshot({
    List<PlatformManagerHealthProbe>? probes,
  }) {
    final effectiveProbes =
        probes ?? PlatformManagerHealthProbe.defaultProbes();
    final components = effectiveProbes
        .map((probe) => probe.run(this))
        .toList(growable: false);
    return PlatformManagerHealthSnapshot(
      targetId: context.targetId,
      ready: components.every((component) => component.ready),
      components: components,
      probeSource: 'platform-manager-probes',
    );
  }

  Future<PlatformManagerHealthSnapshot> probeLiveOperationHealthSnapshot({
    PlatformManagerLiveOperationProbeRegistry? registry,
  }) {
    return (registry ?? PlatformManagerLiveOperationProbeRegistry.defaults())
        .probe(this);
  }
}

class PlatformManagerBundleSnapshot {
  const PlatformManagerBundleSnapshot({
    required this.targetId,
    required this.contextSource,
    required this.schemaVersion,
    required this.supportsLinuxDebianArmTarget,
    required this.managerKeys,
  });

  final String targetId;
  final String contextSource;
  final String schemaVersion;
  final bool supportsLinuxDebianArmTarget;
  final List<String> managerKeys;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'targetId': targetId,
      'contextSource': contextSource,
      'schemaVersion': schemaVersion,
      'supportsLinuxDebianArmTarget': supportsLinuxDebianArmTarget,
      'managerKeys': managerKeys,
    };
  }
}

class PlatformManagerComponentHealth {
  const PlatformManagerComponentHealth({
    required this.managerKey,
    required this.ready,
    required this.message,
    this.probeKind = PlatformManagerHealthProbeKind.factReadiness,
    this.operationId = '',
    this.description = '',
    this.recoveryActions = const <PlatformManagerRecoveryAction>[],
    this.metadata = const <String, Object?>{},
  });

  final String managerKey;
  final bool ready;
  final String message;
  final PlatformManagerHealthProbeKind probeKind;
  final String operationId;
  final String description;
  final List<PlatformManagerRecoveryAction> recoveryActions;
  final Map<String, Object?> metadata;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'managerKey': managerKey,
      'ready': ready,
      'message': message,
      'probeKind': probeKind.name,
      if (operationId.isNotEmpty) 'operationId': operationId,
      if (description.isNotEmpty) 'description': description,
      if (recoveryActions.isNotEmpty)
        'recoveryActions': recoveryActions
            .map((action) => action.toJson())
            .toList(growable: false),
      if (metadata.isNotEmpty) 'metadata': metadata,
    };
  }
}

class PlatformManagerRecoveryAction {
  const PlatformManagerRecoveryAction({
    required this.id,
    required this.label,
    required this.managerKey,
    required this.message,
    this.metadata = const <String, Object?>{},
  });

  final String id;
  final String label;
  final String managerKey;
  final String message;
  final Map<String, Object?> metadata;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'label': label,
      'managerKey': managerKey,
      'message': message,
      if (metadata.isNotEmpty) 'metadata': metadata,
    };
  }
}

class PlatformManagerRecoveryActionRoute {
  const PlatformManagerRecoveryActionRoute({
    required this.actionId,
    required this.managerKey,
    required this.route,
    required this.label,
    required this.message,
    this.settingsSectionId = '',
    this.metadata = const <String, Object?>{},
  });

  final String actionId;
  final String managerKey;
  final String route;
  final String label;
  final String message;
  final String settingsSectionId;
  final Map<String, Object?> metadata;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'actionId': actionId,
      'managerKey': managerKey,
      'route': route,
      'label': label,
      'message': message,
      if (settingsSectionId.isNotEmpty) 'settingsSectionId': settingsSectionId,
      if (metadata.isNotEmpty) 'metadata': metadata,
    };
  }
}

class PlatformManagerRecoveryActionRouter {
  const PlatformManagerRecoveryActionRouter({
    this.settingsRoutePrefix = 'settings://platform',
  });

  final String settingsRoutePrefix;

  PlatformManagerRecoveryActionRoute routeFor(
    PlatformManagerRecoveryAction action,
  ) {
    final settingsSectionId =
        action.metadata['settingsSectionId'] as String? ?? action.managerKey;
    return PlatformManagerRecoveryActionRoute(
      actionId: action.id,
      managerKey: action.managerKey,
      route:
          '$settingsRoutePrefix/$settingsSectionId?action=${Uri.encodeComponent(action.id)}',
      label: action.label,
      message: action.message,
      settingsSectionId: settingsSectionId,
      metadata: <String, Object?>{
        ...action.metadata,
        'surface': 'settings',
        'managerKey': action.managerKey,
        'settingsSectionId': settingsSectionId,
      },
    );
  }

  List<PlatformManagerRecoveryActionRoute> routesFor(
    PlatformManagerHealthSnapshot snapshot,
  ) {
    return snapshot.recoveryActions.map(routeFor).toList(growable: false);
  }
}

typedef PlatformManagerProbeReady = bool Function(PlatformManagerBundle bundle);
typedef PlatformManagerProbeMessage =
    String Function(PlatformManagerBundle bundle, bool ready);
typedef PlatformManagerLiveOperationProbeCallback =
    Future<PlatformManagerLiveOperationProbeResult> Function(
      PlatformManagerBundle bundle,
    );

class PlatformManagerHealthProbe {
  const PlatformManagerHealthProbe({
    required this.managerKey,
    required this.ready,
    required this.message,
    this.probeKind = PlatformManagerHealthProbeKind.managerLiveOperation,
    this.operationId = '',
    this.description = '',
    this.recoveryActions = const <PlatformManagerRecoveryAction>[],
  });

  final String managerKey;
  final PlatformManagerProbeReady ready;
  final PlatformManagerProbeMessage message;
  final PlatformManagerHealthProbeKind probeKind;
  final String operationId;
  final String description;
  final List<PlatformManagerRecoveryAction> recoveryActions;

  static List<PlatformManagerHealthProbe> defaultProbes() {
    return <PlatformManagerHealthProbe>[
      _probe(
        'fileSystem',
        (bundle) => _isSupportedCompatibilityTarget(
          bundle.context.fileSystem.compatibilityTarget,
        ),
      ),
      _probe(
        'shell',
        (bundle) => _isSupportedCompatibilityTarget(
          bundle.context.shell.compatibilityTarget,
        ),
      ),
      _probe(
        'process',
        (bundle) => _isSupportedCompatibilityTarget(
          bundle.context.process.compatibilityTarget,
        ),
      ),
      _probe(
        'resource',
        (bundle) => _isSupportedCompatibilityTarget(
          bundle.context.resource.compatibilityTarget,
        ),
      ),
      _probe(
        'network',
        (bundle) => _isSupportedCompatibilityTarget(
          bundle.context.network.compatibilityTarget,
        ),
      ),
      _probe(
        'clipboard',
        (bundle) => _isSupportedCompatibilityTarget(
          bundle.context.clipboard.compatibilityTarget,
        ),
      ),
      _probe(
        'notification',
        (bundle) => _isSupportedCompatibilityTarget(
          bundle.context.notification.compatibilityTarget,
        ),
      ),
      _probe(
        'localService',
        (bundle) => _isSupportedCompatibilityTarget(
          bundle.context.localService.compatibilityTarget,
        ),
      ),
      _probe(
        'pty',
        (bundle) => _isSupportedCompatibilityTarget(
          bundle.context.pty.compatibilityTarget,
        ),
      ),
    ];
  }

  PlatformManagerComponentHealth run(PlatformManagerBundle bundle) {
    final result = ready(bundle);
    return PlatformManagerComponentHealth(
      managerKey: managerKey,
      ready: result,
      message: message(bundle, result),
      probeKind: probeKind,
      operationId: operationId.isEmpty
          ? 'platform.$managerKey.live-operation'
          : operationId,
      description: description,
      recoveryActions: result
          ? const <PlatformManagerRecoveryAction>[]
          : recoveryActions,
    );
  }
}

class PlatformManagerLiveOperationProbeResult {
  const PlatformManagerLiveOperationProbeResult({
    required this.managerKey,
    required this.ready,
    required this.message,
    required this.operationId,
    this.description = '',
    this.recoveryActions = const <PlatformManagerRecoveryAction>[],
    this.metadata = const <String, Object?>{},
  });

  const PlatformManagerLiveOperationProbeResult.ready({
    required String managerKey,
    required String operationId,
    String message = 'Platform manager live operation probe passed.',
    String description = '',
    Map<String, Object?> metadata = const <String, Object?>{},
  }) : this(
         managerKey: managerKey,
         ready: true,
         message: message,
         operationId: operationId,
         description: description,
         metadata: metadata,
       );

  const PlatformManagerLiveOperationProbeResult.blocked({
    required String managerKey,
    required String operationId,
    String message = 'Platform manager live operation probe is blocked.',
    String description = '',
    List<PlatformManagerRecoveryAction> recoveryActions =
        const <PlatformManagerRecoveryAction>[],
    Map<String, Object?> metadata = const <String, Object?>{},
  }) : this(
         managerKey: managerKey,
         ready: false,
         message: message,
         operationId: operationId,
         description: description,
         recoveryActions: recoveryActions,
         metadata: metadata,
       );

  final String managerKey;
  final bool ready;
  final String message;
  final String operationId;
  final String description;
  final List<PlatformManagerRecoveryAction> recoveryActions;
  final Map<String, Object?> metadata;

  PlatformManagerComponentHealth toComponentHealth() {
    return PlatformManagerComponentHealth(
      managerKey: managerKey,
      ready: ready,
      message: message,
      probeKind: PlatformManagerHealthProbeKind.managerLiveOperation,
      operationId: operationId,
      description: description,
      recoveryActions: ready
          ? const <PlatformManagerRecoveryAction>[]
          : recoveryActions,
      metadata: metadata,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'managerKey': managerKey,
      'ready': ready,
      'message': message,
      'operationId': operationId,
      if (description.isNotEmpty) 'description': description,
      if (recoveryActions.isNotEmpty)
        'recoveryActions': recoveryActions
            .map((action) => action.toJson())
            .toList(growable: false),
      if (metadata.isNotEmpty) 'metadata': metadata,
    };
  }
}

class PlatformManagerLiveOperationProbeRegistration {
  const PlatformManagerLiveOperationProbeRegistration({
    required this.managerKey,
    required this.operationId,
    required PlatformManagerLiveOperationProbeCallback probe,
    this.description = '',
    this.recoveryActions = const <PlatformManagerRecoveryAction>[],
  }) : _probe = probe;

  final String managerKey;
  final String operationId;
  final String description;
  final List<PlatformManagerRecoveryAction> recoveryActions;
  final PlatformManagerLiveOperationProbeCallback _probe;

  Future<PlatformManagerComponentHealth> run(
    PlatformManagerBundle bundle,
  ) async {
    try {
      final result = await _probe(bundle);
      return result.toComponentHealth();
    } on Object catch (error) {
      return PlatformManagerComponentHealth(
        managerKey: managerKey,
        ready: false,
        message: 'Platform manager live operation $operationId failed: $error.',
        probeKind: PlatformManagerHealthProbeKind.managerLiveOperation,
        operationId: operationId,
        description: description,
        recoveryActions: recoveryActions,
      );
    }
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'managerKey': managerKey,
      'operationId': operationId,
      if (description.isNotEmpty) 'description': description,
      if (recoveryActions.isNotEmpty)
        'recoveryActions': recoveryActions
            .map((action) => action.toJson())
            .toList(growable: false),
    };
  }
}

class PlatformManagerLiveOperationProbeRegistry {
  const PlatformManagerLiveOperationProbeRegistry({
    this.registrations =
        const <PlatformManagerLiveOperationProbeRegistration>[],
  });

  final List<PlatformManagerLiveOperationProbeRegistration> registrations;

  factory PlatformManagerLiveOperationProbeRegistry.defaults() {
    return PlatformManagerLiveOperationProbeRegistry(
      registrations: <PlatformManagerLiveOperationProbeRegistration>[
        _liveRegistration(
          managerKey: 'fileSystem',
          description: 'Read the native temporary-directory entry.',
          probe: _probeFileSystemManager,
        ),
        _liveRegistration(
          managerKey: 'shell',
          description: 'Run a no-output command through the selected shell.',
          probe: _probeShellManager,
        ),
        _liveRegistration(
          managerKey: 'process',
          description: 'Run a no-output child process through vityod.',
          probe: _probeProcessManager,
        ),
        _liveRegistration(
          managerKey: 'resource',
          description: 'Read the current native resource snapshot.',
          probe: _probeResourceManager,
        ),
        _liveRegistration(
          managerKey: 'network',
          description: 'Read a disposable loopback HTTP endpoint.',
          probe: _probeNetworkManager,
        ),
        _liveRegistration(
          managerKey: 'clipboard',
          description: 'Read clipboard text without replacing its contents.',
          probe: _probeClipboardManager,
        ),
        _liveRegistration(
          managerKey: 'notification',
          description: 'Dispatch a silent in-app notification probe.',
          probe: _probeNotificationManager,
        ),
        _liveRegistration(
          managerKey: 'localService',
          description: 'Bind and close a disposable loopback service.',
          probe: _probeLocalServiceManager,
        ),
        _liveRegistration(
          managerKey: 'pty',
          description: 'Open, resize, and close a disposable PTY session.',
          probe: _probePtyManager,
        ),
      ],
    );
  }

  bool get isEmpty => registrations.isEmpty;
  bool get isNotEmpty => registrations.isNotEmpty;

  bool get coversAllManagers {
    return registrations
        .map((registration) => registration.managerKey)
        .toSet()
        .containsAll(_platformManagerKeys);
  }

  Future<PlatformManagerHealthSnapshot> probe(
    PlatformManagerBundle bundle,
  ) async {
    final components = await Future.wait(
      registrations.map((registration) => registration.run(bundle)),
    );
    return PlatformManagerHealthSnapshot(
      targetId: bundle.context.targetId,
      ready: components.every((component) => component.ready),
      components: List<PlatformManagerComponentHealth>.unmodifiable(components),
      probeSource: 'platform-live-operation-registry',
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'registrationCount': registrations.length,
      'coversAllManagers': coversAllManagers,
      'registrations': registrations
          .map((registration) => registration.toJson())
          .toList(growable: false),
    };
  }
}

const _platformManagerKeys = <String>{
  'fileSystem',
  'shell',
  'process',
  'resource',
  'network',
  'clipboard',
  'notification',
  'localService',
  'pty',
};

PlatformManagerLiveOperationProbeRegistration _liveRegistration({
  required String managerKey,
  required String description,
  required PlatformManagerLiveOperationProbeCallback probe,
}) {
  return PlatformManagerLiveOperationProbeRegistration(
    managerKey: managerKey,
    operationId: 'platform.$managerKey.live-operation',
    description: description,
    recoveryActions: _platformRecoveryActions(managerKey),
    probe: probe,
  );
}

List<PlatformManagerRecoveryAction> _platformRecoveryActions(
  String managerKey,
) {
  return <PlatformManagerRecoveryAction>[
    PlatformManagerRecoveryAction(
      id: 'platform.$managerKey.open-settings',
      label: 'Review ${_managerTitle(managerKey)} settings',
      managerKey: managerKey,
      message: 'Review ${_managerTitle(managerKey)} availability and retry.',
      metadata: <String, Object?>{'settingsSectionId': managerKey},
    ),
  ];
}

String _managerTitle(String managerKey) {
  return switch (managerKey) {
    'fileSystem' => 'File System',
    'localService' => 'Local Service',
    'pty' => 'PTY',
    _ => '${managerKey[0].toUpperCase()}${managerKey.substring(1)}',
  };
}

PlatformManagerLiveOperationProbeResult _liveResult({
  required String managerKey,
  required bool ready,
  required String message,
  Map<String, Object?> metadata = const <String, Object?>{},
}) {
  final operationId = 'platform.$managerKey.live-operation';
  if (ready) {
    return PlatformManagerLiveOperationProbeResult.ready(
      managerKey: managerKey,
      operationId: operationId,
      message: message,
      metadata: metadata,
    );
  }
  return PlatformManagerLiveOperationProbeResult.blocked(
    managerKey: managerKey,
    operationId: operationId,
    message: message,
    recoveryActions: _platformRecoveryActions(managerKey),
    metadata: metadata,
  );
}

Future<PlatformManagerLiveOperationProbeResult> _probeFileSystemManager(
  PlatformManagerBundle bundle,
) async {
  final snapshot = await bundle.fileSystem.stat(
    bundle.resource.snapshot().systemTempPath,
  );
  return _liveResult(
    managerKey: 'fileSystem',
    ready: snapshot.isDirectory,
    message: snapshot.isDirectory
        ? 'File System live read succeeded.'
        : 'The configured temporary directory is not readable.',
    metadata: <String, Object?>{'entityType': snapshot.type.name},
  );
}

Future<PlatformManagerLiveOperationProbeResult> _probeShellManager(
  PlatformManagerBundle bundle,
) async {
  final result = await bundle.shell.run(
    const ShellCommandRequest(command: ':', loginShell: false),
  );
  return _liveResult(
    managerKey: 'shell',
    ready: result.succeeded,
    message: result.succeeded
        ? 'Shell live command succeeded.'
        : (result.message ?? 'Shell live command failed.'),
    metadata: <String, Object?>{
      'status': result.status.name,
      if (result.exitCode != null) 'exitCode': result.exitCode,
    },
  );
}

Future<PlatformManagerLiveOperationProbeResult> _probeProcessManager(
  PlatformManagerBundle bundle,
) async {
  final shell = bundle.context.shell.defaultShell;
  if (shell == null) {
    return _liveResult(
      managerKey: 'process',
      ready: false,
      message: 'No executable is available for the process live check.',
    );
  }
  final result = await bundle.process.run(
    ProcessCommandRequest(
      executablePath: shell.path,
      arguments: switch (shell.family) {
        ShellFamily.powershell => const <String>[
          '-NoLogo',
          '-NoProfile',
          '-Command',
          'exit 0',
        ],
        ShellFamily.cmd => const <String>['/D', '/C', 'exit 0'],
        _ => const <String>['-c', ':'],
      },
    ),
  );
  return _liveResult(
    managerKey: 'process',
    ready: result.succeeded,
    message: result.succeeded
        ? 'Process live command succeeded.'
        : (result.message ?? 'Process live command failed.'),
    metadata: <String, Object?>{
      'status': result.status.name,
      if (result.exitCode != null) 'exitCode': result.exitCode,
      if (result.metadata['processHandleId'] is String)
        'processHandleId': result.metadata['processHandleId']!,
    },
  );
}

Future<PlatformManagerLiveOperationProbeResult> _probeResourceManager(
  PlatformManagerBundle bundle,
) async {
  final snapshot = bundle.resource.snapshot();
  final ready =
      snapshot.processorCount > 0 && snapshot.systemTempPath.trim().isNotEmpty;
  return _liveResult(
    managerKey: 'resource',
    ready: ready,
    message: ready
        ? 'Resource snapshot is available.'
        : 'Resource snapshot is incomplete.',
    metadata: <String, Object?>{'processorCount': snapshot.processorCount},
  );
}

Future<PlatformManagerLiveOperationProbeResult> _probeNetworkManager(
  PlatformManagerBundle bundle,
) async {
  LocalServiceHandle? service;
  try {
    service = await bundle.localService.startHttpTextService(
      const LocalHttpServiceRequest(
        path: '/vityo-platform-network-health',
        responseText: 'vityo-platform-network-ok',
      ),
    );
    final response = await bundle.network.getText(service.uri);
    final ready =
        response.succeeded && response.body == 'vityo-platform-network-ok';
    return _liveResult(
      managerKey: 'network',
      ready: ready,
      message: ready
          ? 'Network loopback request succeeded.'
          : (response.message ?? 'Network loopback request failed.'),
      metadata: <String, Object?>{
        'status': response.status.name,
        if (response.statusCode != null) 'statusCode': response.statusCode,
      },
    );
  } finally {
    await service?.close();
  }
}

Future<PlatformManagerLiveOperationProbeResult> _probeClipboardManager(
  PlatformManagerBundle bundle,
) async {
  final result = await bundle.clipboard.readText();
  return _liveResult(
    managerKey: 'clipboard',
    ready: result.succeeded,
    message: result.succeeded
        ? 'Clipboard text read succeeded without changing its contents.'
        : (result.message ?? 'Clipboard text read failed.'),
    metadata: <String, Object?>{'status': result.status.name},
  );
}

Future<PlatformManagerLiveOperationProbeResult> _probeNotificationManager(
  PlatformManagerBundle bundle,
) async {
  final result = await bundle.notification.notify(
    const NotificationRequest(
      title: 'Vityo platform health',
      body: 'Silent in-app delivery check.',
    ),
  );
  return _liveResult(
    managerKey: 'notification',
    ready: result.delivered,
    message: result.delivered
        ? 'Notification delivery route is available.'
        : (result.message ?? 'Notification delivery route is blocked.'),
    metadata: <String, Object?>{'status': result.status.name},
  );
}

Future<PlatformManagerLiveOperationProbeResult> _probeLocalServiceManager(
  PlatformManagerBundle bundle,
) async {
  LocalServiceHandle? service;
  try {
    service = await bundle.localService.startHttpTextService(
      const LocalHttpServiceRequest(
        path: '/vityo-platform-local-service-health',
        responseText: 'ok',
      ),
    );
    return _liveResult(
      managerKey: 'localService',
      ready: service.uri.isScheme('http'),
      message: service.uri.isScheme('http')
          ? 'Local Service loopback bind succeeded.'
          : 'Local Service returned an invalid endpoint.',
    );
  } finally {
    await service?.close();
  }
}

Future<PlatformManagerLiveOperationProbeResult> _probePtyManager(
  PlatformManagerBundle bundle,
) async {
  final shell = bundle.context.shell.defaultShell;
  if (shell == null) {
    return _liveResult(
      managerKey: 'pty',
      ready: false,
      message: 'No executable shell is available for the PTY live check.',
    );
  }
  PtySession? session;
  try {
    session = await bundle.pty.start(
      PtySessionRequest(executablePath: shell.path, rows: 4, cols: 20),
    );
    if (session.state != PtySessionState.running) {
      return _liveResult(
        managerKey: 'pty',
        ready: false,
        message: 'PTY session did not enter the running state.',
        metadata: <String, Object?>{'state': session.state.name},
      );
    }
    final resize = await session.resize(rows: 6, cols: 24);
    return _liveResult(
      managerKey: 'pty',
      ready: resize.applied,
      message: resize.applied
          ? 'PTY open and resize operations succeeded.'
          : (resize.message ?? 'PTY resize operation failed.'),
      metadata: <String, Object?>{
        'state': session.state.name,
        'resizeStatus': resize.status.name,
      },
    );
  } finally {
    await session?.close(force: true);
  }
}

class PlatformManagerHealthSnapshot {
  const PlatformManagerHealthSnapshot({
    required this.targetId,
    required this.ready,
    required this.components,
    this.probeSource = 'platform-context-facts',
    this.todo = '',
  });

  final String targetId;
  final bool ready;
  final List<PlatformManagerComponentHealth> components;
  final String probeSource;
  final String todo;

  int get readyCount {
    return components.where((component) => component.ready).length;
  }

  int get blockedCount {
    return components.length - readyCount;
  }

  List<PlatformManagerRecoveryAction> get recoveryActions {
    return components
        .expand((component) => component.recoveryActions)
        .toList(growable: false);
  }

  Map<String, int> get probeKindCounts {
    return <String, int>{
      for (final kind in PlatformManagerHealthProbeKind.values)
        kind.name: components
            .where((component) => component.probeKind == kind)
            .length,
    };
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'targetId': targetId,
      'probeSource': probeSource,
      'ready': ready,
      'readyCount': readyCount,
      'blockedCount': blockedCount,
      'probeKindCounts': probeKindCounts,
      'recoveryActionCount': recoveryActions.length,
      'componentCount': components.length,
      'components': components
          .map((component) => component.toJson())
          .toList(growable: false),
      if (recoveryActions.isNotEmpty)
        'recoveryActions': recoveryActions
            .map((action) => action.toJson())
            .toList(growable: false),
      if (todo.isNotEmpty) 'todo': todo,
    };
  }
}

PlatformManagerHealthProbe _probe(
  String managerKey,
  PlatformManagerProbeReady ready,
) {
  return PlatformManagerHealthProbe(
    managerKey: managerKey,
    ready: ready,
    probeKind: PlatformManagerHealthProbeKind.managerLiveOperation,
    operationId: 'platform.$managerKey.live-operation',
    description: 'Safe platform manager health probe for $managerKey.',
    message: (_, isReady) => isReady
        ? '$managerKey manager probe is ready.'
        : '$managerKey manager probe is blocked.',
    recoveryActions: <PlatformManagerRecoveryAction>[
      PlatformManagerRecoveryAction(
        id: 'platform.$managerKey.open-settings',
        label: 'Open platform settings',
        managerKey: managerKey,
        message: 'Review platform configuration for $managerKey.',
        metadata: <String, Object?>{'settingsSectionId': managerKey},
      ),
    ],
  );
}

bool _isSupportedCompatibilityTarget(String compatibilityTarget) {
  return compatibilityTarget.isNotEmpty && compatibilityTarget != 'unsupported';
}

Future<PlatformManagerBundle> createPlatformManagerBundle({
  required PlatformContextSnapshot platformContext,
  VityodClient? vityodClient,
  String? workspaceRoot,
}) async {
  final process = await createPlatformProcessManager(
    platformContext: platformContext,
    vityodClient: vityodClient,
  );
  final fileSystem = await createPlatformFileSystemManager(
    platformContext: platformContext,
    vityodClient: vityodClient,
    allowedRoots: <String>[
      if (workspaceRoot != null) workspaceRoot,
      if (platformContext.resource.homePath != null)
        platformContext.resource.homePath!,
      platformContext.resource.systemTempPath,
    ],
  );
  return PlatformManagerBundle(
    context: platformContext,
    compatibility: PlatformAdapter(platformContext).adapt(),
    fileSystem: fileSystem,
    shell: await createPlatformShellManager(
      platformContext: platformContext,
      processManager: process,
    ),
    process: process,
    resource: await createPlatformResourceManager(
      platformContext: platformContext,
      fileSystemManager: fileSystem,
    ),
    network: await createPlatformNetworkManager(
      platformContext: platformContext,
    ),
    clipboard: await createPlatformClipboardManager(
      platformContext: platformContext,
    ),
    notification: await createPlatformNotificationManager(
      platformContext: platformContext,
    ),
    localService: await createPlatformLocalServiceManager(
      platformContext: platformContext,
    ),
    pty: await createPlatformPtyManager(
      platformContext: platformContext,
      vityodClient: vityodClient,
    ),
  );
}

Future<PlatformManagerBundle> createDetectedPlatformManagerBundle({
  String targetId = 'local',
  PlatformDetector? detector,
  VityodClient? vityodClient,
  String? workspaceRoot,
}) async {
  final platformDetector =
      detector ??
      const ProbingPlatformDetector(
        fileSystemProber: LocalFileSystemProber(),
        shellProber: LocalShellProber(),
        processProber: LocalProcessProber(),
        resourceProber: LocalResourceProber(),
        networkProber: LocalNetworkProber(),
        clipboardProber: LocalClipboardProber(),
        notificationProber: LocalNotificationProber(),
        localServiceProber: LocalLoopbackServiceProber(),
        ptyProber: LocalPtyProber(),
      );
  final context = await platformDetector.detect(targetId: targetId);
  return createPlatformManagerBundle(
    platformContext: context,
    vityodClient: vityodClient,
    workspaceRoot: workspaceRoot,
  );
}
