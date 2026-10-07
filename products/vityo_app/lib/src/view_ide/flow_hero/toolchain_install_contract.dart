/// Typed outcomes shared by Flow Hero's install controller and dialog.
library;

import 'dart:collection';

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

/// Existence is not executable compatibility, identity, or provenance.
class FlowHeroToolchainCandidate {
  const FlowHeroToolchainCandidate({
    required this.path,
    required this.sourceLabel,
    required this.exists,
  });

  final String path;
  final String sourceLabel;
  final bool exists;
}

/// A read-only list with explicit coverage status for bounded discovery.
class FlowHeroToolchainCandidateCatalog
    extends UnmodifiableListView<FlowHeroToolchainCandidate> {
  FlowHeroToolchainCandidateCatalog(
    super.candidates, {
    this.isPartial = false,
    this.isCancelled = false,
  });

  final bool isPartial;
  final bool isCancelled;
}

typedef FlowHeroToolchainCandidateDiscovery =
    Future<List<FlowHeroToolchainCandidate>> Function(
      FlowHeroToolchainKind kind,
      String selectedPath,
    );

typedef FlowHeroToolchainFilePicker =
    Future<String?> Function(FlowHeroToolchainKind kind);
