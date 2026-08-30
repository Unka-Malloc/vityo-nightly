import 'package:flutter/material.dart';

import '../../view_ide/backend_toolchain/execution_adapter.dart';
import '../../view_ide/debugger/debug_adapter_launcher.dart';
import '../../view_ide/debugger/debug_launch_contract.dart';
import '../../view_ide/debugger/debug_launch_telemetry_store.dart';
import '../../view_ide/runtime/runtime_execution_plan.dart';
import '../platform/viewport_profile.dart';
import '../../view_ide/runtime/runtime_replay_summary.dart';
import '../../view_ide/shell_runtime/shell_runtime.dart';

class DebugConsoleSurface extends StatelessWidget {
  const DebugConsoleSurface({
    super.key,
    required this.viewportProfile,
    required this.entries,
    required this.runtimeEvents,
    this.debugSession = const DebugSessionSnapshot(
      status: DebugSessionStatus.idle,
      message: 'No debug session has been started.',
    ),
    this.debugLaunchPlan,
    this.debugTelemetry,
    this.debugRuntimeExecution,
    this.debugLaunchConfigurations = const DebugLaunchConfigurationSet(
      workspaceId: '',
    ),
    this.onStartDebugging,
    this.onRetryDebugLaunch,
    this.onStopDebugging,
    this.onContinueDebugging,
    this.onStepOver,
    this.onForceStopDebugging,
    this.onSelectLaunchProfile,
    this.onUpdateLaunchConfiguration,
    this.onSaveBreakpoint,
    this.onRemoveBreakpoint,
    this.onSetBreakpointEnabled,
    this.onSelectStackFrame,
    this.onSelectThread,
  });

  final ViewportProfile viewportProfile;
  final List<String> entries;
  final List<RuntimeEventEnvelope> runtimeEvents;
  final DebugSessionSnapshot debugSession;
  final DapDebugAdapterExecutionPlan? debugLaunchPlan;
  final DebugLaunchTelemetrySnapshot? debugTelemetry;
  final DebugRuntimeExecutionResult? debugRuntimeExecution;
  final DebugLaunchConfigurationSet debugLaunchConfigurations;
  final Future<void> Function()? onStartDebugging;
  final Future<void> Function()? onRetryDebugLaunch;
  final Future<void> Function()? onStopDebugging;
  final Future<void> Function()? onContinueDebugging;
  final Future<void> Function()? onStepOver;
  final Future<void> Function()? onForceStopDebugging;
  final Future<DebugCommandResult> Function(String profileId)?
  onSelectLaunchProfile;
  final Future<DebugCommandResult> Function({
    required String programPath,
    required String cwd,
    required List<String> arguments,
    required bool stopOnEntry,
  })?
  onUpdateLaunchConfiguration;
  final Future<DebugCommandResult> Function({
    DebugBreakpoint? previous,
    required String filePath,
    required int line,
    required bool enabled,
  })?
  onSaveBreakpoint;
  final Future<DebugCommandResult> Function(DebugBreakpoint breakpoint)?
  onRemoveBreakpoint;
  final Future<DebugCommandResult> Function(
    DebugBreakpoint breakpoint,
    bool enabled,
  )?
  onSetBreakpointEnabled;
  final ValueChanged<String>? onSelectStackFrame;
  final ValueChanged<String>? onSelectThread;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final latestRuntimeEvent = runtimeEvents.isEmpty
        ? null
        : runtimeEvents.last;
    final latestEntry = latestRuntimeEvent == null
        ? null
        : formatRuntimeEvent(latestRuntimeEvent);
    final replay = summarizeRuntimeReplay(runtimeEvents);
    final graph = summarizeRuntimeGraph(runtimeEvents);
    final debugLanes = summarizeRuntimeDebugLanes(runtimeEvents);
    final debugDigest = summarizeRuntimeDebugDigest(debugLanes);
    final replayFamilies = replay.families;
    final replayWindow = runtimeEvents.isEmpty
        ? 'No runtime replay window yet.'
        : 'window ${formatRuntimeClock(runtimeEvents.first.timestamp)} -> ${formatRuntimeClock(runtimeEvents.last.timestamp)}';
    final latestLine =
        latestEntry ??
        (entries.isEmpty ? 'No host events yet.' : entries.first);
    final combinedEntries = <String>[
      ...runtimeEvents.reversed.map(formatRuntimeEvent),
      ...entries,
    ];

