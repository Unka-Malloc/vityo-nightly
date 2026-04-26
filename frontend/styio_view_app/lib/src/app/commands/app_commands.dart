import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum AppCommandId {
  save,
  run,
  fetchDependencies,
  vendorDependencies,
  useActiveCompiler,
  pinActiveCompiler,
  clearPinnedCompiler,
  packProject,
  preparePublish,
  showRuntime,
  showAgent,
  showDebug,
  refreshModules,
  openSettings,
}

class AppCommandIntent extends Intent {
  const AppCommandIntent(this.commandId);

  final AppCommandId commandId;
}

class AppCommandDescriptor {
  const AppCommandDescriptor({
    required this.id,
    required this.label,
    required this.shortcutHint,
    required this.description,
    this.primary = false,
    this.shortcuts = const <ShortcutActivator>[],
  });

  final AppCommandId id;
  final String label;
  final String shortcutHint;
  final String description;
  final bool primary;
  final List<ShortcutActivator> shortcuts;
}

class StyioCommandRegistry {
  static const List<AppCommandDescriptor> commands = [
    AppCommandDescriptor(
      id: AppCommandId.save,
      label: 'Save',
      shortcutHint: 'Cmd/Ctrl+S',
      description: 'Persist the current workspace target.',
      shortcuts: <ShortcutActivator>[
        SingleActivator(LogicalKeyboardKey.keyS, control: true),
        SingleActivator(LogicalKeyboardKey.keyS, meta: true),
      ],
    ),
    AppCommandDescriptor(
      id: AppCommandId.run,
      label: 'Run',
      shortcutHint: 'Cmd/Ctrl+Enter',
      description: 'Run the active minimal compilable unit.',
      primary: true,
      shortcuts: <ShortcutActivator>[
        SingleActivator(LogicalKeyboardKey.enter, control: true),
        SingleActivator(LogicalKeyboardKey.enter, meta: true),
      ],
    ),
    AppCommandDescriptor(
      id: AppCommandId.fetchDependencies,
      label: 'Fetch',
      shortcutHint: 'Cmd/Ctrl+Shift+F',
      description: 'Materialize dependency sources into the local spio cache.',
      primary: true,
      shortcuts: <ShortcutActivator>[
        SingleActivator(LogicalKeyboardKey.keyF, control: true, shift: true),
        SingleActivator(LogicalKeyboardKey.keyF, meta: true, shift: true),
      ],
    ),
    AppCommandDescriptor(
      id: AppCommandId.vendorDependencies,
      label: 'Vendor',
      shortcutHint: 'Cmd/Ctrl+Shift+V',
      description: 'Materialize project-local vendored dependency snapshots.',
      primary: true,
      shortcuts: <ShortcutActivator>[
        SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true),
        SingleActivator(LogicalKeyboardKey.keyV, meta: true, shift: true),
      ],
    ),
    AppCommandDescriptor(
      id: AppCommandId.useActiveCompiler,
      label: 'Use Compiler',
      shortcutHint: 'Route',
      description:
          'Use the currently resolved compiler version as the managed spio compiler.',
    ),
    AppCommandDescriptor(
      id: AppCommandId.pinActiveCompiler,
      label: 'Pin Compiler',
      shortcutHint: 'Route',
      description:
          'Pin the currently resolved compiler version into spio-toolchain.toml.',
    ),
    AppCommandDescriptor(
      id: AppCommandId.clearPinnedCompiler,
      label: 'Clear Pin',
      shortcutHint: 'Route',
      description: 'Clear the current project toolchain pin.',
    ),
    AppCommandDescriptor(
      id: AppCommandId.packProject,
      label: 'Pack',
      shortcutHint: 'Route',
      description: 'Create a package archive for the active project.',
    ),
    AppCommandDescriptor(
      id: AppCommandId.preparePublish,
      label: 'Preflight',
      shortcutHint: 'Route',
      description: 'Run publish preflight for the active project.',
    ),
    AppCommandDescriptor(
      id: AppCommandId.showRuntime,
      label: 'Runtime',
      shortcutHint: 'Shift+1',
      description: 'Focus the runtime surface.',
      shortcuts: <ShortcutActivator>[
        SingleActivator(LogicalKeyboardKey.digit1, shift: true),
      ],
    ),
    AppCommandDescriptor(
      id: AppCommandId.showAgent,
      label: 'Agent',
      shortcutHint: 'Shift+2',
      description: 'Focus the agent surface.',
      shortcuts: <ShortcutActivator>[
        SingleActivator(LogicalKeyboardKey.digit2, shift: true),
      ],
    ),
    AppCommandDescriptor(
      id: AppCommandId.showDebug,
      label: 'Debug',
      shortcutHint: 'Shift+3',
      description: 'Focus the debug console.',
      shortcuts: <ShortcutActivator>[
        SingleActivator(LogicalKeyboardKey.digit3, shift: true),
      ],
    ),
    AppCommandDescriptor(
      id: AppCommandId.refreshModules,
      label: 'Refresh',
      shortcutHint: 'Cmd/Ctrl+R',
      description:
          'Refresh module host state, project graph, and toolchain contracts.',
      primary: true,
      shortcuts: <ShortcutActivator>[
        SingleActivator(LogicalKeyboardKey.keyR, control: true),
        SingleActivator(LogicalKeyboardKey.keyR, meta: true),
      ],
    ),
    AppCommandDescriptor(
      id: AppCommandId.openSettings,
      label: 'Settings',
      shortcutHint: 'Cmd/Ctrl+,',
      description: 'Open settings and profile routes.',
      shortcuts: <ShortcutActivator>[
        SingleActivator(LogicalKeyboardKey.comma, control: true),
        SingleActivator(LogicalKeyboardKey.comma, meta: true),
      ],
    ),
  ];

  static Iterable<AppCommandDescriptor> get primaryCommands =>
      commands.where((command) => command.primary);

  static Iterable<AppCommandDescriptor> get executionCommands => commands.where(
    (command) => switch (command.id) {
      AppCommandId.run => true,
      _ => false,
    },
  );

  static Iterable<AppCommandDescriptor> get dependencyCommands =>
      commands.where(
        (command) => switch (command.id) {
          AppCommandId.fetchDependencies ||
          AppCommandId.vendorDependencies => true,
          _ => false,
        },
      );

  static Iterable<AppCommandDescriptor> get toolchainCommands => commands.where(
    (command) => switch (command.id) {
      AppCommandId.useActiveCompiler ||
      AppCommandId.pinActiveCompiler ||
      AppCommandId.clearPinnedCompiler => true,
      _ => false,
    },
  );

  static Iterable<AppCommandDescriptor> get workflowCommands => commands.where(
    (command) => switch (command.id) {
      AppCommandId.run ||
      AppCommandId.fetchDependencies ||
      AppCommandId.vendorDependencies ||
      AppCommandId.useActiveCompiler ||
      AppCommandId.pinActiveCompiler ||
      AppCommandId.clearPinnedCompiler ||
      AppCommandId.packProject ||
      AppCommandId.preparePublish => true,
      _ => false,
    },
  );

  static Iterable<AppCommandDescriptor> get deploymentCommands =>
      commands.where(
        (command) => switch (command.id) {
          AppCommandId.packProject || AppCommandId.preparePublish => true,
          _ => false,
        },
      );

  static AppCommandDescriptor descriptorFor(AppCommandId id) =>
      commands.firstWhere((command) => command.id == id);

  static Map<ShortcutActivator, Intent> get shortcutIntents {
    final bindings = <ShortcutActivator, Intent>{};
    for (final command in commands) {
      for (final shortcut in command.shortcuts) {
        bindings[shortcut] = AppCommandIntent(command.id);
      }
    }
    return bindings;
  }
}
