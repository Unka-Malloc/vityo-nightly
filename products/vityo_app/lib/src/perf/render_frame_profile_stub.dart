import 'package:vityo_app/src/app/app_bootstrap.dart';

/// Web has no process exit and no filesystem, so the diagnostic lane is absent.
Future<bool> prepareRenderFrameProfile(List<String> arguments) async => false;

/// No-op counterpart of the desktop diagnostic lane.
Future<void> runPreparedRenderFrameProfile({
  required AppBootstrap bootstrap,
}) async {}
