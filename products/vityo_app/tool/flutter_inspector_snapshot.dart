import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
      'usage: dart run tool/flutter_inspector_snapshot.dart <ws-uri>',
    );
    exitCode = 64;
    return;
  }

  final service = await vmServiceConnectUri(arguments.single);
  try {
    final vm = await service.getVM();
    final isolateRef = vm.isolates
        ?.where((entry) => entry.name == 'main')
        .firstOrNull;
    if (isolateRef?.id == null) {
      throw StateError('running main isolate not found');
    }
    final isolateId = isolateRef!.id!;
    final isolate = await service.getIsolate(isolateId);
    const summaryMethod = 'ext.flutter.inspector.getRootWidgetSummaryTree';
    const layoutMethod = 'ext.flutter.inspector.getLayoutExplorerNode';
    final extensions = isolate.extensionRPCs ?? const <String>[];
    if (!extensions.contains(summaryMethod) ||
        !extensions.contains(layoutMethod)) {
      throw StateError('Flutter Inspector service extensions are unavailable');
    }

    const objectGroup = 'vityo-live-audit';
    final summaryResponse = await service.callServiceExtension(
      summaryMethod,
      isolateId: isolateId,
      args: const <String, dynamic>{'objectGroup': objectGroup},
    );
    final root = _decodeResult(summaryResponse);
    final targets = <Map<String, dynamic>>[];
    _collectTargets(root, targets);

    final layouts = <Map<String, Object?>>[];
    for (final target in targets) {
      final id = target['valueId'] as String?;
      if (id == null) continue;
      final response = await service.callServiceExtension(
        layoutMethod,
        isolateId: isolateId,
        args: <String, dynamic>{
          'id': id,
          'groupName': objectGroup,
          'subtreeDepth': '1',
        },
      );
      final layout = _decodeResult(response);
      layouts.add(<String, Object?>{
        'widget': _widgetName(target),
        'description': target['description'],
        'size': _propertyDescription(layout, 'size'),
        'constraints': _propertyDescription(layout, 'constraints'),
      });
    }

    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'widgetTreeReady': true,
        'inspectedWidgets': layouts,
      }),
    );
    await service.callServiceExtension(
      'ext.flutter.inspector.disposeGroup',
      isolateId: isolateId,
      args: const <String, dynamic>{'objectGroup': objectGroup},
    );
  } finally {
    await service.dispose();
  }
}

dynamic _decodeResult(Response response) {
  final result = response.json?['result'];
  return result is String ? jsonDecode(result) : result;
}

void _collectTargets(dynamic node, List<Map<String, dynamic>> output) {
  if (node is! Map) return;
  final typed = node.cast<String, dynamic>();
  final widget = _widgetName(typed);
  if (widget == 'VityoShellScaffold' ||
      widget == 'EditorSurface' ||
      widget == '_IdeEditorSurface' ||
      widget == '_SourceBuffer') {
    output.add(typed);
  }
  final children = typed['children'];
  if (children is List) {
    for (final child in children) {
      _collectTargets(child, output);
    }
  }
}

String _widgetName(Map<String, dynamic> node) {
  final description = node['description']?.toString() ?? '';
  final separator = description.indexOf('(');
  return separator < 0 ? description : description.substring(0, separator);
}

String? _propertyDescription(dynamic node, String name) {
  if (node is! Map) return null;
  final properties = node['properties'];
  if (properties is List) {
    for (final property in properties.whereType<Map>()) {
      if (property['name'] == name) return property['description']?.toString();
    }
  }
  final renderObject = node['renderObject'];
  if (renderObject is Map) {
    return _propertyDescription(renderObject, name);
  }
  return null;
}
