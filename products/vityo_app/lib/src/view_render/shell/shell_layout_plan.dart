import '../../view_ide/foundation/foundation.dart';
import 'shell_model.dart';

enum ShellLayoutMode { desktop, compact }

extension ShellLayoutModeX on ShellLayoutMode {
  String get wireValue => switch (this) {
    ShellLayoutMode.desktop => 'desktop',
    ShellLayoutMode.compact => 'compact',
  };
}

enum ShellLayoutRegion {
  topBar,
  activityRail,
  primarySidebar,
  editor,
  bottomPanel,
  auxiliaryPanel,
  statusBar,
}

extension ShellLayoutRegionX on ShellLayoutRegion {
  String get wireValue => switch (this) {
    ShellLayoutRegion.topBar => 'top-bar',
    ShellLayoutRegion.activityRail => 'activity-rail',
    ShellLayoutRegion.primarySidebar => 'primary-sidebar',
    ShellLayoutRegion.editor => 'editor',
    ShellLayoutRegion.bottomPanel => 'bottom-panel',
    ShellLayoutRegion.auxiliaryPanel => 'auxiliary-panel',
    ShellLayoutRegion.statusBar => 'status-bar',
  };
}

class ShellPanelDescriptor {
  const ShellPanelDescriptor({
    required this.id,
    required this.title,
    required this.region,
    required this.visible,
    this.active = false,
    this.metadata = const <String, Object?>{},
    this.todo = '',
  });

  factory ShellPanelDescriptor.fromJson(Map<String, Object?> json) {
    return ShellPanelDescriptor(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      region: _regionFromWire(json['region']),
      visible: json['visible'] as bool? ?? false,
      active: json['active'] as bool? ?? false,
      metadata: _jsonObjectMap(json['metadata']),
      todo: json['todo'] as String? ?? '',
    );
  }

  final String id;
  final String title;
  final ShellLayoutRegion region;
  final bool visible;
  final bool active;
  final Map<String, Object?> metadata;
  final String todo;

  ShellPanelDescriptor copyWith({
    String? id,
    String? title,
    ShellLayoutRegion? region,
    bool? visible,
    bool? active,
    Map<String, Object?>? metadata,
    String? todo,
  }) {
    return ShellPanelDescriptor(
      id: id ?? this.id,
      title: title ?? this.title,
      region: region ?? this.region,
      visible: visible ?? this.visible,
      active: active ?? this.active,
      metadata: metadata ?? this.metadata,
      todo: todo ?? this.todo,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'title': title,
      'region': region.wireValue,
      'visible': visible,
      'active': active,
      if (metadata.isNotEmpty) 'metadata': metadata,
      if (todo.isNotEmpty) 'todo': todo,
    };
  }
}

enum ShellPanelContributionStatus { scaffolded, wired, production }

extension ShellPanelContributionStatusX on ShellPanelContributionStatus {
  String get wireValue => switch (this) {
    ShellPanelContributionStatus.scaffolded => 'scaffolded',
    ShellPanelContributionStatus.wired => 'wired',
    ShellPanelContributionStatus.production => 'production',
  };
}

class ShellPanelContribution {
  const ShellPanelContribution({
    required this.id,
    required this.title,
    required this.region,
    required this.surfaceId,
    required this.capabilities,
    required this.status,
    this.route,
    this.defaultVisible = true,
    this.metadata = const <String, Object?>{},
    this.todo = '',
  });

  factory ShellPanelContribution.routedPanel({
    required String id,
    required String title,
    required ShellLayoutRegion region,
    required String surfaceId,
    required List<String> capabilities,
    required ShellPanelContributionStatus status,
    required BottomSurfaceTab route,
    Map<String, Object?> metadata = const <String, Object?>{},
    String todo = '',
  }) {
    return ShellPanelContribution(
      id: id,
      title: title,
      region: region,
      surfaceId: surfaceId,
      capabilities: capabilities,
      status: status,
      route: route,
      metadata: metadata,
      todo: todo,
    );
  }

  final String id;
  final String title;
  final ShellLayoutRegion region;
  final String surfaceId;
  final List<String> capabilities;
  final ShellPanelContributionStatus status;
  final BottomSurfaceTab? route;
  final bool defaultVisible;
  final Map<String, Object?> metadata;
  final String todo;

