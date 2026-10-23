/// Typed outcomes shared by Flow Hero's install controller and dialog.
library;

import 'toolchain_store.dart';

class FlowHeroToolchainProbeResult {
  const FlowHeroToolchainProbeResult({
    required this.ok,
    required this.detail,
    this.versionOutput = '',
    this.failure = '',
    this.exitCode,
  });

  final bool ok;
  final String detail;
  final String versionOutput;
  final String failure;
  final int? exitCode;
}

typedef FlowHeroToolchainProbe =
    Future<FlowHeroToolchainProbeResult> Function(
      FlowHeroToolchainKind kind,
      String path,
    );

class FlowHeroToolchainSaveResult {
  const FlowHeroToolchainSaveResult({
    required this.saved,
    this.failureMessage = '',
    this.stateLine = '',
    this.languageNote = '',
  });

  const FlowHeroToolchainSaveResult.failed(String message)
    : this(saved: false, failureMessage: message);

  final bool saved;
  final String failureMessage;
  final String stateLine;
  final String languageNote;
}
