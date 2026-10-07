/// Native file fallback when no discovered toolchain is suitable.
library;

import 'package:file_selector/file_selector.dart';
import '../../view_ide/flow_hero/flow_hero.dart';

Future<String?> pickFlowHeroToolchainFile(FlowHeroToolchainKind kind) async {
  final file = await openFile(confirmButtonText: 'Choose ${kind.displayName}');
  final path = file?.path.trim();
  return path == null || path.isEmpty ? null : path;
}