  ShellPanelDescriptor toPanelDescriptor({
    required BottomSurfaceTab activeWorkbenchRoute,
  }) {
    return ShellPanelDescriptor(
      id: id,
      title: title,
      region: region,
      visible: defaultVisible && route == activeWorkbenchRoute,
      active: route == activeWorkbenchRoute,
      metadata: <String, Object?>{
        ...metadata,
        'surfaceId': surfaceId,
        'capabilities': capabilities,
        'contributionStatus': status.wireValue,
        if (route != null) 'route': route!.name,
      },
      todo: todo,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'title': title,
      'region': region.wireValue,
      'surfaceId': surfaceId,
      'capabilities': capabilities,
      'status': status.wireValue,
      'defaultVisible': defaultVisible,
      if (route != null) 'route': route!.name,
      if (metadata.isNotEmpty) 'metadata': metadata,
      if (todo.isNotEmpty) 'todo': todo,
    };
  }
}

class ShellPanelContributionCoverage {
  const ShellPanelContributionCoverage({
    required this.requiredPanelIds,
    required this.registeredPanelIds,
    required this.missingPanelIds,
  });

  final List<String> requiredPanelIds;
  final List<String> registeredPanelIds;
  final List<String> missingPanelIds;

  bool get complete => missingPanelIds.isEmpty;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'complete': complete,
      'requiredPanelIds': requiredPanelIds,
      'registeredPanelIds': registeredPanelIds,
      'missingPanelIds': missingPanelIds,
    };
  }
}

class ShellPanelContributionRegistry {
  ShellPanelContributionRegistry({
    Iterable<ShellPanelContribution> contributions =
        const <ShellPanelContribution>[],
  }) {
    for (final contribution in contributions) {
      register(contribution);
    }
  }

  factory ShellPanelContributionRegistry.defaultIdePanels() {
    return ShellPanelContributionRegistry(
      contributions: _defaultPanelContributions(),
    );
  }

  static const List<String> coreIdePanelIds = <String>[
    'bottom.problems',
    'primary.search',
    'primary.settings',
    'primary.extensions',
    'bottom.debug',
    'bottom.agent',
  ];

  final List<ShellPanelContribution> _contributions =
      <ShellPanelContribution>[];

  List<ShellPanelContribution> get contributions {
    return List<ShellPanelContribution>.unmodifiable(_contributions);
  }

  void register(ShellPanelContribution contribution) {
    _contributions.removeWhere((candidate) => candidate.id == contribution.id);
    _contributions.add(contribution);
  }

  ShellPanelContribution? panelById(String panelId) {
    for (final contribution in _contributions) {
      if (contribution.id == panelId) {
        return contribution;
      }
    }
    return null;
  }

  ShellPanelContributionCoverage coverageForCoreIdePanels() {
    return coverageFor(requiredPanelIds: coreIdePanelIds);
  }

  ShellPanelContributionCoverage coverageFor({
    required List<String> requiredPanelIds,
  }) {
    final registered = _contributions
        .map((contribution) => contribution.id)
        .toSet();
    return ShellPanelContributionCoverage(
      requiredPanelIds: requiredPanelIds,
      registeredPanelIds: _contributions
          .map((contribution) => contribution.id)
          .toList(growable: false),
      missingPanelIds: requiredPanelIds
          .where((panelId) => !registered.contains(panelId))
          .toList(growable: false),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'contributionCount': _contributions.length,
      'coreIdeCoverage': coverageForCoreIdePanels().toJson(),
      'contributions': _contributions
          .map((contribution) => contribution.toJson())
          .toList(growable: false),
    };
  }
}

class ShellLayoutPlan {
  const ShellLayoutPlan({
    required this.mode,
    required this.activeWorkbenchRoute,
    required this.panels,
    this.todo = '',
  });

  factory ShellLayoutPlan.fromJson(Map<String, Object?> json) {
    return ShellLayoutPlan(
      mode: _modeFromWire(json['mode']),
      activeWorkbenchRoute: _routeFromWire(json['activeWorkbenchRoute']),
      panels: _jsonPanels(json['panels']),
      todo: json['todo'] as String? ?? '',
    );
  }

  factory ShellLayoutPlan.forViewport({
    required BottomSurfaceTab activeWorkbenchRoute,
    required bool compact,
    ShellPanelContributionRegistry? panelRegistry,
  }) {
    final mode = compact ? ShellLayoutMode.compact : ShellLayoutMode.desktop;
    final contributions =
        panelRegistry ?? ShellPanelContributionRegistry.defaultIdePanels();
    final activePrimaryRoute =
        _panelRegion(activeWorkbenchRoute) == ShellLayoutRegion.primarySidebar
        ? activeWorkbenchRoute
        : BottomSurfaceTab.navigate;
    final panels = <ShellPanelDescriptor>[
      const ShellPanelDescriptor(
        id: 'top-bar',
        title: 'Top Bar',
        region: ShellLayoutRegion.topBar,
        visible: true,
      ),
      ShellPanelDescriptor(
        id: 'activity-rail',
        title: 'Activity Rail',
        region: ShellLayoutRegion.activityRail,
        visible: !compact,
        metadata: const <String, Object?>{
          'compactFallbackSurfaceId': 'compact-workbench-navigation',
        },
      ),
      const ShellPanelDescriptor(
        id: 'editor',
        title: 'Editor',
        region: ShellLayoutRegion.editor,
        visible: true,
        active: true,
      ),
      for (final contribution in contributions.contributions)
        if (contribution.region == ShellLayoutRegion.primarySidebar)
          contribution
              .toPanelDescriptor(activeWorkbenchRoute: activeWorkbenchRoute)
              .copyWith(visible: contribution.route == activePrimaryRoute)
        else
          contribution.toPanelDescriptor(
            activeWorkbenchRoute: activeWorkbenchRoute,
          ),
      const ShellPanelDescriptor(
        id: 'status-bar',
        title: 'Status Bar',
        region: ShellLayoutRegion.statusBar,
        visible: true,
      ),
    ];
    return ShellLayoutPlan(
      mode: mode,
      activeWorkbenchRoute: activeWorkbenchRoute,
      panels: panels,
    );
  }

