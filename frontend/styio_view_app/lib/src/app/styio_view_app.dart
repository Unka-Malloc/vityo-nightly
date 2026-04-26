import 'package:flutter/material.dart';

import '../theme/styio_theme.dart';
import 'app_bootstrap.dart';
import 'layout/styio_shell_scaffold.dart';
import 'state/shell_model.dart';
import 'state/shell_scope.dart';

class StyioViewApp extends StatefulWidget {
  const StyioViewApp({super.key, required this.bootstrap});

  final AppBootstrap bootstrap;

  @override
  State<StyioViewApp> createState() => _StyioViewAppState();
}

class _StyioViewAppState extends State<StyioViewApp> {
  late final ShellModel _shellModel;

  @override
  void initState() {
    super.initState();
    _shellModel = ShellModel(
      platformTarget: widget.bootstrap.platformTarget,
      supplementalAdapterCapabilities:
          widget.bootstrap.supplementalAdapterCapabilities,
      projectGraphAdapter: widget.bootstrap.projectGraphAdapter,
      workspaceController: widget.bootstrap.workspaceController,
      workspaceDocumentStore: widget.bootstrap.workspaceDocumentStore,
      moduleRegistry: widget.bootstrap.moduleRegistry,
      nativeModuleLoader: widget.bootstrap.nativeModuleLoader,
      editorController: widget.bootstrap.editorController,
      executionAdapter: widget.bootstrap.executionAdapter,
      executionAdapterFactory: widget.bootstrap.executionAdapterFactory,
      runtimeEventAdapter: widget.bootstrap.runtimeEventAdapter,
      dependencySourceAdapter: widget.bootstrap.dependencySourceAdapter,
      deploymentAdapter: widget.bootstrap.deploymentAdapter,
      toolchainManagementAdapter: widget.bootstrap.toolchainManagementAdapter,
    );
  }

  @override
  void dispose() {
    _shellModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ShellScope(
      model: _shellModel,
      child: MaterialApp(
        title: 'Styio View',
        debugShowCheckedModeBanner: false,
        theme: StyioTheme.light(),
        home: const StyioShellScaffold(),
      ),
    );
  }
}
