import 'package:flutter/material.dart';

import '../../view_ide/module_host/module_host.dart';
import '../../view_ide/runtime/runtime.dart';
import '../platform/viewport_profile.dart';

class ExtensionsSurface extends StatelessWidget {
  const ExtensionsSurface({
    super.key,
    required this.viewportProfile,
    required this.visibleModules,
    required this.mountedModules,
    this.moduleStates = const <ModuleLifecycleState>[],
    this.activationSession,
    this.supervisorSnapshot,
    this.launchResults = const <ExtensionHostSandboxLaunchResult>[],
    this.telemetryEvents = const <ExtensionHostSupervisorTelemetryEvent>[],
    this.marketplaceIndex,
    this.installedExtensionRegistry,
    this.marketplaceQuery = '',
    this.marketplaceMessage = '',
    this.marketplaceBusy = false,
    this.lastMarketplaceInstallResult,
    this.onRefreshModules,
    this.onRefreshMarketplace,
    this.onMarketplaceQueryChanged,
    this.onEnableModule,
    this.onDisableModule,
    this.onTrustModule,
    this.onInstallExtension,
    this.onUpdateExtension,
  });

  final ViewportProfile viewportProfile;
  final List<ModuleDefinition> visibleModules;
  final List<ModuleDefinition> mountedModules;
  final List<ModuleLifecycleState> moduleStates;
  final ExtensionActivationSession? activationSession;
  final ExtensionHostSupervisorSnapshot? supervisorSnapshot;
  final List<ExtensionHostSandboxLaunchResult> launchResults;
  final List<ExtensionHostSupervisorTelemetryEvent> telemetryEvents;
  final ExtensionMarketplaceIndex? marketplaceIndex;
  final ExtensionManifestRegistry? installedExtensionRegistry;
  final String marketplaceQuery;
  final String marketplaceMessage;
  final bool marketplaceBusy;
  final ExtensionMarketplaceInstallExecutionResult?
  lastMarketplaceInstallResult;
  final Future<void> Function()? onRefreshModules;
  final Future<void> Function()? onRefreshMarketplace;
  final ValueChanged<String>? onMarketplaceQueryChanged;
  final Future<void> Function(String moduleId)? onEnableModule;
  final Future<void> Function(String moduleId)? onDisableModule;
  final Future<void> Function(String moduleId)? onTrustModule;
  final Future<void> Function(ExtensionInstallPlan plan)? onInstallExtension;
  final Future<void> Function(ExtensionMarketplaceUpdatePlan plan)?
  onUpdateExtension;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = viewportProfile.isMobile;
    final mountedIds = mountedModules
        .map((module) => module.manifest.moduleId)
        .toSet();
    final statesById = <String, ModuleLifecycleState>{
      for (final state in moduleStates) state.moduleId: state,
    };
    final installedRegistry =
        installedExtensionRegistry ??
        _installedExtensionRegistry(visibleModules);
    final marketplaceListings =
        marketplaceIndex?.search(marketplaceQuery) ??
        const <ExtensionMarketplaceListing>[];
    final disabledCount = visibleModules.where((module) {
      final state =
          statesById[module.manifest.moduleId] ??
          defaultModuleLifecycleState(module);
      return !state.enabled;
    }).length;
    final untrustedCount = visibleModules.where((module) {
      final state =
          statesById[module.manifest.moduleId] ??
          defaultModuleLifecycleState(module);
      return !state.trusted;
    }).length;