  final ShellLayoutMode mode;
  final BottomSurfaceTab activeWorkbenchRoute;
  final List<ShellPanelDescriptor> panels;
  final String todo;

  ShellLayoutPlan copyWith({
    ShellLayoutMode? mode,
    BottomSurfaceTab? activeWorkbenchRoute,
    List<ShellPanelDescriptor>? panels,
    String? todo,
  }) {
    return ShellLayoutPlan(
      mode: mode ?? this.mode,
      activeWorkbenchRoute: activeWorkbenchRoute ?? this.activeWorkbenchRoute,
      panels: panels ?? this.panels,
      todo: todo ?? this.todo,
    );
  }

  ShellPanelDescriptor? panelById(String id) {
    for (final panel in panels) {
      if (panel.id == id) {
        return panel;
      }
    }
    return null;
  }

  List<String> get visiblePanelIds {
    return panels
        .where((panel) => panel.visible)
        .map((panel) => panel.id)
        .toList(growable: false);
  }

  ShellLayoutRenderBinding renderBinding() {
    return ShellLayoutRenderBinding.fromPlan(this);
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'mode': mode.wireValue,
      'activeWorkbenchRoute': activeWorkbenchRoute.name,
      'visiblePanelIds': visiblePanelIds,
      'panels': panels.map((panel) => panel.toJson()).toList(growable: false),
      if (todo.isNotEmpty) 'todo': todo,
    };
  }
}

/// Maps each workbench route to the IDE capability entry that owns its
/// maturity. Routes without an entry are reported as scaffolded instead of
/// claiming production readiness.
String? _routeCapabilityId(BottomSurfaceTab tab) {
  return switch (tab) {
    BottomSurfaceTab.runtime => 'presentation.output-panel',
    BottomSurfaceTab.terminal => 'runtime.terminal',
    BottomSurfaceTab.commands ||
    BottomSurfaceTab.commandPalette => 'interaction.command-palette',
    BottomSurfaceTab.navigate => 'workspace.file-explorer',
    BottomSurfaceTab.quickOpen => 'interaction.search',
    BottomSurfaceTab.outline => 'service.styio-language',
    BottomSurfaceTab.search ||
    BottomSurfaceTab.locations => 'interaction.search',
    BottomSurfaceTab.problems => 'presentation.problems-panel',
    BottomSurfaceTab.testing => 'interaction.testing',
    BottomSurfaceTab.debug => 'debugger.dap',
    BottomSurfaceTab.agent => 'agent.workbench',
    BottomSurfaceTab.sourceControl => 'interaction.source-control',
    BottomSurfaceTab.extensions => 'extension.marketplace',
    BottomSurfaceTab.observable => 'service.observable-topology',
    BottomSurfaceTab.settings => 'toolchain.manager',
    // Language-navigation routes have no wired shell surface yet. They stay
    // unmapped so their panel contributions report scaffolded instead of
    // borrowing another capability's readiness.
    _ => null,
  };
}

List<ShellPanelContribution> _defaultPanelContributions() {
  final capabilityById = <String, IdeCapabilityDescriptor>{
    for (final entry in const VityoIdeCapabilityFramework().snapshot().entries)
      entry.id: entry,
  };
  return BottomSurfaceTab.values
      .map((tab) {
        final region = _panelRegion(tab);
        final panelId = _panelId(tab);
        final capabilityId = _routeCapabilityId(tab);
        final capability = capabilityId == null
            ? null
            : capabilityById[capabilityId];
        final metadata = <String, Object?>{
          'coreIdePanel': ShellPanelContributionRegistry.coreIdePanelIds
              .contains(panelId),
          if (capabilityId != null) 'capabilityId': capabilityId,
        };
        return ShellPanelContribution.routedPanel(
          id: panelId,
          title: _routeTitle(tab),
          region: region,
          surfaceId: _routeSurfaceId(tab),
          capabilities: _routeCapabilities(tab),
          status: _panelStatusFromCapability(capability),
          route: tab,
          metadata: metadata,
          todo: capability?.todo ?? _missingPanelCapabilityTodo(tab),
        );
      })
      .toList(growable: false);
}

