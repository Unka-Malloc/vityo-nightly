/// Vityo — Step-Row Workbench, a desktop port of the direction proof at
/// `.impeccable/mocks/vityo-step-row.html`.
///
/// Run it on its own:
/// `flutter run -d macos -t lib/src/view_render/workbench_demo/workbench_demo.dart`
///
/// The demo is self-contained: it boots no services, talks to no daemon and
/// imports nothing but Flutter and its own files.
library;

import 'package:flutter/material.dart';

import 'machine.dart';
import 'tokens.dart';

void main() => runApp(const WorkbenchDemoApp());

class WorkbenchDemoApp extends StatelessWidget {
  const WorkbenchDemoApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'VITYO — Step Row Workbench',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: C.room,
          canvasColor: C.room,
          fontFamily: kMono,
          colorScheme: const ColorScheme.dark(
            surface: C.panel,
            primary: C.red,
            secondary: C.orange,
          ),
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
          hoverColor: Colors.transparent,
        ),
        home: const WorkbenchPage(),
      );
}

class WorkbenchPage extends StatefulWidget {
  const WorkbenchPage({super.key});

  @override
  State<WorkbenchPage> createState() => _WorkbenchPageState();
}

class _WorkbenchPageState extends State<WorkbenchPage> {
  final WorkbenchController controller = WorkbenchController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: C.room,
        body: RepaintBoundary(
          key: const ValueKey<String>('machineCapture'), /* headless state captures hook here */
          child: Machine(controller: controller),
        ),
      );
}