    return Card(
      key: const ValueKey('extensions-surface'),
      child: Padding(
        padding: EdgeInsets.all(compact ? 14 : 18),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Extensions', style: theme.textTheme.titleLarge),
              const SizedBox(height: 6),
              Text(
                'Manage installed modules, inspect extension-host activation, and review verified marketplace packages.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  Chip(label: Text('visible ${visibleModules.length}')),
                  Chip(label: Text('mounted ${mountedModules.length}')),
                  Chip(label: Text('disabled $disabledCount')),
                  Chip(label: Text('untrusted $untrustedCount')),
                  if (marketplaceIndex != null)
                    Chip(
                      label: Text('marketplace ${marketplaceListings.length}'),
                    ),
                  if (marketplaceQuery.trim().isNotEmpty)
                    Chip(label: Text('query ${marketplaceQuery.trim()}')),
                ],
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const ValueKey('extensions-refresh-modules'),
                onPressed: onRefreshModules,
                icon: const Icon(Icons.extension_rounded),
                label: const Text('Refresh Modules'),
              ),
              const SizedBox(height: 12),
              if (activationSession != null || supervisorSnapshot != null) ...[
                _ExtensionActivationTelemetry(
                  activationSession: activationSession,
                  supervisorSnapshot: supervisorSnapshot,
                  launchResults: launchResults,
                  telemetryEvents: telemetryEvents,
                ),
                const SizedBox(height: 12),
              ],
              if (marketplaceIndex != null) ...[
                _MarketplaceStatus(
                  message: marketplaceMessage,
                  busy: marketplaceBusy,
                  configured: onRefreshMarketplace != null,
                  lastResult: lastMarketplaceInstallResult,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Marketplace',
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    IconButton.filledTonal(
                      key: const ValueKey('extensions-marketplace-refresh'),
                      tooltip: 'Refresh marketplace index',
                      onPressed: marketplaceBusy ? null : onRefreshMarketplace,
                      icon: const Icon(Icons.sync_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextFormField(
                  key: const ValueKey('extensions-marketplace-search'),
                  initialValue: marketplaceQuery,
                  onChanged: onMarketplaceQueryChanged,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search_rounded),
                    hintText: 'Search extensions',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                if (marketplaceListings.isEmpty)
                  Text(
                    marketplaceMessage.isEmpty
                        ? 'No marketplace extensions match this query.'
                        : marketplaceMessage,
                    style: theme.textTheme.bodySmall,
                  )
                else
                  Column(
                    key: const ValueKey('extensions-marketplace-list'),
                    children: [
                      for (final listing in marketplaceListings.take(6))
                        _ExtensionMarketplaceCard(
                          listing: listing,
                          installPlan: marketplaceIndex!.installPlan(
                            installedRegistry: installedRegistry,
                            extensionId: listing.extensionId,
                          ),
                          updatePlan:
                              ExtensionMarketplaceUpdatePlan.fromListing(
                                listing: listing,
                                installedRegistry: installedRegistry,
                              ),
                          busy: marketplaceBusy,
                          onInstallExtension: onInstallExtension,
                          onUpdateExtension: onUpdateExtension,
                        ),
                    ],
                  ),
                const SizedBox(height: 12),
              ],
              Text('Installed Modules', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              if (visibleModules.isEmpty)
                Text(
                  'No visible modules are registered for this platform.',
                  style: theme.textTheme.bodySmall,
                )
              else
                Column(
                  key: const ValueKey('extensions-module-list'),
                  children: [
                    for (final module in visibleModules)
                      _ExtensionModuleCard(
                        module: module,
                        mounted: mountedIds.contains(module.manifest.moduleId),
                        state:
                            statesById[module.manifest.moduleId] ??
                            defaultModuleLifecycleState(module),
                        onEnableModule: onEnableModule,
                        onDisableModule: onDisableModule,
                        onTrustModule: onTrustModule,
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExtensionActivationTelemetry extends StatelessWidget {
  const _ExtensionActivationTelemetry({
    required this.activationSession,
    required this.supervisorSnapshot,
    required this.launchResults,
    required this.telemetryEvents,
  });

  final ExtensionActivationSession? activationSession;
  final ExtensionHostSupervisorSnapshot? supervisorSnapshot;
  final List<ExtensionHostSandboxLaunchResult> launchResults;
  final List<ExtensionHostSupervisorTelemetryEvent> telemetryEvents;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = supervisorSnapshot;
    final running = snapshot?.runningExtensionIds.length ?? 0;
    final blocked = snapshot?.blockedExtensionIds.length ?? 0;
    final failed = snapshot?.failedExtensionIds.length ?? 0;
    final launchByExtension = <String, ExtensionHostSandboxLaunchResult>{
      for (final result in launchResults) result.request.extensionId: result,
    };

    return Container(
      key: const ValueKey('extensions-activation-hosts'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: ExpansionTile(
        key: const ValueKey('extensions-activation-telemetry-toggle'),
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Icon(
          failed == 0 ? Icons.hub_outlined : Icons.error_outline_rounded,
          color: failed == 0
              ? theme.colorScheme.primary
              : theme.colorScheme.error,
        ),
        title: const Text('Activation & Hosts'),
        subtitle: Text(
          'event ${activationSession?.event ?? 'not recorded'} · '
          '$running running · $blocked blocked${failed == 0 ? '' : ' · $failed failed'}',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        children: [
          if (activationSession != null) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                key: const ValueKey('extensions-activation-summary'),
                spacing: 8,
                runSpacing: 8,
                children: [
                  Chip(
                    label: Text(
                      'activated '
                      '${activationSession!.activatedExtensionIds.length}',
                    ),
                  ),
                  Chip(
                    label: Text(
                      'trust blocked '
                      '${activationSession!.blockedExtensionIds.length}',
                    ),
                  ),
                  Chip(label: Text('launches ${launchResults.length}')),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
          if (snapshot == null || snapshot.records.isEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'No extension hosts were planned for this activation event.',
                style: theme.textTheme.bodySmall,
              ),
            )
          else
            Column(
              key: const ValueKey('extensions-host-list'),
              children: [
                for (final record in snapshot.records)
                  _ExtensionHostRecord(
                    record: record,
                    launch: launchByExtension[record.extensionId],
                  ),
              ],
            ),
          if (telemetryEvents.isNotEmpty) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Activation timeline',
                style: theme.textTheme.labelLarge,
              ),
            ),
            const SizedBox(height: 6),
            Column(
              key: const ValueKey('extensions-activation-timeline'),
              children: [
                for (final event in telemetryEvents.reversed.take(12))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Icon(
                          event.status == ExtensionHostSupervisorStatus.failed
                              ? Icons.cancel_outlined
                              : Icons.check_circle_outline_rounded,
                          size: 16,
                          color:
                              event.status ==
                                  ExtensionHostSupervisorStatus.failed
                              ? theme.colorScheme.error
                              : theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            '${event.extensionId} · ${event.status.wireValue} '
                            '· ${event.mode.wireValue}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ExtensionHostRecord extends StatelessWidget {
  const _ExtensionHostRecord({required this.record, required this.launch});

  final ExtensionHostSupervisorRecord record;
  final ExtensionHostSandboxLaunchResult? launch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = record.status == ExtensionHostSupervisorStatus.failed;
    return Container(
      key: ValueKey('extensions-host-${record.extensionId}'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                failed ? Icons.warning_amber_rounded : Icons.memory_rounded,
                size: 18,
                color: failed
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  record.extensionId,
                  style: theme.textTheme.labelLarge,
                ),
              ),
              Text(
                record.status.wireValue,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: failed
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(record.message, style: theme.textTheme.bodySmall),
          const SizedBox(height: 7),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              Chip(label: Text(record.plan.mode.wireValue)),
              Chip(label: Text(record.action.wireValue)),
              if (launch?.launcher != null)
                Chip(label: Text(launch!.launcher!.label)),
              if (launch?.processHandleId.isNotEmpty == true ||
                  launch?.pid != null)
                const Chip(label: Text('managed process')),
            ],
          ),
        ],
      ),
    );
  }
}

ExtensionManifestRegistry _installedExtensionRegistry(
  List<ModuleDefinition> modules,
) {
  final manifests = <ExtensionManifest>[];
  for (final module in modules) {
    final manifest = ExtensionManifest.fromModuleManifest(
      module: module.manifest,
      publisher: 'vityo',
    );
    if (manifest.valid) {
      manifests.add(manifest);
    }
  }
  return ExtensionManifestRegistry(manifests);
}

class _MarketplaceStatus extends StatelessWidget {
  const _MarketplaceStatus({
    required this.message,
    required this.busy,
    required this.configured,
    required this.lastResult,
  });

  final String message;
  final bool busy;
  final bool configured;
  final ExtensionMarketplaceInstallExecutionResult? lastResult;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = lastResult;
    final succeeded = result?.installed == true;
    return Container(
      key: const ValueKey('extensions-marketplace-status'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: succeeded
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (busy)
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(
              succeeded
                  ? Icons.verified_rounded
                  : configured
                  ? Icons.cloud_outlined
                  : Icons.settings_outlined,
              size: 19,
              color: succeeded
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              result?.message ??
                  (message.isEmpty
                      ? 'Marketplace is ready for configuration.'
                      : message),
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _ExtensionMarketplaceCard extends StatelessWidget {
  const _ExtensionMarketplaceCard({
    required this.listing,
    required this.installPlan,
    required this.updatePlan,
    required this.busy,
    required this.onInstallExtension,
    required this.onUpdateExtension,
  });

  final ExtensionMarketplaceListing listing;
  final ExtensionInstallPlan installPlan;
  final ExtensionMarketplaceUpdatePlan updatePlan;
  final bool busy;
  final Future<void> Function(ExtensionInstallPlan plan)? onInstallExtension;
  final Future<void> Function(ExtensionMarketplaceUpdatePlan plan)?
  onUpdateExtension;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final manifest = listing.manifest;
    final executionPlan = const ExtensionMarketplaceInstaller().planExecution(
      installPlan,
    );
    return Container(
      key: ValueKey('extensions-marketplace-${listing.extensionId}'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.cloud_download_outlined),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  manifest.displayName,
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${manifest.extensionId} · ${manifest.version} · ${manifest.publisher}',
            style: theme.textTheme.bodySmall,
          ),
          if (listing.summary.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(listing.summary, style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(label: Text(listing.verified ? 'verified' : 'unverified')),
              Chip(
                label: Text(
                  listing.hasPackageIntegrity ? 'SHA-256' : 'no digest',
                ),
              ),
              Chip(label: Text(installPlan.status.wireValue)),
              if (installPlan.ready)
                Chip(
                  label: Text('execution ${executionPlan.status.wireValue}'),
                ),
              if (installPlan.ready)
                Chip(label: Text('steps ${executionPlan.steps.length}')),
              for (final category in listing.categories.take(3))
                Chip(label: Text(category)),
              if (!updatePlan.canUpdate)
                FilledButton.tonal(
                  key: ValueKey('extensions-install-${listing.extensionId}'),
                  onPressed:
                      !busy && installPlan.ready && onInstallExtension != null
                      ? () => _confirmInstall(context)
                      : null,
                  child: Text(
                    installPlan.ready
                        ? 'Install'
                        : installPlan.status ==
                              ExtensionInstallPlanStatus.alreadyInstalled
                        ? 'Installed'
                        : 'Blocked',
                  ),
                ),
              if (updatePlan.canUpdate)
                FilledButton.tonalIcon(
                  key: ValueKey('extensions-update-${listing.extensionId}'),
                  onPressed: !busy && onUpdateExtension != null
                      ? () => _confirmUpdate(context)
                      : null,
                  icon: const Icon(Icons.system_update_alt_rounded),
                  label: Text('Update to ${listing.manifest.version}'),
                ),
            ],
          ),
          if (executionPlan.steps.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              key: ValueKey(
                'extensions-install-execution-${listing.extensionId}',
              ),
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final step in executionPlan.steps.take(5))
                  Chip(
                    label: Text(
                      '${step.kind.wireValue} ${step.ready ? 'ready' : 'blocked'}',
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmInstall(BuildContext context) async {
    final confirmed = await _confirmPackageOperation(
      context,
      title: 'Install ${listing.manifest.displayName}?',
      actionLabel: 'Install verified package',
    );
    if (confirmed && context.mounted) {
      await onInstallExtension?.call(installPlan);
    }
  }

  Future<void> _confirmUpdate(BuildContext context) async {
    final confirmed = await _confirmPackageOperation(
      context,
      title: 'Update ${listing.manifest.displayName}?',
      actionLabel: 'Update verified package',
    );
    if (confirmed && context.mounted) {
      await onUpdateExtension?.call(updatePlan);
    }
  }

  Future<bool> _confirmPackageOperation(
    BuildContext context, {
    required String title,
    required String actionLabel,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            key: const ValueKey('extensions-marketplace-confirmation'),
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${listing.manifest.publisher} · ${listing.manifest.version}',
                ),
                const SizedBox(height: 8),
                Text(
                  listing.installVerified
                      ? 'Publisher verification and SHA-256 integrity metadata are present.'
                      : 'This package does not satisfy install verification.',
                ),
                const SizedBox(height: 8),
                SelectableText(
                  listing.expectedSha256.isEmpty
                      ? 'SHA-256 unavailable'
                      : listing.expectedSha256,
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const ValueKey(
                  'extensions-marketplace-confirmation-confirm',
                ),
                onPressed: listing.installVerified
                    ? () => Navigator.of(dialogContext).pop(true)
                    : null,
                child: Text(actionLabel),
              ),
            ],
          ),
        ) ??
        false;
  }
}

class _ExtensionModuleCard extends StatelessWidget {
  const _ExtensionModuleCard({
    required this.module,
    required this.mounted,
    required this.state,
    required this.onEnableModule,
    required this.onDisableModule,
    required this.onTrustModule,
  });

  final ModuleDefinition module;
  final bool mounted;
  final ModuleLifecycleState state;
  final Future<void> Function(String moduleId)? onEnableModule;
  final Future<void> Function(String moduleId)? onDisableModule;
  final Future<void> Function(String moduleId)? onTrustModule;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final manifest = module.manifest;
    return Container(
      key: ValueKey('extensions-module-${manifest.moduleId}'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                mounted ? Icons.extension_rounded : Icons.extension_off_rounded,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  manifest.displayName,
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${manifest.moduleId} · ${manifest.version} · ${manifest.kind.name} · ${manifest.slot.name}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(label: Text(mounted ? 'mounted' : 'visible')),
              Chip(label: Text(state.enabled ? 'enabled' : 'disabled')),
              Chip(label: Text(state.trustState.wireValue)),
              if (state.updateAvailable) const Chip(label: Text('update')),
              if (manifest.kind == ModuleKind.core)
                const Chip(label: Text('product managed'))
              else if (state.enabled)
                TextButton(
                  key: ValueKey('extensions-disable-${manifest.moduleId}'),
                  onPressed: onDisableModule == null
                      ? null
                      : () {
                          onDisableModule!(manifest.moduleId);
                        },
                  child: const Text('Disable'),
                )
              else
                TextButton(
                  key: ValueKey('extensions-enable-${manifest.moduleId}'),
                  onPressed: onEnableModule == null
                      ? null
                      : () {
                          onEnableModule!(manifest.moduleId);
                        },
                  child: const Text('Enable'),
                ),
              if (!state.trusted)
                TextButton(
                  key: ValueKey('extensions-trust-${manifest.moduleId}'),
                  onPressed: onTrustModule == null
                      ? null
                      : () {
                          onTrustModule!(manifest.moduleId);
                        },
                  child: const Text('Trust'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
