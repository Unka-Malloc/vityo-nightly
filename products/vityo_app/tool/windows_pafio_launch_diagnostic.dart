// Diagnostic only. The Python supervisor owns this process and all descendants.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vityo_app/src/view_ide/environment/system_compatibility/process/process_facts.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/process/process_manager.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/process/process_manager_io.dart';

import '../test/fake_pafio_cli.dart';
import '../test/support/vityod_test_harness.dart';

const _limit = 8192;
const _timeout = Duration(seconds: 5);

class _Output {
  final List<int> bytes = <int>[];
  bool truncated = false;
  Future<void> drain(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      final remaining = _limit - bytes.length;
      if (chunk.length > remaining) truncated = true;
      bytes.addAll(chunk.take(remaining));
    }
  }

  String get text =>
      _safeText(utf8.decode(bytes, allowMalformed: true), truncated: truncated);
}

String _bounded(String value, {bool truncated = false}) {
  final bytes = utf8.encode(_safeText(value, truncated: truncated));
  return utf8.decode(bytes.take(_limit).toList(), allowMalformed: true);
}

String _safeText(String value, {bool truncated = false}) {
  final secrets =
      Platform.environment.entries
          .where(
            (entry) =>
                entry.value.isNotEmpty &&
                RegExp(
                  r'token|secret|password|credential|api.?key|auth',
                  caseSensitive: false,
                ).hasMatch(entry.key),
          )
          .map((entry) => entry.value)
          .toList()
        ..sort((left, right) => right.length.compareTo(left.length));
  for (final secret in secrets) {
    value = value.replaceAll(secret, '<redacted>');
    if (truncated) {
      // A bounded capture can end in the middle of a secret.
      for (var size = secret.length - 1; size > 0; size--) {
        if (value.endsWith(secret.substring(0, size))) {
          value = '${value.substring(0, value.length - size)}<redacted>';
          break;
        }
      }
    }
  }
  return value;
}

Future<Map<String, Object?>> _direct(
  String executable,
  Map<String, String> environment,
) async {
  Process? process;
  final out = _Output();
  final err = _Output();
  try {
    process = await Process.start(
      executable,
      const <String>['--version'],
      environment: environment,
      includeParentEnvironment: false,
    );
    final streams = Future.wait(<Future<void>>[
      out.drain(process.stdout),
      err.drain(process.stderr),
    ]);
    final code = await process.exitCode.timeout(_timeout);
    await streams.timeout(_timeout);
    return <String, Object?>{
      'status': code == 0 ? 'succeeded' : 'failed',
      'exit_code': code,
      'started': true,
      'stdout': out.text,
      'stderr': err.text,
      'stdout_truncated': out.truncated,
      'stderr_truncated': err.truncated,
    };
  } on ProcessException catch (error) {
    return <String, Object?>{
      'status': 'spawn-error',
      'started': process != null,
      'error_code': error.errorCode,
      'message': _bounded(error.message),
    };
  } on TimeoutException {
    final observation = <String, Object?>{
      'status': 'timedOut',
      'started': process != null,
      'stdout': out.text,
      'stderr': err.text,
    };
    await _emit(observation);
    process?.kill();
    if (process != null) {
      await process.exitCode.timeout(const Duration(seconds: 2));
    }
    return observation;
  }
}

