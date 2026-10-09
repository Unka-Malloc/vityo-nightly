import 'dart:io';

import 'package:test/test.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/pafio_cli_discovery.dart';
import 'package:vityo_app/src/view_ide/environment/configuration/forwarded_host_environment.dart';
import 'package:vityo_app/src/view_ide/environment/configuration/host_environment.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/platform_manager/platform_manager.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/process/process_manager.dart';
import 'package:vityo_app/src/view_ide/environment/system_compatibility/process/process_manager_io.dart';

import 'support/vityod_test_harness.dart';

void main() {
  tearDown(() {
    debugOverrideHostEnvironment(null);
    debugOverridePafioExecutableCandidates(null);
  });

  for (final environment in <Map<String, String>?>[
    null,
    const <String, String>{},
    const <String, String>{'PATH': ''},
  ]) {
    test(
      'Pafio discovery distinguishes omitted context from $environment',
      () async {
        debugOverrideHostEnvironment(const <String, String>{
          'PATH': '/fixture/host-bin',
          'TOKEN': 'synthetic-fixture',
        });
        final process = _RecordingProcess();
        await resolvePafioBinary(
          _ProbeManagers(process),
          environment: environment,
          extraCandidatePaths: const <String>['/fixture/pafio'],
        );
        expect(
          process.requests.single.environment,
          environment == null
              ? <String, String>{'PATH': '/fixture/host-bin'}
              : <String, String>{},
        );
      },
    );
  }

  test('forwarding uses only the explicit non-secret launch allowlist', () {
    const allowed = <String, String>{
      'HOME': '/fixture/home',
      'USERPROFILE': r'C:\fixture\home',
      'TMPDIR': '/fixture/tmp',
      'TEMP': r'C:\fixture\tmp',
      'TMP': r'C:\fixture\tmp',
      'FLUTTER_ROOT': '/fixture/flutter',
      'PUB_CACHE': '/fixture/pub',
      'DART_SDK': '/fixture/dart',
      'PATH': r'C:\fixture\bin;C:\Windows\System32',
      'SYSTEMROOT': r'C:\Windows',
      'COMSPEC': r'C:\Windows\System32\cmd.exe',
      'PATHEXT': '.COM;.EXE;.BAT;.CMD',
    };
    final source = <String, String>{
      ...allowed,
      'VITYO_PAFIO_BIN': '/fixture/selected-pafio',
      'API_KEY': 'synthetic-placeholder',
      'AUTHORIZATION': 'Bearer synthetic-placeholder',
      'SESSION_COOKIE': 'synthetic-placeholder',
      'PROVIDER_CREDENTIAL': 'synthetic-placeholder',
      'PASSWORD': 'synthetic-placeholder',
      'SECRET': 'synthetic-placeholder',
      'RUNTIME_TOKEN': 'synthetic-placeholder',
      'OTHER_CONFIG': '/fixture/unused',
    };
    final snapshot = Map<String, String>.of(source);
    expect(forwardedHostEnvironment(source: source), allowed);
    expect(source, snapshot, reason: 'selection input is never mutated');
  });

  test('default forwarding still reads the host provider', () {
    debugOverrideHostEnvironment(const <String, String>{
      'HOME': '/fixture/host',
      'TOKEN': 'synthetic-placeholder',
    });
    expect(forwardedHostEnvironment(), <String, String>{
      'HOME': '/fixture/host',
    });
    expect(forwardedHostEnvironment(source: const <String, String>{}), isEmpty);
  });

  test(
    'Windows launch key casing canonicalizes and identical aliases deduplicate',
    () {
      expect(
        forwardedHostEnvironment(
          source: const <String, String>{
            'Path': r'C:\fixture\selected',
            'PATH': r'C:\fixture\selected',
            'SystemRoot': r'C:\Windows',
            'SYSTEMROOT': r'C:\Windows',
            'ComSpec': r'C:\Windows\System32\cmd.exe',
            'PATHEXT': '.EXE;.CMD',
            'pathext': '.EXE;.CMD',
          },
        ),
        const <String, String>{
          'PATH': r'C:\fixture\selected',
          'SYSTEMROOT': r'C:\Windows',
          'COMSPEC': r'C:\Windows\System32\cmd.exe',
          'PATHEXT': '.EXE;.CMD',
        },
      );
    },
  );

  test('conflicting launch aliases fail closed without exposing values', () {
    for (final key in <String>['PATH', 'SYSTEMROOT', 'COMSPEC', 'PATHEXT']) {
      for (final conflicting in <String>['/fixture/second', '']) {
        final entries = <String, String>{
          key: '/fixture/first',
          key.toLowerCase(): conflicting,
        };
        for (final source in <Map<String, String>>[
          entries,
          Map<String, String>.fromEntries(entries.entries.toList().reversed),
        ]) {
          expect(
            () => forwardedHostEnvironment(source: source),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                'Conflicting host environment values denied for $key.',
              ),
            ),
          );
        }
      }
    }
  });

  test('empty entries and unknown aliases cannot expand the allowlist', () {
    expect(
      forwardedHostEnvironment(
        source: const <String, String>{
          'PATH': '',
          'PATHEXT_TOKEN': 'synthetic-placeholder',
          'SYSTEMROOT_SECRET': 'synthetic-placeholder',
          'COMSPEC_PASSWORD': 'synthetic-placeholder',
          'PATH_EXTRA': '/fixture/unapproved',
          'HOME': '/fixture/home',
        },
      ),
      const <String, String>{'HOME': '/fixture/home'},
    );
  });

  for (final key in <String>['PATH', 'SYSTEMROOT', 'COMSPEC', 'PATHEXT']) {
    for (final value in <String>[
      'BeArEr synthetic-placeholder',
      '/fixture?ACCESS_TOKEN=synthetic-placeholder',
    ]) {
      test(
        '$key refuses a credential-shaped value without echoing it (${value.startsWith('BeArEr') ? 'bearer' : 'query'})',
        () {
          expect(
            () =>
                forwardedHostEnvironment(source: <String, String>{key: value}),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                'Credential-like host environment value denied for $key.',
              ),
            ),
          );
        },
      );
    }
  }

  test(
    'selected Pafio stays authoritative while only safe PATH reaches the probe',
    () async {
      final process = _RecordingProcess();
      final managers = _ProbeManagers(process);
      final resolved = await resolvePafioBinary(
        managers,
        environment: const <String, String>{
          'VITYO_PAFIO_BIN': '/fixture/selected/pafio',
          'PATH': '/fixture/different-tool/bin',
          'TOKEN': 'synthetic-placeholder',
        },
        extraCandidatePaths: const <String>['/fixture/fallback/pafio'],
      );
      expect(resolved, '/fixture/selected/pafio');
      expect(process.requests, hasLength(1));
      expect(process.requests.single.executablePath, resolved);
      expect(process.requests.single.arguments, <String>['--version']);
      expect(process.requests.single.environment, <String, String>{
        'PATH': '/fixture/different-tool/bin',
      });
      expect(process.requests.single.serviceKind, ProcessServiceKind.pafio);
    },
  );

  test('failed authoritative probe never falls back after filtering', () async {
    final process = _RecordingProcess(succeed: false);
    final resolved = await resolvePafioBinary(
      _ProbeManagers(process),
      environment: const <String, String>{
        'VITYO_PAFIO_BIN': '/fixture/broken/pafio',
        'PATH': '/fixture/path',
        'PASSWORD': 'synthetic-placeholder',
      },
      extraCandidatePaths: const <String>['/fixture/fallback/pafio'],
    );
    expect(resolved, isNull);
    expect(process.requests.map((request) => request.executablePath), <String>[
      '/fixture/broken/pafio',
    ]);
  });

  test(
    'credential-shaped PATH blocks discovery before any process request',
    () async {
      final process = _RecordingProcess();
      final resolved = await resolvePafioBinary(
        _ProbeManagers(process),
        environment: const <String, String>{
          'VITYO_PAFIO_BIN': '/fixture/pafio',
          'PATH': 'Bearer synthetic-placeholder',
        },
      );
      expect(resolved, isNull);
      expect(process.requests, isEmpty);
    },
  );

  group('real daemon Pafio version probe', () {
    VityodTestHarness? harness;
    late ProcessManager process;
    late String dartExecutable;

    setUpAll(() async {
      // Resolve the already-installed native Dart binary, not a shell wrapper.
      // This isolates the environment boundary from fake .cmd reliability.
      dartExecutable = await _nativeDartExecutable();
      harness = await VityodTestHarness.start(
        clientId: 'pafio-environment-regression',
      );
      process = await createPlatformProcessManager(
        vityodClient: harness!.client,
      );
    });
    tearDownAll(() async => harness?.close());

    test(
      'ambient credential-shaped entries do not block an actual --version probe',
      () async {
        final recording = _RecordingProcess(delegate: process);
        final resolved = await resolvePafioBinary(
          _ProbeManagers(recording),
          environment: <String, String>{
            ...Platform.environment,
            'VITYO_PAFIO_BIN': dartExecutable,
            'VITYO_DISCOVERY_TOKEN': 'synthetic-placeholder',
          },
        );
        expect(resolved, dartExecutable);
        expect(
          recording.results.single.succeeded,
          isTrue,
          reason: recording.results.single.message,
        );
        expect(
          recording.requests.single.environment!.keys,
          isNot(contains('VITYO_DISCOVERY_TOKEN')),
        );
        expect(
          recording.requests.single.environment!.keys,
          isNot(contains('VITYO_PAFIO_BIN')),
        );
      },
    );

    test(
      'an explicit sensitive process environment still fails before start',
      () async {
        var started = false;
        final result = await process.run(
          ProcessCommandRequest(
            executablePath: dartExecutable,
            arguments: const <String>['--version'],
            environment: const <String, String>{
              'TOKEN': 'synthetic-placeholder',
            },
            serviceKind: ProcessServiceKind.pafio,
            onStarted: (_) => started = true,
          ),
        );
        expect(result.succeeded, isFalse);
        expect(result.message, contains('credential_passthrough_denied'));
        expect(result.exitCode, isNull);
        expect(started, isFalse);
      },
    );
  });
}

