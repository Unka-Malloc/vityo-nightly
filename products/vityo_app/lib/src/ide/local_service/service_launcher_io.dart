import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'platform/platform_policy.dart';
import 'vityod_client.dart';
import 'transport/windows_named_pipe.dart';

Future<VityodClient?> createPlatformVityodClient() async {
  if (!VityodPlatformPolicy.supportsLocalDaemon) return null;
  final support = await getApplicationSupportDirectory();
  final serviceDirectory = Directory('${support.path}/vityod');
  await serviceDirectory.create(recursive: true);
  final endpoint = Platform.isWindows
      ? r'\\.\pipe\vityo-vityod'
      : '${serviceDirectory.path}/service.sock';
  final client = VityodClient(
    transport: SocketVityodTransport(endpointPath: endpoint),
    clientInstanceId: 'vityo-${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    await client.connect();
    return client;
  } on SocketException {
    await _startPackagedVityod(endpoint, serviceDirectory.path);
    await _waitForEndpoint(endpoint);
    await client.connect();
    return client;
  } on WindowsNamedPipeUnavailable {
    await _startPackagedVityod(endpoint, serviceDirectory.path);
    await _waitForEndpoint(endpoint);
    await client.connect();
    return client;
  }
}

Future<void> _startPackagedVityod(
  String endpoint,
  String stateDirectory,
) async {
  final executable = _packagedVityodExecutable();
  if (!executable.existsSync()) {
    throw StateError('The packaged vityod component is missing.');
  }
  await Process.start(executable.path, <String>[
    '--serve',
    '--endpoint',
    endpoint,
    '--state-dir',
    stateDirectory,
  ], mode: ProcessStartMode.detached);
}

File _packagedVityodExecutable() {
  final applicationBinary = File(Platform.resolvedExecutable);
  if (Platform.isMacOS) {
    return File('${applicationBinary.parent.parent.path}/Helpers/vityod');
  }
  if (Platform.isWindows) {
    return File('${applicationBinary.parent.path}/components/vityod.exe');
  }
  return File('${applicationBinary.parent.path}/components/vityod');
}