ShellPanelContributionStatus _panelStatusFromCapability(
  IdeCapabilityDescriptor? capability,
) {
  if (capability == null) {
    return ShellPanelContributionStatus.scaffolded;
  }
  return switch (capability.status) {
    IdeCapabilityStatus.ready => ShellPanelContributionStatus.production,
    IdeCapabilityStatus.wired => ShellPanelContributionStatus.wired,
    IdeCapabilityStatus.scaffolded ||
    IdeCapabilityStatus.todo => ShellPanelContributionStatus.scaffolded,
  };
}

String _missingPanelCapabilityTodo(BottomSurfaceTab tab) {
  return 'TODO: no IDE capability entry owns the ${tab.name} workbench route yet.';
}

class ShellLayoutPreferences {
  const ShellLayoutPreferences({
    required this.workspaceId,
    this.activeWorkbenchRoute = BottomSurfaceTab.navigate,
    this.hiddenPanelIds = const <String>{},
    this.pinnedPanelIds = const <String>{},
    this.primarySidebarVisible = true,
    this.primarySidebarWidth = defaultPrimarySidebarWidth,
    this.bottomPanelExpanded = false,
    this.bottomPanelHeight = defaultBottomPanelHeight,
    this.updatedAt,
  });

  static const double minPrimarySidebarWidth = 196;
  static const double maxPrimarySidebarWidth = 480;
  static const double defaultPrimarySidebarWidth = 240;
  static const double minBottomPanelHeight = 132;
  static const double maxBottomPanelHeight = 560;
  static const double defaultBottomPanelHeight = 220;

