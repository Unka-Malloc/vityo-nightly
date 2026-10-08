/// Arguments and truthful evidence for a process-isolated desktop startup probe.
final class DesktopStartupProbeRequest {
  const DesktopStartupProbeRequest({
    required this.candidate,
    required this.evidenceFile,
  });

  static const String probeArgument = '--vityo-startup-probe';
  static const String candidateArgument = '--vityo-candidate';
  static const String evidenceFileArgument = '--vityo-evidence-file';

  final String candidate;
  final String evidenceFile;

  /// Returns null for an ordinary launch and rejects incomplete probe requests.
  static DesktopStartupProbeRequest? parse(List<String> arguments) {
    var probeRequested = false;
    String? candidate;
    String? evidenceFile;

    for (var index = 0; index < arguments.length; index += 1) {
      final argument = arguments[index];
      if (argument.startsWith('--vityo-') &&
          argument != probeArgument &&
          argument != candidateArgument &&
          argument != evidenceFileArgument) {
        throw const FormatException('Invalid Vityo startup probe arguments.');
      }

      if (argument == probeArgument) {
        if (probeRequested) {
          throw const FormatException('Invalid Vityo startup probe arguments.');
        }
        probeRequested = true;
        continue;
      }

      if (argument == candidateArgument || argument == evidenceFileArgument) {
        if (index + 1 >= arguments.length ||
            arguments[index + 1].startsWith('--')) {
          throw const FormatException('Invalid Vityo startup probe arguments.');
        }
        final value = arguments[++index];
        if (argument == candidateArgument) {
          if (candidate != null || !_isCandidateLabel(value)) {
            throw const FormatException(
              'Invalid Vityo startup probe arguments.',
            );
          }
          candidate = value;
        } else {
          if (evidenceFile != null || value.isEmpty) {
            throw const FormatException(
              'Invalid Vityo startup probe arguments.',
            );
          }
          evidenceFile = value;
        }
      }
    }

    if (!probeRequested && candidate == null && evidenceFile == null) {
      return null;
    }
    if (!probeRequested || candidate == null || evidenceFile == null) {
      throw const FormatException('Invalid Vityo startup probe arguments.');
    }
    return DesktopStartupProbeRequest(
      candidate: candidate,
      evidenceFile: evidenceFile,
    );
  }

  /// Writes truthful startup facts only after the supplied rasterization future.
  Future<Map<String, Object?>> recordAfterFirstFrame({
    required Future<void> firstFrameRasterized,
    required String platform,
    Future<int> Function()? verifyWindowsPipeLibrary,
    required Future<void> Function(Map<String, Object?> evidence) writeEvidence,
  }) async {
    await firstFrameRasterized;
    int? windowsPipeAbi;
    if (platform == 'windows') {
      if (verifyWindowsPipeLibrary == null) {
        throw StateError('Windows startup requires bundled pipe verification');
      }
      windowsPipeAbi = await verifyWindowsPipeLibrary();
      if (windowsPipeAbi != 1) {
        throw StateError('Windows startup pipe ABI is incompatible');
      }
    }
    final evidence = <String, Object?>{
      'schema_version': 1,
      'candidate': candidate,
      'platform': platform,
      'launched': true,
      'first_frame': true,
      if (windowsPipeAbi != null) 'windows_pipe_abi': windowsPipeAbi,
    };
    await writeEvidence(evidence);
    return evidence;
  }

  static bool _isCandidateLabel(String value) =>
      value.isNotEmpty &&
      value != '.' &&
      value != '..' &&
      !value.contains('/') &&
      !value.contains('\\') &&
      !value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);
}
