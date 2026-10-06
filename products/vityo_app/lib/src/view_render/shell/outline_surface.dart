import 'package:flutter/material.dart';

import '../../view_ide/language/language_contract.dart';
import '../platform/viewport_profile.dart';

/// Real document outline backed by the active document's `documentSymbols`.
///
/// The StyioService LSP connector publishes document-level symbols, so this
/// panel lists exactly those symbols and never invents hierarchy or
/// position-scoped language features that the service does not provide.
class OutlineSurface extends StatelessWidget {
  const OutlineSurface({
    super.key,
    required this.viewportProfile,
    required this.documentId,
    this.symbols = const <DocumentSymbol>[],
    this.onSelectSymbol,
  });

  final ViewportProfile viewportProfile;
  final String documentId;
  final List<DocumentSymbol> symbols;
  final ValueChanged<DocumentSymbol>? onSelectSymbol;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = viewportProfile.isMobile;
    final orderedSymbols = _orderedSymbols(symbols);

    return Card(
      key: const ValueKey('outline-surface'),
      child: Padding(
        padding: EdgeInsets.all(compact ? 14 : 18),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final tight = constraints.maxHeight < 260;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Outline',
                  style: tight
                      ? theme.textTheme.titleMedium
                      : theme.textTheme.titleLarge,
                ),
                if (tight) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${symbols.length} symbols · $documentId',
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ] else ...[
                  const SizedBox(height: 6),
                  Text(
                    'Document symbols reported by the active language service '
                    'for $documentId. Position-scoped language features stay '
                    'unavailable until the service exposes them.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      Chip(label: Text('document $documentId')),
                      Chip(label: Text('symbols ${symbols.length}')),
                    ],
                  ),
                ],
                const SizedBox(height: 10),
                Expanded(
                  child: orderedSymbols.isEmpty
                      ? Text(
                          'The language service reported no symbols for this '
                          'document yet.',
                          style: theme.textTheme.bodySmall,
                        )
                      : ListView.builder(
                          key: const ValueKey('outline-symbol-list'),
                          itemCount: orderedSymbols.length,
                          itemBuilder: (context, index) {
                            final symbol = orderedSymbols[index];
                            final line = symbol.nameRange.start;
                            return ListTile(
                              key: ValueKey(
                                'outline-symbol-${symbol.kind.name}-${symbol.name}-${symbol.nameRange.start}',
                              ),
                              dense: true,
                              leading: Icon(_iconForKind(symbol.kind)),
                              title: Text(symbol.name),
                              subtitle: Text(
                                symbol.detail.isEmpty
                                    ? '${symbol.kind.name} @ $line'
                                    : '${symbol.kind.name} · ${symbol.detail}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: onSelectSymbol == null
                                  ? null
                                  : () {
                                      onSelectSymbol!(symbol);
                                    },
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

List<DocumentSymbol> _orderedSymbols(List<DocumentSymbol> symbols) {
  final ordered = symbols.toList(growable: false);
  ordered.sort((left, right) {
    final byStart = left.nameRange.start.compareTo(right.nameRange.start);
    if (byStart != 0) {
      return byStart;
    }
    return left.name.compareTo(right.name);
  });
  return ordered;
}

IconData _iconForKind(SymbolKind kind) {
  return switch (kind) {
    SymbolKind.function => Icons.functions_rounded,
    SymbolKind.pipeline => Icons.account_tree_outlined,
    SymbolKind.state => Icons.toggle_on_outlined,
    SymbolKind.resource => Icons.inventory_2_outlined,
    SymbolKind.variable => Icons.data_object_rounded,
    SymbolKind.parameter => Icons.tune_rounded,
    SymbolKind.task => Icons.checklist_rounded,
  };
}
