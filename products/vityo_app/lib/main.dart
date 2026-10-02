import 'src/ide/platform/desktop_startup_probe.dart' as startup_probe;
import 'src/view_render/flow_hero/flow_hero.dart';

/// Launch the Flow Hero workbench, optionally recording isolated CI startup.
void main(List<String> arguments) {
  startup_probe.runDesktopStartupProbe(arguments, const FlowHeroApp());
}
