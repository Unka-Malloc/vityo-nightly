import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_ide/language/contract/language_contract.dart';
import 'package:vityo_app/src/view_ide/platform/platform_target.dart';
import 'package:vityo_app/src/view_render/platform/platform.dart';
import 'package:vityo_app/src/view_render/shell/outline_surface.dart';
import 'package:vityo_app/src/view_render/shell/quick_open_surface.dart';

void main() {
  final viewportProfile = resolveViewportProfile(
    platformTarget: PlatformTarget.macos,
    width: 1200,
    height: 800,
  );

  testWidgets('quick open filters real workspace files and opens matches', (
    tester,
  ) async {
    String? openedPath;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 420,
            child: QuickOpenSurface(
              viewportProfile: viewportProfile,
              workspaceFiles: const <String>[
                'src/main.styio',
                'lib/util.styio',
                'docs/readme.md',
              ],
              recentFilePaths: const <String>['docs/readme.md'],
              onOpenFile: (filePath) async {
                openedPath = filePath;
                return true;
              },
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('quick-open-surface')), findsOneWidget);
    expect(find.text('workspace-files 3'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('quick-open-input')),
      'util',
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('quick-open-result-lib/util.styio')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('quick-open-result-src/main.styio')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey('quick-open-result-lib/util.styio')),
    );
    await tester.pump();

    expect(openedPath, 'lib/util.styio');
  });

  testWidgets('quick open reports an empty workspace instead of faking files', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 420,
            child: QuickOpenSurface(viewportProfile: viewportProfile),
          ),
        ),
      ),
    );

    expect(find.text('workspace-files 0'), findsOneWidget);
    expect(find.text('No workspace files are indexed yet.'), findsOneWidget);
  });

  testWidgets('outline surface renders real document symbols', (tester) async {
    DocumentSymbol? selected;
    const symbols = <DocumentSymbol>[
      DocumentSymbol(
        name: 'calculate',
        kind: SymbolKind.function,
        nameRange: SourceRange(start: 4, end: 13),
        declarationRange: SourceRange(start: 0, end: 20),
      ),
      DocumentSymbol(
        name: 'count',
        kind: SymbolKind.variable,
        nameRange: SourceRange(start: 30, end: 35),
        declarationRange: SourceRange(start: 28, end: 40),
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 420,
            child: OutlineSurface(
              viewportProfile: viewportProfile,
              documentId: 'src/main.styio',
              symbols: symbols,
              onSelectSymbol: (symbol) {
                selected = symbol;
              },
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('outline-surface')), findsOneWidget);
    expect(find.text('symbols 2'), findsOneWidget);
    expect(find.text('calculate'), findsOneWidget);
    expect(find.text('count'), findsOneWidget);

    await tester.tap(find.text('count'));
    await tester.pump();

    expect(selected?.name, 'count');
  });

  testWidgets('outline surface stays honest when no symbols are available', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 420,
            child: OutlineSurface(
              viewportProfile: viewportProfile,
              documentId: 'src/main.styio',
            ),
          ),
        ),
      ),
    );

    expect(find.text('symbols 0'), findsOneWidget);
    expect(find.textContaining('reported no symbols'), findsOneWidget);
  });
}
