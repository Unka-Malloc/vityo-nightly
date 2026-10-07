import 'package:flutter/widgets.dart';

import 'src/app/platform/desktop_startup_probe.dart' as startup_probe;
import 'src/view_ide/flow_hero/compile_acceptance.dart';
import 'src/view_render/flow_hero/flow_hero.dart';

/// Explicit no-Agent acceptance entrypoint. Use the same production UI and
/// runtime with new per-launch stores, a copied workspace and a private daemon.
/// The ordinary main.dart and any installed application remain unchanged.
Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final acceptance = await FlowHeroCompileAcceptance.create(
    workspaceFixture: const String.fromEnvironment(
      'VITYO_COMPILE_ACCEPTANCE_WORKSPACE',
    ),
    daemonExecutable: const String.fromEnvironment(
      'VITYO_COMPILE_ACCEPTANCE_DAEMON',
    ),
  );
  startup_probe.runDesktopStartupProbe(
    arguments,
    FlowHeroApp(
      runtime: acceptance.runtime,
      initialWorkspaceRoot: acceptance.workspaceRoot,
    ),
  );
}
