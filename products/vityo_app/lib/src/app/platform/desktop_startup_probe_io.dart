import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'desktop_startup_probe_contract.dart';

/// Launches the requested app and exits a probe process after verified startup.
void runDesktopStartupProbe(List<String> arguments, Widget app) {
  final DesktopStartupProbeRequest? request;
  try {
    request = DesktopStartupProbeRequest.parse(arguments);
  } on FormatException {
    stderr.writeln('Invalid Vityo startup probe arguments.');
    exit(64);
  }

  if (request == null) {
    runApp(app);
    return;
  }

  final binding = WidgetsFlutterBinding.ensureInitialized();
  var completed = false;

  void failStartup() {
    if (completed) {
      return;
    }
    completed = true;
    stderr.writeln('Vityo startup probe failed.');
    exit(1);
  }

  FlutterError.onError = (_) => failStartup();
  PlatformDispatcher.instance.onError = (_, __) {
    failStartup();
    return true;
  };

  final firstFrameRasterized = binding.waitUntilFirstFrameRasterized;
  try {
    runApp(app);
  } catch (_) {
    failStartup();
    return;
  }

  unawaited(
    _recordFirstFrameAndExit(
      request,
      firstFrameRasterized: firstFrameRasterized,
      onFailure: failStartup,
      onSuccess: () {
        if (completed) {
          return;
        }
        completed = true;
        exit(0);
      },
    ),
  );
}

Future<void> _recordFirstFrameAndExit(
  DesktopStartupProbeRequest request, {
  required Future<void> firstFrameRasterized,
  required void Function() onFailure,
  required void Function() onSuccess,
}) async {
  try {
    await request.recordAfterFirstFrame(
      firstFrameRasterized: firstFrameRasterized,
      platform: Platform.operatingSystem,
      writeEvidence: (evidence) async {
        final target = File(request.evidenceFile);
        await target.parent.create(recursive: true);
        await target.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(evidence)}\n',
          flush: true,
        );
      },
    );
  } catch (_) {
    onFailure();
    return;
  }
  onSuccess();
}