Future<Map<String, Object?>> _daemon(
  String executable,
  Map<String, String> environment,
) async {
  VityodTestHarness? harness;
  LocalProcessManager? manager;
  ProcessCommandHandle? handle;
  final observation = <String, Object?>{};
  try {
    final daemon = File('native/vityod/target/debug/vityod.exe').absolute;
    observation['daemon_executable'] = daemon.path;
    harness = await VityodTestHarness.start(
      clientId: 'pafio-launch-diagnostic',
      executableOverride: daemon,
    );
    manager = LocalProcessManager(
      facts: ProcessFacts.windowsX64(),
      client: harness.client,
    );
    final result = await manager
        .run(
          ProcessCommandRequest(
            executablePath: executable,
            arguments: const <String>['--version'],
            environment: environment,
            timeout: _timeout,
            serviceKind: ProcessServiceKind.pafio,
            onStarted: (value) => handle = value,
          ),
        )
        .timeout(const Duration(seconds: 8));
    observation.addAll(<String, Object?>{
      'status': result.status.name,
      'exit_code': result.exitCode,
      'started': handle != null,
      'stdout': _bounded(
        result.stdout,
        truncated: result.metadata['stdoutTruncated'] == true,
      ),
      'stderr': _bounded(
        result.stderr,
        truncated: result.metadata['stderrTruncated'] == true,
      ),
      'message': result.message == null ? null : _bounded(result.message!),
      'stdout_truncated':
          utf8.encode(result.stdout).length > _limit ||
          result.metadata['stdoutTruncated'] == true,
      'stderr_truncated':
          utf8.encode(result.stderr).length > _limit ||
          result.metadata['stderrTruncated'] == true,
    });
  } on TimeoutException {
    observation.addAll(<String, Object?>{
      'status': 'timedOut',
      'started': handle != null,
    });
    await _emit(observation);
    if (manager != null && handle != null) {
      final cancellation = await manager
          .cancelProcess(handle!.processHandleId)
          .timeout(const Duration(seconds: 2));
      observation['cancel_status'] = cancellation.accepted;
    }
  } finally {
    // Emit the actual launch observation BEFORE shutdown; a shutdown hang must
    // not discard the launch failure that this tool exists to diagnose.
    if (observation.containsKey('status')) await _emit(observation);
    if (harness != null) {
      await harness.close().timeout(const Duration(seconds: 3));
      observation['harness_closed'] = true;
    }
  }
  return observation;
}

late String _case;
Future<void> _emit(Map<String, Object?> value) async {
  stdout.writeln(
    jsonEncode(<String, Object?>{'phase': 'result', 'case': _case, ...value}),
  );
  await stdout.flush();
}

Future<void> main(List<String> args) async {
  if (!Platform.isWindows || args.length != 3) {
    throw ArgumentError('Windows supervisor arguments required');
  }
  _case = args[0];
  final python = File(args[1]);
  final directory = Directory(args[2]);
  final environment = Map<String, String>.unmodifiable(Platform.environment);
  final clock = Stopwatch()..start();
  try {
    if (!python.isAbsolute ||
        !await python.exists() ||
        !python.path.toLowerCase().endsWith('.exe')) {
      throw ArgumentError('An existing absolute Python .exe is required');
    }
    final String executable;
    if (_case.endsWith('-native')) {
      executable = python.path;
    } else {
      final launcher = await writeFakePafioCli(
        workspaceRoot: directory,
        pythonSource:
            "import sys\nif sys.argv[1:] == ['--version']:\n"
            "    print('pafio diagnostic')\n    raise SystemExit(0)\n"
            'raise SystemExit(64)\n',
      );
      if (_case.endsWith('-absolute-wrapper')) {
        // Only change interpreter lookup; script, arguments and environment
        // remain identical to the existing fake-Pafio helper.
        if (RegExp('[%"\\r\\n]').hasMatch(python.path)) {
          throw ArgumentError('Python path cannot be safely embedded in cmd');
        }
        await launcher.writeAsString(
          '@echo off\r\n"${python.path}" "%~dp0pafio.py" %*\r\n',
        );
      }
      executable = launcher.path;
    }
    final result = _case.startsWith('direct-')
        ? await _direct(executable, environment)
        : await _daemon(executable, environment);
    await _emit(<String, Object?>{
      ...result,
      'elapsed_ms': clock.elapsedMilliseconds,
    });
  } on Object catch (error) {
    await _emit(<String, Object?>{
      'status': 'diagnostic-error',
      'message': _bounded(error.toString()),
      'elapsed_ms': clock.elapsedMilliseconds,
    });
    exitCode = 1;
  }
}
