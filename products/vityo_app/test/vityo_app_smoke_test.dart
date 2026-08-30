import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/frontend_shell/frontend_shell.dart';
import 'package:vityo_app/src/ide/editor/editor_controller.dart';
import 'package:vityo_app/src/ide/editor/document_state.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/adapter_contracts.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/dependency_source_adapter.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/deployment_adapter.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/execution_adapter.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/project_graph_adapter.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/project_graph_contract.dart';
import 'package:vityo_app/src/view_ide/backend_toolchain/runtime_event_adapter.dart';
import 'package:vityo_app/src/view_ide/language/language_contract.dart';
import 'package:vityo_app/src/view_ide/language/simple_styio_language_service.dart';
import 'package:vityo_app/src/view_ide/module_host/module_capability_matrix.dart';
import 'package:vityo_app/src/view_ide/module_host/module_definition.dart';
import 'package:vityo_app/src/view_ide/module_host/module_manifest.dart';
import 'package:vityo_app/src/view_ide/module_host/module_registry.dart';
import 'package:vityo_app/src/view_ide/platform/native_module_loader.dart';
import 'package:vityo_app/src/view_ide/platform/platform_target.dart';
import 'package:vityo_app/src/view_ide/toolchain/toolchain_catalog.dart';
import 'package:vityo_app/src/view_ide/toolchain/toolchain_manager.dart';
import 'package:vityo_app/src/view_ide/toolchain/toolchain_resolver.dart';

import 'backend_provider_test_support.dart';
import 'support/editor_widget_test_driver.dart';

part 'smoke/vityo_smoke_harness.dart';
part 'smoke/vityo_shell_smoke_tests.dart';
part 'smoke/vityo_editor_smoke_tests.dart';
part 'smoke/vityo_language_smoke_tests.dart';
part 'smoke/vityo_refactor_smoke_tests.dart';

void main() {
  _registerShellSmokeTests();
  _registerEditorSmokeTests();
  _registerLanguageSmokeTests();
  _registerRefactorSmokeTests();
}
