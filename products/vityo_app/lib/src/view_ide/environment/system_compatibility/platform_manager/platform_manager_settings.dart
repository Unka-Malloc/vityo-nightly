import 'platform_manager.dart';

class PlatformManagerSettingsSection {
  PlatformManagerSettingsSection({
    required this.id,
    required this.title,
    required this.ready,
    required this.message,
    required this.operationId,
    required this.description,
    required Iterable<PlatformManagerRecoveryActionRoute> recoveryRoutes,
    this.metadata = const <String, Object?>{},
  }) : recoveryRoutes = List<PlatformManagerRecoveryActionRoute>.unmodifiable(
         recoveryRoutes,
       );

  final String id;
  final String title;
  final bool ready;
  final String message;
  final String operationId;
  final String description;
  final List<PlatformManagerRecoveryActionRoute> recoveryRoutes;
  final Map<String, Object?> metadata;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'title': title,
      'ready': ready,
      'message': message,
      'operationId': operationId,
      if (description.isNotEmpty) 'description': description,
      'recoveryRoutes': recoveryRoutes
          .map((route) => route.toJson())
          .toList(growable: false),
      if (metadata.isNotEmpty) 'metadata': metadata,
    };
  }
}

class PlatformManagerSettingsSurface {
  PlatformManagerSettingsSurface({
    required this.targetId,
    required this.ready,
    required this.probeSource,
    required Iterable<PlatformManagerSettingsSection> sections,
    this.activeSectionId,
  }) : sections = List<PlatformManagerSettingsSection>.unmodifiable(sections);

  factory PlatformManagerSettingsSurface.fromHealthSnapshot(
    PlatformManagerHealthSnapshot snapshot, {
    String? activeSectionId,
    PlatformManagerRecoveryActionRouter router =
        const PlatformManagerRecoveryActionRouter(),
  }) {
    return PlatformManagerSettingsSurface(
      targetId: snapshot.targetId,
      ready: snapshot.ready,
      probeSource: snapshot.probeSource,
      activeSectionId: activeSectionId,
      sections: snapshot.components.map((component) {
        return PlatformManagerSettingsSection(
          id: component.managerKey,
          title: platformManagerSettingsTitle(component.managerKey),
          ready: component.ready,
          message: component.message,
          operationId: component.operationId,
          description: component.description,
          recoveryRoutes: component.recoveryActions.map(router.routeFor),
          metadata: component.metadata,
        );
      }),
    );
  }

  final String targetId;
  final bool ready;
  final String probeSource;
  final List<PlatformManagerSettingsSection> sections;
  final String? activeSectionId;

  int get readyCount => sections.where((section) => section.ready).length;

  int get blockedCount => sections.length - readyCount;

  PlatformManagerSettingsSection? get activeSection {
    final id = activeSectionId;
    if (id == null) return null;
    for (final section in sections) {
      if (section.id == id) return section;
    }
    return null;
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'targetId': targetId,
      'ready': ready,
      'probeSource': probeSource,
      'readyCount': readyCount,
      'blockedCount': blockedCount,
      if (activeSectionId != null) 'activeSectionId': activeSectionId,
      'sections': sections
          .map((section) => section.toJson())
          .toList(growable: false),
    };
  }
}

String platformManagerSettingsTitle(String managerKey) {
  return switch (managerKey) {
    'fileSystem' => 'File System',
    'shell' => 'Shell',
    'process' => 'Process',
    'resource' => 'Resources',
    'network' => 'Network',
    'clipboard' => 'Clipboard',
    'notification' => 'Notifications',
    'localService' => 'Local Service',
    'pty' => 'Terminal PTY',
    _ => managerKey,
  };
}