Future<String> _nativeDartExecutable() async {
  final name = Platform.isWindows ? 'dart.exe' : 'dart';
  final current = File(
    await File(Platform.resolvedExecutable).resolveSymbolicLinks(),
  );
  if (current.uri.pathSegments.last == name) return current.path;
  // flutter_tester lives inside this same installed SDK's engine cache.
  var directory = current.parent;
  for (var depth = 0; depth < 8; depth++) {
    final candidate = File('${directory.path}/bin/cache/dart-sdk/bin/$name');
    if (await candidate.exists()) return candidate.absolute.path;
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  throw StateError(
    'Native Dart binary in the installed Flutter SDK is required',
  );
}

class _ProbeManagers implements PlatformManagerBundle {
  _ProbeManagers(this.process);
  @override
  final ProcessManager process;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingProcess implements ProcessManager {
  _RecordingProcess({this.delegate, this.succeed = true});
  final ProcessManager? delegate;
  final bool succeed;
  final List<ProcessCommandRequest> requests = <ProcessCommandRequest>[];
  final List<ProcessCommandResult> results = <ProcessCommandResult>[];

  @override
  Future<ProcessCommandResult> run(ProcessCommandRequest request) async {
    requests.add(request);
    final result = delegate == null
        ? ProcessCommandResult(
            status: succeed
                ? ProcessCommandStatus.succeeded
                : ProcessCommandStatus.failed,
            executablePath: request.executablePath,
            arguments: request.arguments,
            exitCode: succeed ? 0 : 1,
            stdout: '',
            stderr: '',
            duration: Duration.zero,
          )
        : await delegate!.run(request);
    results.add(result);
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