Future<void> _waitForEndpoint(String endpoint) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  if (Platform.isWindows) {
    while (true) {
      try {
        final pipe = await WindowsNamedPipeConnection.connect(endpoint);
        await pipe.close();
        return;
      } on WindowsNamedPipeUnavailable {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException(
            'The packaged vityod endpoint did not become ready.',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }
  }
  while (true) {
    try {
      final probe = await Socket.connect(
        InternetAddress(endpoint, type: InternetAddressType.unix),
        0,
      );
      await probe.close();
      return;
    } on SocketException {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
          'The packaged vityod endpoint did not become ready.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }
}

/// An acceptance-owned daemon. Each instance has a newly created root and
/// endpoint; it starts its own packaged process before attempting a connection.
/// No path_provider lookup, installed endpoint probe, or shared-daemon fallback
/// is reachable here. Temporary data is retained for acceptance evidence.
class VityodCompileAcceptanceService {
  VityodCompileAcceptanceService._(this.root, this._executable);

  static Future<VityodCompileAcceptanceService> create({
    Directory? temporaryParent,
    File? executable,
  }) async {
    final root = await (temporaryParent ?? Directory.systemTemp).createTemp(
      'vca-',
    );
    final service = VityodCompileAcceptanceService._(root, executable);
    await Directory(service.stateDirectory).create();
    await Directory(service.homeDirectory).create();
    await Directory(service.workspaceDirectory).create();
    await Directory('${root.path}/tmp').create();
    return service;
  }

  final Directory root;
  final File? _executable;
  Process? _process;
  VityodClient? _client;
  Future<VityodClient?>? _pending;
  bool _disposed = false;

  String get stateDirectory => '${root.path}/daemon';
  String get homeDirectory => '${root.path}/home';
  String get workspaceDirectory => '${root.path}/workspace';
  String get endpoint =>
      compileAcceptanceEndpoint(root.path, windows: Platform.isWindows);

  /// Child processes inherit the tool PATH, but user config/cache roots are
  /// private to this acceptance run, including Pafio/Styio subprocesses.
  Map<String, String> get environment =>
      compileAcceptanceEnvironment(root.path, Platform.environment);

  Future<VityodClient?> client() {
    if (_disposed) return Future<VityodClient?>.value(null);
    return _pending ??= _startAndConnect();
  }

  Future<VityodClient?> _startAndConnect() async {
    if (!VityodPlatformPolicy.supportsLocalDaemon) {
      throw UnsupportedError('Compile acceptance requires a desktop daemon.');
    }
    final executable = _executable ?? _packagedVityodExecutable();
    if (!executable.isAbsolute || !executable.existsSync()) {
      throw StateError('The compile acceptance vityod executable is missing.');
    }
    final process = await Process.start(
      executable.path,
      <String>[
        '--serve',
        '--endpoint',
        endpoint,
        '--state-dir',
        stateDirectory,
      ],
      environment: environment,
      includeParentEnvironment: false,
    );
    _process = process;
    // Do not forward native output into app logs or leave a pipe undrained.
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    try {
      await Future.any<void>(<Future<void>>[
        _waitForEndpoint(endpoint),
        process.exitCode.then<void>((_) {
          throw StateError(
            'The compile acceptance daemon exited before ready.',
          );
        }),
      ]);
      if (_disposed) return null;
      final client = VityodClient(
        transport: SocketVityodTransport(endpointPath: endpoint),
        clientInstanceId:
            'vityo-compile-${DateTime.now().microsecondsSinceEpoch}',
      );
      _client = client;
      await client.connect();
      return client;
    } on Object {
      await _client?.dispose();
      _client = null;
      await _stopProcess();
      rethrow;
    }
  }

  /// Stops only this instance's process. Never signals a shared daemon.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _pending;
    } on Object {
      // Failed starts still own any process they created.
    }
    try {
      await _client?.dispose();
    } on Object {
      // The shared Flow Hero holder may already have released this client.
    } finally {
      _client = null;
      await _stopProcess();
    }
  }

  Future<void> _stopProcess() async {
    final process = _process;
    _process = null;
    if (process == null) return;
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
  }
}

/// Uses the fresh root's random leaf for a Windows pipe name, never the normal
/// global `vityo-vityod` name. UNIX sockets also live in the fresh root.
String compileAcceptanceEndpoint(String rootPath, {required bool windows}) {
  if (windows) {
    final leaf = rootPath.replaceAll('\\', '/').split('/').last;
    return r'\\.\pipe\vityo-compile-' + leaf;
  }
  return '$rootPath/d.sock';
}

/// Only platform/tool selection facts cross into the isolated daemon. Provider
/// credentials and arbitrary host cache/config overrides are not inherited.
Map<String, String> compileAcceptanceEnvironment(
  String rootPath,
  Map<String, String> host,
) => <String, String>{
  for (final key in const <String>[
    'PATH',
    'PATHEXT',
    'SystemRoot',
    'SYSTEMROOT',
    'WINDIR',
    'COMSPEC',
    'LANG',
    'LC_ALL',
    'LC_CTYPE',
    'TZ',
    'SDKROOT',
    'DEVELOPER_DIR',
    'VITYO_PAFIO_BIN',
    'VITYO_STYIO_BIN',
    'VITYO_STYIO_LSPD_BIN',
  ])
    if (host[key] != null) key: host[key]!,
  'HOME': '$rootPath/home',
  'USERPROFILE': '$rootPath/home',
  'APPDATA': '$rootPath/home/AppData/Roaming',
  'LOCALAPPDATA': '$rootPath/home/AppData/Local',
  'XDG_CONFIG_HOME': '$rootPath/home/.config',
  'XDG_DATA_HOME': '$rootPath/home/.local/share',
  'XDG_STATE_HOME': '$rootPath/home/.local/state',
  'XDG_CACHE_HOME': '$rootPath/home/.cache',
  'PAFIO_HOME': '$rootPath/home/.pafio',
  'TMPDIR': '$rootPath/tmp',
  'TMP': '$rootPath/tmp',
  'TEMP': '$rootPath/tmp',
};