  factory ShellLayoutPreferences.fromJson(Map<String, Object?> json) {
    return ShellLayoutPreferences(
      workspaceId: json['workspaceId'] as String? ?? '',
      activeWorkbenchRoute: _routeFromWire(json['activeWorkbenchRoute']),
      hiddenPanelIds: _jsonStringSet(json['hiddenPanelIds']),
      pinnedPanelIds: _jsonStringSet(json['pinnedPanelIds']),
      primarySidebarVisible: json['primarySidebarVisible'] as bool? ?? true,
      primarySidebarWidth: _normalizedDimension(
        json['primarySidebarWidth'],
        fallback: defaultPrimarySidebarWidth,
        minimum: minPrimarySidebarWidth,
        maximum: maxPrimarySidebarWidth,
      ),
      bottomPanelExpanded: json['bottomPanelExpanded'] as bool? ?? false,
      bottomPanelHeight: _normalizedDimension(
        json['bottomPanelHeight'],
        fallback: defaultBottomPanelHeight,
        minimum: minBottomPanelHeight,
        maximum: maxBottomPanelHeight,
      ),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '')?.toUtc(),
    );
  }

  final String workspaceId;
  final BottomSurfaceTab activeWorkbenchRoute;
  final Set<String> hiddenPanelIds;
  final Set<String> pinnedPanelIds;
  final bool primarySidebarVisible;
  final double primarySidebarWidth;
  final bool bottomPanelExpanded;
  final double bottomPanelHeight;
  final DateTime? updatedAt;

  ShellLayoutPreferences copyWith({
    String? workspaceId,
    BottomSurfaceTab? activeWorkbenchRoute,
    Set<String>? hiddenPanelIds,
    Set<String>? pinnedPanelIds,
    bool? primarySidebarVisible,
    double? primarySidebarWidth,
    bool? bottomPanelExpanded,
    double? bottomPanelHeight,
    DateTime? updatedAt,
  }) {
    return ShellLayoutPreferences(
      workspaceId: workspaceId ?? this.workspaceId,
      activeWorkbenchRoute: activeWorkbenchRoute ?? this.activeWorkbenchRoute,
      hiddenPanelIds: hiddenPanelIds ?? this.hiddenPanelIds,
      pinnedPanelIds: pinnedPanelIds ?? this.pinnedPanelIds,
      primarySidebarVisible:
          primarySidebarVisible ?? this.primarySidebarVisible,
      primarySidebarWidth: primarySidebarWidth ?? this.primarySidebarWidth,
      bottomPanelExpanded: bottomPanelExpanded ?? this.bottomPanelExpanded,
      bottomPanelHeight: bottomPanelHeight ?? this.bottomPanelHeight,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  ShellLayoutPlan applyTo(ShellLayoutPlan plan) {
    final activePrimaryRoute =
        _panelRegion(activeWorkbenchRoute) == ShellLayoutRegion.primarySidebar
        ? activeWorkbenchRoute
        : BottomSurfaceTab.navigate;
    return plan.copyWith(
      activeWorkbenchRoute: activeWorkbenchRoute,
      panels: plan.panels
          .map((panel) {
            final routeName = panel.metadata['route'] as String?;
            final routeVisible = switch (panel.region) {
              ShellLayoutRegion.primarySidebar =>
                routeName == activePrimaryRoute.name,
              ShellLayoutRegion.bottomPanel =>
                routeName == activeWorkbenchRoute.name,
              _ => panel.visible,
            };
            final metadata = <String, Object?>{
              ...panel.metadata,
              if (pinnedPanelIds.contains(panel.id)) 'pinned': true,
              if (panel.region == ShellLayoutRegion.primarySidebar)
                'primarySidebarWidth': primarySidebarWidth,
              if (panel.region ==
                  ShellLayoutRegion.bottomPanel) ...<String, Object?>{
                'bottomPanelExpanded': bottomPanelExpanded,
                'bottomPanelHeight': bottomPanelHeight,
              },
            };
            return panel.copyWith(
              visible:
                  (panel.region == ShellLayoutRegion.primarySidebar &&
                          !primarySidebarVisible) ||
                      hiddenPanelIds.contains(panel.id)
                  ? false
                  : routeVisible,
              active: routeName != null
                  ? routeName == activeWorkbenchRoute.name
                  : panel.active,
              metadata: metadata,
            );
          })
          .toList(growable: false),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'workspaceId': workspaceId,
      'activeWorkbenchRoute': activeWorkbenchRoute.name,
      'hiddenPanelIds': _sortedStrings(hiddenPanelIds),
      'pinnedPanelIds': _sortedStrings(pinnedPanelIds),
      'primarySidebarVisible': primarySidebarVisible,
      'primarySidebarWidth': primarySidebarWidth,
      'bottomPanelExpanded': bottomPanelExpanded,
      'bottomPanelHeight': bottomPanelHeight,
      if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
    };
  }
}

class ShellLayoutPreferencesStore {
  ShellLayoutPreferencesStore.fromDataStore({
    required FoundationDataStore dataStore,
  }) : this(
         owner: FoundationDataStoreOwner(
           descriptor: const FoundationDataStoreOwnerDescriptor(
             ownerId: 'presentation.shell-layout-preferences',
             layer: 'presentation',
             stateFamily: 'shell-layout',
             allowedNamespaces: <String>{_namespaceName},
           ),
           dataStore: dataStore,
         ),
       );

  const ShellLayoutPreferencesStore({required FoundationDataStoreOwner owner})
    : _owner = owner;

  static const int schemaVersion = 1;
  static const String _namespaceName = 'presentation.shell-layout';
  static const String _key = 'preferences';

  final FoundationDataStoreOwner _owner;

  Future<void> savePreferences(ShellLayoutPreferences preferences) {
    return _owner.writeJson(
      namespaceName: _namespaceName,
      key: _key,
      value: preferences.copyWith(updatedAt: DateTime.now().toUtc()).toJson(),
      schemaVersion: schemaVersion,
      scope: FoundationResourceScope.workspace,
      workspaceId: preferences.workspaceId,
    );
  }

  Future<ShellLayoutPreferences> readPreferences({
    required String workspaceId,
  }) async {
    final value = await _owner.readJson(
      namespaceName: _namespaceName,
      key: _key,
      schemaVersion: schemaVersion,
      scope: FoundationResourceScope.workspace,
      workspaceId: workspaceId,
    );
    if (value == null) {
      return ShellLayoutPreferences(workspaceId: workspaceId);
    }
    final preferences = ShellLayoutPreferences.fromJson(value);
    return preferences.workspaceId.isEmpty
        ? preferences.copyWith(workspaceId: workspaceId)
        : preferences;
  }

  Future<bool> deletePreferences({required String workspaceId}) {
    return _owner.delete(
      namespaceName: _namespaceName,
      key: _key,
      schemaVersion: schemaVersion,
      scope: FoundationResourceScope.workspace,
      workspaceId: workspaceId,
    );
  }

  Stream<FoundationDataStoreChange> watchPreferences({
    required String workspaceId,
  }) {
    return _owner.watchJson(
      namespaceName: _namespaceName,
      key: _key,
      schemaVersion: schemaVersion,
      scope: FoundationResourceScope.workspace,
      workspaceId: workspaceId,
    );
  }
}

class ShellLayoutPreferenceController {
  ShellLayoutPreferenceController({
    required ShellLayoutPreferences initialPreferences,
  }) : _preferences = initialPreferences;

  ShellLayoutPreferences _preferences;
  int _revision = 0;

  ShellLayoutPreferences get preferences => _preferences;

  int get revision => _revision;

  Future<void> loadFromStore(
    ShellLayoutPreferencesStore store, {
    required String workspaceId,
  }) async {
    hydrate(await store.readPreferences(workspaceId: workspaceId));
  }

  Future<void> saveToStore(ShellLayoutPreferencesStore store) {
    return store.savePreferences(_preferences);
  }

  void hydrate(ShellLayoutPreferences preferences) {
    _setPreferences(preferences);
  }

  void selectWorkbenchRoute(BottomSurfaceTab tab) {
    if (_preferences.activeWorkbenchRoute == tab) {
      return;
    }
    _setPreferences(_preferences.copyWith(activeWorkbenchRoute: tab));
  }

  void setPanelVisible(String panelId, {required bool visible}) {
    final hiddenPanelIds = <String>{..._preferences.hiddenPanelIds};
    final changed = visible
        ? hiddenPanelIds.remove(panelId)
        : hiddenPanelIds.add(panelId);
    if (!changed) {
      return;
    }
    _setPreferences(_preferences.copyWith(hiddenPanelIds: hiddenPanelIds));
  }

  void setPanelPinned(String panelId, {required bool pinned}) {
    final pinnedPanelIds = <String>{..._preferences.pinnedPanelIds};
    final changed = pinned
        ? pinnedPanelIds.add(panelId)
        : pinnedPanelIds.remove(panelId);
    if (!changed) {
      return;
    }
    _setPreferences(_preferences.copyWith(pinnedPanelIds: pinnedPanelIds));
  }

  bool setPrimarySidebarVisible(bool visible) {
    if (_preferences.primarySidebarVisible == visible) {
      return false;
    }
    _setPreferences(_preferences.copyWith(primarySidebarVisible: visible));
    return true;
  }

  bool setPrimarySidebarWidth(double width) {
    final normalized = width
        .clamp(
          ShellLayoutPreferences.minPrimarySidebarWidth,
          ShellLayoutPreferences.maxPrimarySidebarWidth,
        )
        .toDouble();
    if ((_preferences.primarySidebarWidth - normalized).abs() < 0.5) {
      return false;
    }
    _setPreferences(_preferences.copyWith(primarySidebarWidth: normalized));
    return true;
  }

  bool setBottomPanelExpanded(bool expanded) {
    if (_preferences.bottomPanelExpanded == expanded) {
      return false;
    }
    _setPreferences(_preferences.copyWith(bottomPanelExpanded: expanded));
    return true;
  }

  bool setBottomPanelHeight(double height) {
    final normalized = height
        .clamp(
          ShellLayoutPreferences.minBottomPanelHeight,
          ShellLayoutPreferences.maxBottomPanelHeight,
        )
        .toDouble();
    if ((_preferences.bottomPanelHeight - normalized).abs() < 0.5) {
      return false;
    }
    _setPreferences(_preferences.copyWith(bottomPanelHeight: normalized));
    return true;
  }

  ShellLayoutPlan planForViewport({required bool compact}) {
    return _preferences.applyTo(
      ShellLayoutPlan.forViewport(
        activeWorkbenchRoute: _preferences.activeWorkbenchRoute,
        compact: compact,
      ),
    );
  }

  ShellLayoutRenderBinding renderBindingForViewport({required bool compact}) {
    return planForViewport(compact: compact).renderBinding();
  }

  void _setPreferences(ShellLayoutPreferences preferences) {
    _preferences = preferences.copyWith(updatedAt: DateTime.now().toUtc());
    _revision += 1;
  }
}

class ShellLayoutRenderBinding {
  const ShellLayoutRenderBinding({
    required this.mode,
    required this.viewportKey,
    required this.activePanelId,
    required this.visiblePanelIds,
    required this.primarySidebarVisible,
    required this.primarySidebarWidth,
    required this.bottomPanelExpanded,
    required this.bottomPanelHeight,
    required this.compactActivityFallback,
  });

  factory ShellLayoutRenderBinding.fromPlan(ShellLayoutPlan plan) {
    ShellPanelDescriptor? activePanel;
    for (final panel in plan.panels) {
      if (panel.metadata['route'] == plan.activeWorkbenchRoute.name) {
        activePanel = panel;
        break;
      }
    }
    ShellPanelDescriptor? primarySidebar;
    for (final panel in plan.panels) {
      if (panel.region == ShellLayoutRegion.primarySidebar &&
          (panel.metadata['route'] == plan.activeWorkbenchRoute.name ||
              panel.metadata['route'] == BottomSurfaceTab.navigate.name)) {
        primarySidebar = panel;
        if (panel.metadata['route'] == plan.activeWorkbenchRoute.name) {
          break;
        }
      }
    }
    ShellPanelDescriptor? bottomLayoutPanel;
    for (final panel in plan.panels) {
      if (panel.region == ShellLayoutRegion.bottomPanel) {
        bottomLayoutPanel = panel;
        break;
      }
    }
    final viewportKey = plan.mode == ShellLayoutMode.compact
        ? 'shell-viewport-mobile'
        : 'shell-viewport-${plan.mode.wireValue}';
    return ShellLayoutRenderBinding(
      mode: plan.mode,
      viewportKey: viewportKey,
      activePanelId: activePanel?.id ?? 'editor',
      visiblePanelIds: plan.visiblePanelIds,
      primarySidebarVisible: primarySidebar?.visible ?? false,
      primarySidebarWidth:
          primarySidebar?.metadata['primarySidebarWidth'] as double? ??
          ShellLayoutPreferences.defaultPrimarySidebarWidth,
      bottomPanelExpanded:
          bottomLayoutPanel?.metadata['bottomPanelExpanded'] as bool? ?? false,
      bottomPanelHeight:
          bottomLayoutPanel?.metadata['bottomPanelHeight'] as double? ??
          ShellLayoutPreferences.defaultBottomPanelHeight,
      compactActivityFallback:
          plan.panelById('activity-rail')?.visible == false &&
          plan.mode == ShellLayoutMode.compact,
    );
  }

  final ShellLayoutMode mode;
  final String viewportKey;
  final String activePanelId;
  final List<String> visiblePanelIds;
  final bool primarySidebarVisible;
  final double primarySidebarWidth;
  final bool bottomPanelExpanded;
  final double bottomPanelHeight;
  final bool compactActivityFallback;

  bool isPanelVisible(String panelId) {
    return visiblePanelIds.contains(panelId);
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'mode': mode.wireValue,
      'viewportKey': viewportKey,
      'activePanelId': activePanelId,
      'visiblePanelIds': visiblePanelIds,
      'primarySidebarVisible': primarySidebarVisible,
      'primarySidebarWidth': primarySidebarWidth,
      'bottomPanelExpanded': bottomPanelExpanded,
      'bottomPanelHeight': bottomPanelHeight,
      'compactActivityFallback': compactActivityFallback,
    };
  }
}

