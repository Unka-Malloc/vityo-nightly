import 'package:flutter/widgets.dart';

import 'src/view_ide/flow_hero/runtime.dart';
import 'src/app/platform/desktop_startup_probe.dart' as startup_probe;
import 'src/view_render/flow_hero/flow_hero.dart';

/// Compose the Flow Hero feature runtime at the maintained app entry point.
/// Store restoration runs after the first frame; startup-probe launches use
/// the same composition as ordinary launches.
void main(List<String> arguments) {
  WidgetsFlutterBinding.ensureInitialized();
  final ProductionFlowHeroRuntime runtime = ProductionFlowHeroRuntime();
  startup_probe.runDesktopStartupProbe(
    arguments,
    FlowHeroApp(runtime: runtime),
  );
}
