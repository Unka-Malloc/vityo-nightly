/// Real Styio source buffers + lexer-driven coloring.
///
/// Coloring comes from the real `lexStyio` in flow_model.dart — the actual
/// engine ported from the step-row workbench — not from hardcoded span lists.
library;

import 'package:flutter/material.dart';

import 'flow_model.dart';
import 'palette.dart';

Color tokenColor(TokenKind kind) {
  switch (kind) {
    case TokenKind.keyword:
      return P.redBright;
    case TokenKind.name:
      return P.orangeBright;
    case TokenKind.literal:
      return P.yellow;
    case TokenKind.operator:
      return P.silkHi;
    case TokenKind.comment:
      return P.silkDim;
    case TokenKind.punct:
      return P.silk;
    case TokenKind.plain:
      return P.paperLow;
  }
}

/// Lex [line] with the real engine and map tokens to colored spans.
List<TextSpan> lexSpans(String line, {double size = 11.5}) {
  final List<Token> tokens = lexStyio(line);
  if (tokens.isEmpty) {
    return <TextSpan>[
      TextSpan(
        text: ' ',
        style: P.monoStyle(size: size),
      ),
    ];
  }
  return <TextSpan>[
    for (final Token t in tokens)
      TextSpan(
        text: t.text,
        style: P.monoStyle(color: tokenColor(t.kind), size: size),
      ),
  ];
}

/// One gutter-numbered, lexer-colored source line.
class SourceLine extends StatelessWidget {
  const SourceLine({
    super.key,
    required this.lineNo,
    required this.line,
    this.hot = false,
  });

  final int lineNo;
  final String line;
  final bool hot;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: hot
          ? BoxDecoration(
              color: P.red.withValues(alpha: 0.09),
              border: Border(left: BorderSide(color: P.red, width: 2)),
            )
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 30,
            child: Text(
              '$lineNo',
              textAlign: TextAlign.right,
              style: P.monoStyle(color: P.silkDim, size: 11),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text.rich(
              TextSpan(children: lexSpans(line)),
              softWrap: false,
              overflow: TextOverflow.clip,
            ),
          ),
        ],
      ),
    );
  }
}