ShellLayoutMode _modeFromWire(Object? value) {
  return switch (value) {
    'desktop' => ShellLayoutMode.desktop,
    'compact' => ShellLayoutMode.compact,
    _ => ShellLayoutMode.desktop,
  };
}

ShellLayoutRegion _regionFromWire(Object? value) {
  return switch (value) {
    'top-bar' => ShellLayoutRegion.topBar,
    'activity-rail' => ShellLayoutRegion.activityRail,
    'primary-sidebar' => ShellLayoutRegion.primarySidebar,
    'editor' => ShellLayoutRegion.editor,
    'bottom-panel' => ShellLayoutRegion.bottomPanel,
    'auxiliary-panel' => ShellLayoutRegion.auxiliaryPanel,
    'status-bar' => ShellLayoutRegion.statusBar,
    _ => ShellLayoutRegion.editor,
  };
}

BottomSurfaceTab _routeFromWire(Object? value) {
  final name = value as String? ?? '';
  for (final tab in BottomSurfaceTab.values) {
    if (tab.name == name) {
      return tab;
    }
  }
  return BottomSurfaceTab.navigate;
}

String _routeTitle(BottomSurfaceTab tab) {
  return switch (tab) {
    BottomSurfaceTab.runtime => 'Runtime',
    BottomSurfaceTab.terminal => 'Terminal',
    BottomSurfaceTab.commands ||
    BottomSurfaceTab.commandPalette => 'Command Palette',
    BottomSurfaceTab.agent => 'Agent',
    BottomSurfaceTab.sourceControl => 'Source Control',
    BottomSurfaceTab.search => 'Search',
    BottomSurfaceTab.problems => 'Problems',
    BottomSurfaceTab.testing => 'Testing',
    BottomSurfaceTab.observable => 'Observable',
    BottomSurfaceTab.extensions => 'Extensions',
    BottomSurfaceTab.debug => 'Debug',
    BottomSurfaceTab.navigate => 'Navigate',
    BottomSurfaceTab.quickOpen => 'Quick Open',
    BottomSurfaceTab.outline => 'Outline',
    BottomSurfaceTab.settings => 'Settings',
    BottomSurfaceTab.locations => 'Locations',
    _ => '',
  };
}

