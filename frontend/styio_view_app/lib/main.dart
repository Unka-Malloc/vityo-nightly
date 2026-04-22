import 'package:flutter/widgets.dart';

import 'src/frontend_shell/frontend_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final bootstrap = await AppBootstrap.load();
  runApp(StyioViewApp(bootstrap: bootstrap));
}
