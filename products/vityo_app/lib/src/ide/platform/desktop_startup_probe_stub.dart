import 'package:flutter/widgets.dart';

import 'desktop_startup_probe_contract.dart';

/// Web and other non-IO targets retain the normal launch without desktop IO.
void runDesktopStartupProbe(List<String> arguments, Widget app) {
  if (DesktopStartupProbeRequest.parse(arguments) != null) {
    throw UnsupportedError('Vityo startup probing requires a desktop process.');
  }
  runApp(app);
}