String _routeSurfaceId(BottomSurfaceTab tab) {
  return switch (tab) {
    BottomSurfaceTab.runtime => 'runtime.output',
    BottomSurfaceTab.terminal => 'terminal.session',
    BottomSurfaceTab.commands ||
    BottomSurfaceTab.commandPalette => 'commands.palette',
    BottomSurfaceTab.agent => 'agent.activity',
    BottomSurfaceTab.sourceControl => 'source-control.changes',
    BottomSurfaceTab.search => 'workspace.search',
    BottomSurfaceTab.problems => 'workspace.problems',
    BottomSurfaceTab.testing => 'testing.results',
    BottomSurfaceTab.observable => 'observable.graph',
    BottomSurfaceTab.extensions => 'extensions.marketplace',
    BottomSurfaceTab.debug => 'debug.console',
    BottomSurfaceTab.navigate => 'navigate.quick',
    BottomSurfaceTab.quickOpen => 'navigate.quick',
    BottomSurfaceTab.outline => 'workspace.outline',
    BottomSurfaceTab.settings => 'settings.workspace',
    BottomSurfaceTab.locations => 'locations.list',
    _ => '',
  };
}

List<String> _routeCapabilities(BottomSurfaceTab tab) {
  return switch (tab) {
    BottomSurfaceTab.runtime => const <String>[
      'runtime-output',
      'task-activity',
    ],
    BottomSurfaceTab.terminal => const <String>['terminal', 'pty-session'],
    BottomSurfaceTab.commands || BottomSurfaceTab.commandPalette =>
      const <String>['command-search', 'command-execution'],
    BottomSurfaceTab.agent => const <String>[
      'agent-activity',
      'coding-session-history',
    ],
    BottomSurfaceTab.sourceControl => const <String>[
      'source-control',
      'diff-preview',
    ],
    BottomSurfaceTab.search => const <String>[
      'workspace-search',
      'replace-preview',
    ],
    BottomSurfaceTab.problems => const <String>['diagnostics', 'quick-fix'],
    BottomSurfaceTab.testing => const <String>[
      'test-results',
      'failed-test-debug',
    ],
    BottomSurfaceTab.observable => const <String>[
      'observable-topology',
      'change-highlight',
    ],
    BottomSurfaceTab.extensions => const <String>[
      'extension-management',
      'marketplace',
    ],
    BottomSurfaceTab.debug => const <String>['debug-console', 'debug-session'],
    BottomSurfaceTab.navigate || BottomSurfaceTab.quickOpen => const <String>[
      'quick-navigate',
      'fuzzy-file-search',
    ],
    BottomSurfaceTab.outline => const <String>['outline', 'document-symbols'],
    BottomSurfaceTab.settings => const <String>[
      'settings',
      'toolchain-configuration',
    ],
    _ => const <String>[],
  };
}

