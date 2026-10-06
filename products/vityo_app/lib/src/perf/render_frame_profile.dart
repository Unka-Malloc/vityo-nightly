import 'package:vityo_app/src/app/app_bootstrap.dart';

import 'render_frame_profile_stub.dart'
    if (dart.library.io) 'render_frame_profile_io.dart'
    as implementation;

/// Opt-in render frame-time profile mode.
///
/// Returns true when the diagnostic run was requested and the project root has
/// been redirected to the fixture workspace. Must be awaited before
/// `AppBootstrap.load` so the workspace root override is already in place.
Future<bool> prepareRenderFrameProfile(List<String> arguments) {
  return implementation.prepareRenderFrameProfile(arguments);
}

/// Runs the prepared render frame-time profile after `runApp`.
///
/// No-ops when [prepareRenderFrameProfile] did not request a run. Writes the
/// receipt, then terminates the process so a scripted before/after pair can be
/// collected without an attached debugger.
Future<void> runPreparedRenderFrameProfile({
  required AppBootstrap bootstrap,
}) {
  return implementation.runPreparedRenderFrameProfile(bootstrap: bootstrap);
}
