/// Bounded bootstrap for compile acceptance using the production Flow Hero
/// runtime. Every launch owns new stores, a workspace copy and a daemon; Agent
/// state is never loaded. This is not a second application implementation.
library;

import 'dart:io';

import '../../ide/local_service/service_launcher_io.dart';
import 'local_services.dart';
import 'runtime.dart';

class FlowHeroCompileAcceptance {
  FlowHeroCompileAcceptance._(this.service)
    : runtime = ProductionFlowHeroRuntime.compileAcceptance(
        localServices: FlowHeroLocalServices(
          clientFactory: service.client,
          onDispose: service.dispose,
        ),
        homePath: service.homeDirectory,
        environment: service.environment,
      );

  static Future<FlowHeroCompileAcceptance> create({
    String workspaceFixture = '',
    String daemonExecutable = '',
    Directory? temporaryParent,
  }) async {
    final service = await VityodCompileAcceptanceService.create(
      temporaryParent: temporaryParent,
      executable: daemonExecutable.isEmpty ? null : File(daemonExecutable),
    );
    try {
      if (workspaceFixture.isNotEmpty) {
        await _copyFixture(
          Directory(workspaceFixture),
          Directory(service.workspaceDirectory),
        );
      }
      return FlowHeroCompileAcceptance._(service);
    } on Object {
      await service.dispose();
      rethrow;
    }
  }

  final VityodCompileAcceptanceService service;
  final ProductionFlowHeroRuntime runtime;

  String get workspaceRoot => service.workspaceDirectory;
}

/// Copy a small, explicitly supplied fixture. Reject links rather than reading
/// or modifying a project outside that fixture; the source is never written.
Future<void> _copyFixture(Directory source, Directory destination) async {
  if (!source.isAbsolute ||
      await FileSystemEntity.type(source.path, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw ArgumentError(
      'Compile acceptance requires an absolute fixture directory.',
    );
  }
  int files = 0;
  int bytes = 0;
  Future<void> copy(Directory from, Directory to) async {
    await for (final entity in from.list(followLinks: false)) {
      final name = entity.uri.pathSegments
          .where((part) => part.isNotEmpty)
          .last;
      final path = '${to.path}/$name';
      if (entity is Link) {
        throw ArgumentError(
          'Compile acceptance fixtures must not contain links.',
        );
      } else if (entity is Directory) {
        final child = await Directory(path).create();
        await copy(entity, child);
      } else if (entity is File) {
        bytes += await entity.length();
        if (++files > 1000 || bytes > 16 * 1024 * 1024) {
          throw ArgumentError(
            'Compile acceptance fixture exceeds the copy limit.',
          );
        }
        await entity.copy(path);
      } else {
        throw ArgumentError(
          'Compile acceptance fixtures require ordinary files.',
        );
      }
    }
  }

  await copy(source, destination);
}