ShellLayoutRegion _panelRegion(BottomSurfaceTab tab) {
  return switch (tab) {
    BottomSurfaceTab.navigate ||
    BottomSurfaceTab.quickOpen ||
    BottomSurfaceTab.search ||
    BottomSurfaceTab.sourceControl ||
    BottomSurfaceTab.extensions ||
    BottomSurfaceTab.settings => ShellLayoutRegion.primarySidebar,
    _ => ShellLayoutRegion.bottomPanel,
  };
}

String _panelId(BottomSurfaceTab tab) {
  if (tab == BottomSurfaceTab.navigate) {
    return 'primary.explorer';
  }
  return switch (_panelRegion(tab)) {
    ShellLayoutRegion.primarySidebar => 'primary.${tab.name}',
    _ => 'bottom.${tab.name}',
  };
}

List<ShellPanelDescriptor> _jsonPanels(Object? value) {
  if (value is! List) {
    return const <ShellPanelDescriptor>[];
  }
  return value
      .whereType<Map>()
      .map(
        (panel) => ShellPanelDescriptor.fromJson(
          panel.map(
            (key, value) => MapEntry<String, Object?>(key.toString(), value),
          ),
        ),
      )
      .toList(growable: false);
}

Map<String, Object?> _jsonObjectMap(Object? value) {
  if (value is! Map) {
    return const <String, Object?>{};
  }
  return Map<String, Object?>.unmodifiable(
    value.map((key, value) => MapEntry<String, Object?>(key.toString(), value)),
  );
}

Set<String> _jsonStringSet(Object? value) {
  if (value is! List) {
    return const <String>{};
  }
  return Set<String>.unmodifiable(
    value.whereType<String>().where((item) => item.trim().isNotEmpty),
  );
}

List<String> _sortedStrings(Iterable<String> values) {
  final sorted = values.toList(growable: false)..sort();
  return sorted;
}

double _normalizedDimension(
  Object? value, {
  required double fallback,
  required double minimum,
  required double maximum,
}) {
  final number = value is num ? value.toDouble() : fallback;
  return number.clamp(minimum, maximum).toDouble();
}