    return Card(
      key: ValueKey('debug-surface-${viewportProfile.label.toLowerCase()}'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (viewportProfile.isMobile)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Debug Console', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    'Compact development log aligned to the mobile shell.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      Chip(label: Text('host ${entries.length}')),
                      Chip(label: Text('runtime ${runtimeEvents.length}')),
                      Chip(label: Text('${replayFamilies.length} family')),
                      Chip(label: Text(viewportProfile.label)),
                    ],
                  ),
                ],
              )
            else
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Debug Console',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Desktop development log slot fed by shell logs plus published runtime-event replay.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      Chip(label: Text('host ${entries.length}')),
                      Chip(label: Text('runtime ${runtimeEvents.length}')),
                      Chip(label: Text('${replayFamilies.length} family')),
                    ],
                  ),
                ],
              ),
            const SizedBox(height: 14),
            Expanded(
              child: ListView(
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: viewportProfile.isMobile ? 180 : 120,
                    ),
                    child: SingleChildScrollView(
                      child: Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              latestLine,
                              style: theme.textTheme.bodySmall,
                              maxLines: viewportProfile.isMobile ? 3 : 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              replayWindow,
                              style: theme.textTheme.bodySmall,
                            ),
                            if (replayFamilies.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                'families ${replayFamilies.join(', ')}',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                            if (graph.routeNodes.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                graph.summarySentence,
                                style: theme.textTheme.bodySmall,
                              ),
                              if (graph.routeTraceLabel != null) ...[
                                const SizedBox(height: 6),
                                Text(
                                  'route ${graph.routeTraceLabel!}',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                              ...graph.nodeDetails
                                  .take(3)
                                  .map(
                                    (detail) => Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'node ${detail.label}: ${detail.filterLabel}',
                                            style: theme.textTheme.bodySmall,
                                          ),
                                          if (detail.timelineLabel != null)
                                            Text(
                                              'timeline ${detail.timelineLabel!}',
                                              style: theme.textTheme.bodySmall,
                                            ),
                                          if (detail.relationLabel != null)
                                            Text(
                                              'relations ${detail.relationLabel!}',
                                              style: theme.textTheme.bodySmall,
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ...graph.edgeDetails
                                  .take(2)
                                  .map(
                                    (detail) => Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'edge ${detail.label}: ${detail.filterLabel}',
                                            style: theme.textTheme.bodySmall,
                                          ),
                                          if (detail.timelineLabel != null)
                                            Text(
                                              'timeline ${detail.timelineLabel!}',
                                              style: theme.textTheme.bodySmall,
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                            ],
                            if (debugDigest != null) ...[
                              const SizedBox(height: 6),
                              Text(
                                'debug $debugDigest',
                                style: theme.textTheme.bodySmall,
                              ),
                              ...debugLanes.map(
                                (lane) => Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${lane.title}: ${lane.traceLabel ?? lane.latestEventKind}${lane.detailLabel == null ? '' : ' · ${lane.detailLabel!}'}',
                                        style: theme.textTheme.bodySmall,
                                      ),
                                      Text(
                                        'filter ${lane.filterLabel}',
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (debugLaunchPlan != null ||
                      debugTelemetry != null ||
                      debugRuntimeExecution != null) ...[
                    _DebugLaunchPlanSection(
                      plan: debugLaunchPlan ?? debugRuntimeExecution?.plan,
                      telemetry:
                          debugTelemetry ?? debugRuntimeExecution?.telemetry,
                      execution: debugRuntimeExecution,
                      onRetryDebugLaunch:
                          onRetryDebugLaunch ?? onStartDebugging,
                    ),
                    const SizedBox(height: 14),
                  ],
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: viewportProfile.isMobile ? 420 : 380,
                    ),
                    child: SingleChildScrollView(
                      child: _DebuggerSessionSection(
                        session: debugSession,
                        launchConfigurations: debugLaunchConfigurations,
                        onStartDebugging: onStartDebugging,
                        onStopDebugging: onStopDebugging,
                        onContinueDebugging: onContinueDebugging,
                        onStepOver: onStepOver,
                        onForceStopDebugging: onForceStopDebugging,
                        onSelectLaunchProfile: onSelectLaunchProfile,
                        onUpdateLaunchConfiguration:
                            onUpdateLaunchConfiguration,
                        onSaveBreakpoint: onSaveBreakpoint,
                        onRemoveBreakpoint: onRemoveBreakpoint,
                        onSetBreakpointEnabled: onSetBreakpointEnabled,
                        onSelectStackFrame: onSelectStackFrame,
                        onSelectThread: onSelectThread,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: viewportProfile.isMobile ? 220 : 160,
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: const Color(0xFF29282B),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      padding: const EdgeInsets.all(14),
                      child: combinedEntries.isEmpty
                          ? const Center(
                              child: Text(
                                'No debug output yet.',
                                key: ValueKey('debug-output-empty'),
                                style: TextStyle(
                                  color: Color(0xFFB8B5BD),
                                  fontFamily: 'monospace',
                                ),
                              ),
                            )
                          : ListView.separated(
                              reverse: false,
                              itemCount: combinedEntries.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (context, index) {
                                return Text(
                                  combinedEntries[index],
                                  style: const TextStyle(
                                    color: Color(0xFFF2F0EC),
                                    height: 1.35,
                                    fontFamily: 'monospace',
                                  ),
                                );
                              },
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DebugLaunchPlanSection extends StatelessWidget {
  const _DebugLaunchPlanSection({
    this.plan,
    this.telemetry,
    this.execution,
    this.onRetryDebugLaunch,
  });

  final DapDebugAdapterExecutionPlan? plan;
  final DebugLaunchTelemetrySnapshot? telemetry;
  final DebugRuntimeExecutionResult? execution;
  final Future<void> Function()? onRetryDebugLaunch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final latestRecord = telemetry?.records.isEmpty == false
        ? telemetry!.records.first
        : null;
    final executionResult = execution;
    final canRetryExecution =
        executionResult != null &&
        (executionResult.blocked || executionResult.failed) &&
        onRetryDebugLaunch != null;
    return Container(
      key: const ValueKey('debug-launch-plan-section'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Debug Launch Plan', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (plan != null) ...[
                Chip(label: Text('profile ${plan!.profileId}')),
                Chip(label: Text('plan ${plan!.status.wireValue}')),
                Chip(label: Text('ready ${plan!.ready}')),
                Chip(label: Text('route ${plan!.routePlan.status.wireValue}')),
              ],
              if (telemetry != null) ...[
                Chip(label: Text('telemetry ${telemetry!.records.length}')),
                Chip(label: Text('blocked ${telemetry!.blockedCount}')),
                Chip(label: Text('successful ${telemetry!.successfulCount}')),
              ],
              if (executionResult != null) ...[
                Chip(
                  label: Text('execution ${executionResult.status.wireValue}'),
                ),
                Chip(
                  label: Text(
                    'dispatch ${executionResult.dispatchResult.status.wireValue}',
                  ),
                ),
                Chip(
                  label: Text('output ${executionResult.outputEvents.length}'),
                ),
              ],
            ],
          ),
          if (plan != null) ...[
            const SizedBox(height: 8),
            Text(
              plan!.message,
              key: const ValueKey('debug-launch-plan-message'),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              'adapter ${plan!.launchConfiguration.debuggerLabel} · program ${plan!.launchConfiguration.programPath ?? 'not selected'}',
              key: const ValueKey('debug-launch-plan-adapter'),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              'output ${plan!.outputBinding.outputChannel.id}',
              key: const ValueKey('debug-launch-plan-output'),
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (latestRecord != null) ...[
            const SizedBox(height: 8),
            Text(
              'latest ${latestRecord.status.wireValue} · ${latestRecord.message}',
              key: const ValueKey('debug-launch-telemetry-latest'),
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (executionResult != null) ...[
            const SizedBox(height: 8),
            Text(
              'execution ${executionResult.status.wireValue} · ${executionResult.dispatchResult.message}',
              key: const ValueKey('debug-runtime-execution-message'),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              'runtime output ${executionResult.outputEvents.length} event(s)',
              key: const ValueKey('debug-runtime-execution-output'),
              style: theme.textTheme.bodySmall,
            ),
            if (executionResult.processHandle case final processHandle?) ...[
              const SizedBox(height: 4),
              Text(
                'process ${processHandle.processHandleId}${processHandle.pid == null ? '' : ' · pid ${processHandle.pid}'}',
                key: const ValueKey('debug-process-identity'),
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (canRetryExecution) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                key: const ValueKey('debug-runtime-retry-launch'),
                onPressed: () async {
                  await onRetryDebugLaunch!();
                },
                child: const Text('Retry Launch'),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _DebuggerSessionSection extends StatelessWidget {
  const _DebuggerSessionSection({
    required this.session,
    required this.launchConfigurations,
    this.onStartDebugging,
    this.onStopDebugging,
    this.onContinueDebugging,
    this.onStepOver,
    this.onForceStopDebugging,
    this.onSelectLaunchProfile,
    this.onUpdateLaunchConfiguration,
    this.onSaveBreakpoint,
    this.onRemoveBreakpoint,
    this.onSetBreakpointEnabled,
    this.onSelectStackFrame,
    this.onSelectThread,
  });

  final DebugSessionSnapshot session;
  final DebugLaunchConfigurationSet launchConfigurations;
  final Future<void> Function()? onStartDebugging;
  final Future<void> Function()? onStopDebugging;
  final Future<void> Function()? onContinueDebugging;
  final Future<void> Function()? onStepOver;
  final Future<void> Function()? onForceStopDebugging;
  final Future<DebugCommandResult> Function(String profileId)?
  onSelectLaunchProfile;
  final Future<DebugCommandResult> Function({
    required String programPath,
    required String cwd,
    required List<String> arguments,
    required bool stopOnEntry,
  })?
  onUpdateLaunchConfiguration;
  final Future<DebugCommandResult> Function({
    DebugBreakpoint? previous,
    required String filePath,
    required int line,
    required bool enabled,
  })?
  onSaveBreakpoint;
  final Future<DebugCommandResult> Function(DebugBreakpoint breakpoint)?
  onRemoveBreakpoint;
  final Future<DebugCommandResult> Function(
    DebugBreakpoint breakpoint,
    bool enabled,
  )?
  onSetBreakpointEnabled;
  final ValueChanged<String>? onSelectStackFrame;
  final ValueChanged<String>? onSelectThread;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final breakpoints = session.breakpoints;
    final threads = session.threads;
    final frames = session.stackFrames;
    final variables = session.variables;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Debugger Session', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'status ${session.status.name}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(session.message, style: theme.textTheme.bodySmall),
          if (session.debuggerLabel != null) ...[
            const SizedBox(height: 4),
            Text(
              'debugger ${session.debuggerLabel}',
              style: theme.textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 8),
          _DebugConfigurationEditor(
            configurations: launchConfigurations,
            onSelectProfile: onSelectLaunchProfile,
            onUpdateConfiguration: onUpdateLaunchConfiguration,
          ),
          const SizedBox(height: 10),
          _DebugControlStrip(
            session: session,
            onStartDebugging: onStartDebugging,
            onStopDebugging: onStopDebugging,
            onContinueDebugging: onContinueDebugging,
            onStepOver: onStepOver,
            onForceStopDebugging: onForceStopDebugging,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Breakpoints · ${breakpoints.length}',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              TextButton.icon(
                key: const ValueKey('debug-add-breakpoint'),
                onPressed: onSaveBreakpoint == null
                    ? null
                    : () => _showBreakpointEditor(
                        context,
                        onSave: onSaveBreakpoint!,
                      ),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add'),
              ),
            ],
          ),
          if (breakpoints.isEmpty)
            Text('No breakpoints.', style: theme.textTheme.bodySmall),
          ...breakpoints.map(
            (breakpoint) => Row(
              key: ValueKey('debug-breakpoint-${breakpoint.key}'),
              children: [
                Checkbox(
                  key: ValueKey('debug-breakpoint-enabled-${breakpoint.key}'),
                  value: breakpoint.enabled,
                  visualDensity: VisualDensity.compact,
                  onChanged: onSetBreakpointEnabled == null
                      ? null
                      : (enabled) {
                          if (enabled != null) {
                            onSetBreakpointEnabled!(breakpoint, enabled);
                          }
                        },
                ),
                Expanded(
                  child: Text(
                    '${breakpoint.filePath}:${breakpoint.line + 1}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: breakpoint.enabled
                          ? null
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  key: ValueKey('debug-breakpoint-edit-${breakpoint.key}'),
                  tooltip: 'Edit breakpoint',
                  visualDensity: VisualDensity.compact,
                  onPressed: onSaveBreakpoint == null
                      ? null
                      : () => _showBreakpointEditor(
                          context,
                          breakpoint: breakpoint,
                          onSave: onSaveBreakpoint!,
                        ),
                  icon: const Icon(Icons.edit_outlined, size: 16),
                ),
                IconButton(
                  key: ValueKey('debug-breakpoint-remove-${breakpoint.key}'),
                  tooltip: 'Remove breakpoint',
                  visualDensity: VisualDensity.compact,
                  onPressed: onRemoveBreakpoint == null
                      ? null
                      : () => onRemoveBreakpoint!(breakpoint),
                  icon: const Icon(Icons.close, size: 16),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text('Threads', style: theme.textTheme.titleSmall),
          if (threads.isEmpty)
            Text('No threads captured.', style: theme.textTheme.bodySmall)
          else
            ...threads
                .take(6)
                .map(
                  (thread) => Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: GestureDetector(
                      key: ValueKey('debug-thread-${thread.id}'),
                      behavior: HitTestBehavior.opaque,
                      onTap: onSelectThread == null
                          ? null
                          : () => onSelectThread!(thread.id),
                      child: Text(
                        '${thread.id} · ${thread.name}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
                ),
          const SizedBox(height: 8),
          Text('Call Stack', style: theme.textTheme.titleSmall),
          if (frames.isEmpty)
            Text('No stack frames captured.', style: theme.textTheme.bodySmall)
          else
            ...frames
                .take(4)
                .map(
                  (frame) => Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: GestureDetector(
                      key: ValueKey('debug-stack-frame-${frame.id}'),
                      behavior: HitTestBehavior.opaque,
                      onTap: onSelectStackFrame == null
                          ? null
                          : () => onSelectStackFrame!(frame.id),
                      child: Text(
                        '${frame.name} · ${frame.filePath}:${frame.line + 1}:${frame.column + 1}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
                ),
          const SizedBox(height: 8),
          Text('Variables', style: theme.textTheme.titleSmall),
          if (variables.isEmpty)
            Text('No variables captured.', style: theme.textTheme.bodySmall)
          else
            ...variables
                .take(6)
                .map(
                  (variable) => Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      '${variable.name} = ${variable.value}${variable.type == null ? '' : ' : ${variable.type}'}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ),
        ],
      ),
    );
  }
}

class _DebugConfigurationEditor extends StatelessWidget {
  const _DebugConfigurationEditor({
    required this.configurations,
    this.onSelectProfile,
    this.onUpdateConfiguration,
  });

  final DebugLaunchConfigurationSet configurations;
  final Future<DebugCommandResult> Function(String profileId)? onSelectProfile;
  final Future<DebugCommandResult> Function({
    required String programPath,
    required String cwd,
    required List<String> arguments,
    required bool stopOnEntry,
  })?
  onUpdateConfiguration;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = configurations.selectedProfile;
    final profiles = configurations.profiles;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Launch Configuration', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        if (profiles.isEmpty)
          Text(
            'No DAP adapters are registered. Install a debugger extension or configure a debugger toolchain.',
            key: const ValueKey('debug-no-adapters'),
            style: theme.textTheme.bodySmall,
          )
        else ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: const ValueKey('debug-adapter-selector'),
                  initialValue: profile?.id,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'DAP adapter',
                    isDense: true,
                  ),
                  items: profiles
                      .map(
                        (candidate) => DropdownMenuItem<String>(
                          value: candidate.id,
                          child: Text(
                            '${candidate.displayName} · ${_debugProfileScope(candidate)}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: onSelectProfile == null
                      ? null
                      : (profileId) {
                          if (profileId != null) {
                            onSelectProfile!(profileId);
                          }
                        },
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                key: const ValueKey('debug-edit-launch-configuration'),
                onPressed: profile == null || onUpdateConfiguration == null
                    ? null
                    : () => _showLaunchConfigurationEditor(
                        context,
                        profile: profile,
                        onUpdate: onUpdateConfiguration!,
                      ),
                icon: const Icon(Icons.tune, size: 16),
                label: const Text('Configure'),
              ),
            ],
          ),
          if (profile != null) ...[
            const SizedBox(height: 6),
            Text(
              profile.configuration.programPath == null
                  ? profile.configuration.reason
                  : '${profile.configuration.programPath} · ${profile.configuration.cwd}',
              key: const ValueKey('debug-launch-configuration-summary'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: profile.configuration.ready
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ],
    );
  }
}

Future<void> _showLaunchConfigurationEditor(
  BuildContext context, {
  required DebugLaunchProfile profile,
  required Future<DebugCommandResult> Function({
    required String programPath,
    required String cwd,
    required List<String> arguments,
    required bool stopOnEntry,
  })
  onUpdate,
}) async {
  final configuration = profile.configuration;
  var programPath = configuration.programPath ?? '';
  var cwd = configuration.cwd;
  var argumentsText = configuration.arguments.join('\n');
  var stopOnEntry = configuration.stopOnEntry;
  String? errorText;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        title: Text('Configure ${profile.displayName}'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Adapter ${configuration.debuggerExecutablePath}',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('debug-launch-program-field'),
                  initialValue: programPath,
                  onChanged: (value) => programPath = value,
                  decoration: const InputDecoration(
                    labelText: 'Program',
                    hintText: '/workspace/build/app',
                  ),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  key: const ValueKey('debug-launch-cwd-field'),
                  initialValue: cwd,
                  onChanged: (value) => cwd = value,
                  decoration: const InputDecoration(
                    labelText: 'Working directory',
                  ),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  key: const ValueKey('debug-launch-arguments-field'),
                  initialValue: argumentsText,
                  onChanged: (value) => argumentsText = value,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'Program arguments',
                    helperText: 'One argument per line',
                  ),
                ),
                CheckboxListTile(
                  key: const ValueKey('debug-launch-stop-on-entry'),
                  contentPadding: EdgeInsets.zero,
                  value: stopOnEntry,
                  title: const Text('Stop on entry'),
                  onChanged: (value) {
                    setState(() => stopOnEntry = value ?? false);
                  },
                ),
                if (errorText != null)
                  Text(
                    errorText!,
                    style: TextStyle(
                      color: Theme.of(dialogContext).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('debug-launch-save'),
            onPressed: () async {
              final result = await onUpdate(
                programPath: programPath,
                cwd: cwd,
                arguments: argumentsText
                    .split('\n')
                    .map((argument) => argument.trim())
                    .where((argument) => argument.isNotEmpty)
                    .toList(growable: false),
                stopOnEntry: stopOnEntry,
              );
              if (!result.applied) {
                setState(() => errorText = result.message);
                return;
              }
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

Future<void> _showBreakpointEditor(
  BuildContext context, {
  DebugBreakpoint? breakpoint,
  required Future<DebugCommandResult> Function({
    DebugBreakpoint? previous,
    required String filePath,
    required int line,
    required bool enabled,
  })
  onSave,
}) async {
  var filePath = breakpoint?.filePath ?? '';
  var lineText = breakpoint == null ? '' : '${breakpoint.line + 1}';
  var enabled = breakpoint?.enabled ?? true;
  String? errorText;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        title: Text(breakpoint == null ? 'Add Breakpoint' : 'Edit Breakpoint'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const ValueKey('debug-breakpoint-path-field'),
                initialValue: filePath,
                onChanged: (value) => filePath = value,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'File path'),
              ),
              const SizedBox(height: 10),
              TextFormField(
                key: const ValueKey('debug-breakpoint-line-field'),
                initialValue: lineText,
                onChanged: (value) => lineText = value,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Line'),
              ),
              CheckboxListTile(
                key: const ValueKey('debug-breakpoint-enabled-field'),
                contentPadding: EdgeInsets.zero,
                value: enabled,
                title: const Text('Enabled'),
                onChanged: (value) {
                  setState(() => enabled = value ?? true);
                },
              ),
              if (errorText != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    errorText!,
                    style: TextStyle(
                      color: Theme.of(dialogContext).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('debug-breakpoint-save'),
            onPressed: () async {
              final displayLine = int.tryParse(lineText.trim());
              if (filePath.trim().isEmpty ||
                  displayLine == null ||
                  displayLine < 1) {
                setState(() {
                  errorText =
                      'Enter a file path and a line number of 1 or greater.';
                });
                return;
              }
              final result = await onSave(
                previous: breakpoint,
                filePath: filePath,
                line: displayLine - 1,
                enabled: enabled,
              );
              if (!result.applied) {
                setState(() => errorText = result.message);
                return;
              }
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

String _debugProfileScope(DebugLaunchProfile profile) {
  final languages = profile.metadata['languages'];
  if (languages is List) {
    final labels = languages
        .whereType<String>()
        .map((language) => language.trim())
        .where((language) => language.isNotEmpty)
        .toList(growable: false);
    if (labels.isNotEmpty) {
      return labels.join(', ');
    }
  }
  final debuggerType = profile.metadata['debuggerType'];
  if (debuggerType is String && debuggerType.trim().isNotEmpty) {
    return debuggerType.trim();
  }
  return 'DAP';
}

class _DebugControlStrip extends StatelessWidget {
  const _DebugControlStrip({
    required this.session,
    this.onStartDebugging,
    this.onStopDebugging,
    this.onContinueDebugging,
    this.onStepOver,
    this.onForceStopDebugging,
  });

  final DebugSessionSnapshot session;
  final Future<void> Function()? onStartDebugging;
  final Future<void> Function()? onStopDebugging;
  final Future<void> Function()? onContinueDebugging;
  final Future<void> Function()? onStepOver;
  final Future<void> Function()? onForceStopDebugging;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = session.status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Debug Controls', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _DebugControlButton(
              key: const ValueKey('debug-control-start'),
              label: 'Start',
              enabled: _canStartDebugging(status),
              onPressed: onStartDebugging,
            ),
            _DebugControlButton(
              key: const ValueKey('debug-control-continue'),
              label: 'Continue',
              enabled: _canContinueDebugging(status),
              onPressed: onContinueDebugging,
            ),
            _DebugControlButton(
              key: const ValueKey('debug-control-step-over'),
              label: 'Step Over',
              enabled: _canStepOver(status),
              onPressed: onStepOver,
            ),
            _DebugControlButton(
              key: const ValueKey('debug-control-stop'),
              label: 'Stop',
              enabled: _canStopDebugging(status),
              onPressed: onStopDebugging,
            ),
            _DebugForceStopButton(
              enabled: _canStopDebugging(status),
              onPressed: onForceStopDebugging,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'adapter ${session.adapterSessionStatus ?? 'not attached'} · '
          'pending ${session.adapterPendingRequestCount} · '
          'events ${session.adapterEventCount}',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _DebugControlButton extends StatelessWidget {
  const _DebugControlButton({
    super.key,
    required this.label,
    required this.enabled,
    required this.onPressed,
  });

  final String label;
  final bool enabled;
  final Future<void> Function()? onPressed;

  @override
  Widget build(BuildContext context) {
    final callback = onPressed;
    return OutlinedButton(
      onPressed: enabled && callback != null
          ? () async {
              await callback();
            }
          : null,
      child: Text(label),
    );
  }
}

class _DebugForceStopButton extends StatelessWidget {
  const _DebugForceStopButton({required this.enabled, this.onPressed});

  final bool enabled;
  final Future<void> Function()? onPressed;

  @override
  Widget build(BuildContext context) {
    final callback = onPressed;
    return OutlinedButton(
      key: const ValueKey('debug-control-force-stop'),
      onPressed: enabled && callback != null
          ? () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('Force stop debug adapter?'),
                  content: const Text(
                    'The adapter process will be terminated immediately. Use this only when normal Stop does not respond.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      key: const ValueKey('debug-force-stop-confirm'),
                      onPressed: () => Navigator.of(dialogContext).pop(true),
                      child: const Text('Force Stop'),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                await callback();
              }
            }
          : null,
      style: OutlinedButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.error,
      ),
      child: const Text('Force Stop'),
    );
  }
}

bool _canStartDebugging(DebugSessionStatus status) {
  return switch (status) {
    DebugSessionStatus.idle ||
    DebugSessionStatus.blocked ||
    DebugSessionStatus.configured ||
    DebugSessionStatus.stopped => true,
    DebugSessionStatus.launching ||
    DebugSessionStatus.running ||
    DebugSessionStatus.paused => false,
  };
}

bool _canStopDebugging(DebugSessionStatus status) {
  return switch (status) {
    DebugSessionStatus.configured ||
    DebugSessionStatus.launching ||
    DebugSessionStatus.running ||
    DebugSessionStatus.paused => true,
    DebugSessionStatus.idle ||
    DebugSessionStatus.blocked ||
    DebugSessionStatus.stopped => false,
  };
}

bool _canContinueDebugging(DebugSessionStatus status) {
  return status == DebugSessionStatus.paused;
}

bool _canStepOver(DebugSessionStatus status) {
  return status == DebugSessionStatus.paused;
}
