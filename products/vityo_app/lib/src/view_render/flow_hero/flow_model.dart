/// Style buffers, the analyzer's one rule, the Styio reader and the FLOW
/// board's geometry — all pure Dart so the projection can be tested without a
/// window. Transcribed from the direction proof
/// (`.impeccable/mocks/vityo-step-row.html`: `parseStyio`, `lintText`,
/// `renderGraph`).
library;

import 'dart:math' as math;

/// ------------------------------------------------------------------ points ---
class Pt {
  const Pt(this.x, this.y);
  final double x;
  final double y;

  Pt operator +(Pt o) => Pt(x + o.x, y + o.y);
  Pt operator -(Pt o) => Pt(x - o.x, y - o.y);
  Pt operator *(double k) => Pt(x * k, y * k);
  double get length => math.sqrt(x * x + y * y);

  @override
  String toString() => 'Pt(${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)})';
}

/// ------------------------------------------------------------------ lexing ---
enum TokenKind { plain, keyword, name, literal, operator, punct, comment }

class Token {
  const Token(this.text, this.kind);
  final String text;
  final TokenKind kind;
}

const Set<String> _styioKeywords = <String>{
  'pipeline', 'let', 'fn', 'state', 'when', 'emit',
};
const Set<String> _styioStates = <String>{'idle', 'running', 'held'};

final RegExp _ws = RegExp(r'^\s+');
final RegExp _op = RegExp(r'^(:=|\|>|->|<-|=>|<=|=)');
final RegExp _num = RegExp(r'^\d+(\.\d+)?');
final RegExp _ident = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*');
final RegExp _punct = RegExp(r'[{}()\[\],.;]');

/// Enough grammar for the buffers on board — a real lexer, not a highlighter.
List<Token> lexStyio(String line) {
  final List<Token> toks = <Token>[];
  int i = 0;
  bool expectName = false;
  while (i < line.length) {
    final String rest = line.substring(i);
    final RegExpMatch? ws = _ws.firstMatch(rest);
    if (ws != null) {
      toks.add(Token(ws.group(0)!, TokenKind.plain));
      i += ws.group(0)!.length;
      continue;
    }
    final RegExpMatch? op = _op.firstMatch(rest);
    if (op != null) {
      toks.add(Token(op.group(0)!, TokenKind.operator));
      i += op.group(0)!.length;
      continue;
    }
    final RegExpMatch? num = _num.firstMatch(rest);
    if (num != null) {
      toks.add(Token(num.group(0)!, TokenKind.literal));
      i += num.group(0)!.length;
      continue;
    }
    final RegExpMatch? id = _ident.firstMatch(rest);
    if (id != null) {
      final String w = id.group(0)!;
      TokenKind kind = TokenKind.plain;
      if (_styioKeywords.contains(w)) {
        kind = TokenKind.keyword;
        expectName = w == 'fn';
      } else if (_styioStates.contains(w)) {
        kind = TokenKind.literal;
      } else if (expectName) {
        kind = TokenKind.name;
        expectName = false;
      }
      toks.add(Token(w, kind));
      i += w.length;
      continue;
    }
    final String ch = rest[0];
    toks.add(Token(ch, _punct.hasMatch(ch) ? TokenKind.punct : TokenKind.plain));
    i += 1;
  }
  return toks;
}

final RegExp _tomlSection = RegExp(r'^\s*\[.*\]\s*$');
final RegExp _tomlComment = RegExp(r'^\s*#');
final RegExp _tomlKV = RegExp(r'^(\s*)([A-Za-z0-9_.-]+)(\s*=\s*)(.*)$');
final RegExp _tomlNumber = RegExp(r'^\d');

List<Token> lexToml(String line) {
  if (_tomlSection.hasMatch(line)) {
    return <Token>[Token(line, TokenKind.name)];
  }
  if (_tomlComment.hasMatch(line)) {
    return <Token>[Token(line, TokenKind.comment)];
  }
  final RegExpMatch? m = _tomlKV.firstMatch(line);
  if (m == null) return <Token>[Token(line, TokenKind.plain)];
  final String v = m.group(4)!;
  final TokenKind vc = (v.startsWith('"') || _tomlNumber.hasMatch(v))
      ? TokenKind.literal
      : TokenKind.keyword;
  return <Token>[
    Token(m.group(1)!, TokenKind.plain),
    Token(m.group(2)!, TokenKind.plain),
    Token(m.group(3)!, TokenKind.operator),
    Token(v, vc),
  ];
}

/// ----------------------------------------------------------------- linting ---
class Diagnostic {
  const Diagnostic(this.line, this.ident);
  final int line;
  final String ident;
}

final RegExp _inputRouteDecl =
    RegExp(r'^\s*let\s+([A-Za-z_][A-Za-z0-9_]*)\s*:?=\s*.*?<-');

/// The analyzer keeps exactly one honest rule: an input route (`a <- b`) must be
/// consumed. Whole-word uses are counted; fewer than two is a finding.
List<Diagnostic> lintText(String text) {
  final List<Diagnostic> diags = <Diagnostic>[];
  final List<String> lines = text.split('\n');
  for (int i = 0; i < lines.length; i++) {
    final RegExpMatch? m = _inputRouteDecl.firstMatch(lines[i]);
    if (m == null) continue;
    final String ident = m.group(1)!;
    final int count = RegExp('\\b${RegExp.escape(ident)}\\b').allMatches(text).length;
    if (count < 2) diags.add(Diagnostic(i, ident));
  }
  return diags;
}

/// ------------------------------------------------------------- the reader ---
class Chain {
  const Chain(this.kind, this.parts, this.out);
  final String kind; // pipe | route
  final List<String> parts;
  final String out;
}

class InputRoute {
  const InputRoute(this.name, this.target, this.source);
  final String name;
  final String target;
  final String source;
}

class ConstDecl {
  const ConstDecl(this.name, this.value);
  final String name;
  final String value;
}

class Transition {
  const Transition(this.label, this.back, this.to);
  final String label;
  final bool back;
  final String to;
}

class EmitDecl {
  const EmitDecl(this.fn, this.value);
  final String fn;
  final String value;
}

class StateDecl {
  const StateDecl(this.name, {this.initial = false});
  final String name;
  final bool initial;
}

class StyioModel {
  String? pipeline;
  final List<Chain> chains = <Chain>[];
  final List<InputRoute> routes = <InputRoute>[];
  final List<ConstDecl> consts = <ConstDecl>[];
  final List<String> fns = <String>[];
  final List<StateDecl> states = <StateDecl>[];
  final List<Transition> transitions = <Transition>[];
  final List<EmitDecl> emits = <EmitDecl>[];

  /// The program's states in source order, deduped, the first occurrence's
  /// initial flag kept — `held` appended because a stopped run must never be
  /// able to read RUNNING.
  List<StateDecl> get stateList {
    final List<StateDecl> list = <StateDecl>[];
    final Set<String> seen = <String>{};
    for (final StateDecl s in states) {
      if (seen.add(s.name)) list.add(s);
    }
    if (states.isNotEmpty && seen.add('held')) {
      list.add(const StateDecl('held'));
    }
    return list;
  }
}

final RegExp _rePipeline = RegExp(r'^\s*pipeline\s+([A-Za-z_]\w*)');
final RegExp _reFn = RegExp(r'^\s*fn\s+([A-Za-z_]\w*)');
final RegExp _reClose = RegExp(r'^\s*\}');
final RegExp _reState = RegExp(r'^\s*state\s+([A-Za-z_]\w*)');
final RegExp _reWhen = RegExp(r'^\s*when\s+(.+?)\s*->\s*state\s+([A-Za-z_]\w*)');
final RegExp _reEmit = RegExp(r'^\s*emit\s+([A-Za-z_]\w*)');
final RegExp _reLet = RegExp(r'^\s*let\s+([A-Za-z_]\w*)\s*:?=\s*(.+?)\s*$');

List<String> _splitTrim(String s, String sep) =>
    s.split(sep).map((String e) => e.trim()).toList();

/// Just enough of Styio to know what connects to what.
StyioModel parseStyio(String text) {
  final StyioModel m = StyioModel();
  String? fn;
  for (final String ln in text.split('\n')) {
    RegExpMatch? mt = _rePipeline.firstMatch(ln);
    if (mt != null) {
      m.pipeline = mt.group(1);
      continue;
    }
    mt = _reFn.firstMatch(ln);
    if (mt != null) {
      final String name = mt.group(1)!;
      fn = name;
      m.fns.add(name);
      continue;
    }
    if (_reClose.hasMatch(ln)) {
      fn = null;
      continue;
    }
    if (fn != null) {
      mt = _reState.firstMatch(ln);
      if (mt != null) {
        m.states.add(StateDecl(mt.group(1)!, initial: true));
        continue;
      }
      mt = _reWhen.firstMatch(ln);
      if (mt != null) {
        m.transitions.add(
          Transition('${mt.group(1)!.trim()} →', false, mt.group(2)!),
        );
        continue;
      }
      mt = _reEmit.firstMatch(ln);
      if (mt != null) {
        m.emits.add(EmitDecl(fn, mt.group(1)!));
        continue;
      }
      continue;
    }
    mt = _reLet.firstMatch(ln);
    if (mt == null) continue;
    final String name = mt.group(1)!;
    final String rhs = mt.group(2)!;
    if (rhs.contains('<-')) {
      final List<String> p = _splitTrim(rhs, '<-');
      m.routes.add(InputRoute(name, p[0], p[1]));
    } else if (rhs.contains('|>')) {
      m.chains.add(Chain('pipe', _splitTrim(rhs, '|>'), name));
    } else if (rhs.contains('=>')) {
      final List<String> p = _splitTrim(rhs, '=>');
      if (p[0] == 'state') {
        m.states.add(StateDecl(p[1]));
        m.transitions.add(Transition('$name => ${p[1]}', false, p[1]));
      }
    } else if (rhs.contains('<=')) {
      final List<String> p = _splitTrim(rhs, '<=');
      if (p[0] == 'state') {
        m.states.add(StateDecl(p[1]));
        m.transitions.add(Transition('$name <= ${p[1]}', true, p[1]));
      }
    } else if (rhs.contains('->')) {
      m.chains.add(Chain('route', _splitTrim(rhs, '->'), name));
    } else {
      m.consts.add(ConstDecl(name, rhs));
    }
  }
  return m;
}

/// Reads `tempo = <n>` out of the loop configuration buffer.
final RegExp _tempoKey = RegExp(r'tempo\s*=\s*(\d+(?:\.\d+)?)');
double? parseTomlTempo(String text) {
  final RegExpMatch? m = _tempoKey.firstMatch(text);
  if (m == null) return null;
  return double.tryParse(m.group(1)!);
}

/// ------------------------------------------------------------- text metrics ---
enum GraphFont { modName, modKind, chip, chipWarn }

/// The proof measures its furniture from character counts (`length × 6.8`);
/// port note (o) asks the port to measure real text, so the Flutter build
/// injects a real measurer and this one keeps the model usable on its own.
abstract class Glyphs {
  double width(String text, GraphFont font);
}

class ApproxGlyphs implements Glyphs {
  const ApproxGlyphs();

  @override
  double width(String text, GraphFont font) {
    switch (font) {
      case GraphFont.modName:
        return text.length * 7.4;
      case GraphFont.modKind:
        return text.length * 6.8;
      case GraphFont.chip:
        return text.length * 6.8;
      case GraphFont.chipWarn:
        return text.length * 6.3;
    }
  }
}

/// --------------------------------------------------------------- geometry ---
class Cubic {
  const Cubic(this.p0, this.c1, this.c2, this.p3);

  final Pt p0;
  final Pt c1;
  final Pt c2;
  final Pt p3;

  static const int _samples = 96;

  Pt pointAt(double t) {
    final double u = 1 - t;
    final double a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t;
    return Pt(
      a * p0.x + b * c1.x + c * c2.x + d * p3.x,
      a * p0.y + b * c1.y + c * c2.y + d * p3.y,
    );
  }

  Pt tangentAt(double t) {
    final double u = 1 - t;
    final double a = 3 * u * u, b = 6 * u * t, c = 3 * t * t;
    final Pt d = Pt(
      a * (c1.x - p0.x) + b * (c2.x - c1.x) + c * (p3.x - c2.x),
      a * (c1.y - p0.y) + b * (c2.y - c1.y) + c * (p3.y - c2.y),
    );
    return d.length == 0 ? const Pt(1, 0) : d;
  }

  List<Pt> get samples => <Pt>[for (int i = 0; i <= _samples; i++) pointAt(i / _samples)];

  double get length {
    final List<Pt> pts = samples;
    double total = 0;
    for (int i = 1; i < pts.length; i++) {
      total += (pts[i] - pts[i - 1]).length;
    }
    return total;
  }

  /// `getPointAtLength` — arc length, sampled the way a browser walks a path.
  Pt pointAtLength(double l) {
    final List<Pt> pts = samples;
    double total = 0;
    for (int i = 1; i < pts.length; i++) {
      final Pt prev = pts[i - 1];
      final double seg = (pts[i] - prev).length;
      if (total + seg >= l && seg > 0) {
        return prev + (pts[i] - prev) * ((l - total) / seg);
      }
      total += seg;
    }
    return pts.last;
  }
}

/// `cableD`: horizontal-tangent cubic with a computed sag, and the two plug
/// angles derived from that cubic's own tangents at each end.
class CableGeometry {
  const CableGeometry(this.curve, this.angleStart, this.angleEnd);
  final Cubic curve;
  final double angleStart;
  final double angleEnd;
}

CableGeometry cableD(double x1, double y1, double x2, double y2, [double? sag]) {
  final double gap = math.max(40, (x2 - x1).abs());
  final double s = sag ?? math.min(30, math.max(12, gap * 0.16));
  final double c = math.max(24, gap * 0.36);
  const double deg = 180 / math.pi;
  return CableGeometry(
    Cubic(Pt(x1, y1), Pt(x1 + c, y1 + s), Pt(x2 - c, y2 + s), Pt(x2, y2)),
    math.atan2(s, c) * deg,
    math.atan2(-s, c) * deg,
  );
}

/// ------------------------------------------------------------------- board ---
class Chip {
  Chip(this.center, this.label, this.width, {this.cv = false, this.warn = false});
  final Pt center;
  final String label;
  final double width;
  final bool cv;
  final bool warn;
}

class Lamp {
  Lamp(this.name, this.at, {this.initial = false});
  final String name;
  final Pt at;
  final bool initial;
}

class GraphModule {
  GraphModule(this.name);
  final String name;
  String? kind;
  String? kindDetail;
  double x = 0, y = 0, w = 96, h = 48;
  int layer = 0;
  bool isState = false;
  final List<Lamp> lamps = <Lamp>[];

  Pt get sled => Pt(x + w - 13, y + 10);
  Pt get leftEdge => Pt(x, y + 24);
  Pt get rightEdge => Pt(x + w, y + 24);
  String get kindText => kind == 'CONST' ? (kindDetail ?? '') : (kind ?? '');
}

class BoardCable {
  BoardCable(this.curve, this.from, this.to, this.label, {this.cv = false, this.route = false});
  final Cubic curve;
  final String from;
  final String to;
  final String label;
  final bool cv;
  final bool route;
  double angleStart = 0;
  double angleEnd = 0;
  Pt? plugStart;
  Pt? plugEnd;
  Chip? chip;
}

class BoardRoute {
  BoardRoute(this.name, this.bare);
  final String name;
  final bool bare;
  late Cubic curve;
  late double startX, startY, endX, endY;
  Pt? sled;
  Chip? warnChip;
  Chip? chip;
}

class BoardTap {
  BoardTap(this.curve, this.point, this.chip);
  final Cubic curve;
  final Pt point;
  final Chip chip;
}

class GraphBoard {
  /// Draw order, exactly as the proof paints it: cables, control voltages,
  /// modules over them, jacks and plugs on top, chips last.
  final List<BoardCable> cables = <BoardCable>[];
  final List<BoardRoute> routes = <BoardRoute>[];
  final List<BoardTap> taps = <BoardTap>[];
  final List<GraphModule> modules = <GraphModule>[];
  final List<Pt> jacks = <Pt>[];
  final List<Lamp> stateLamps = <Lamp>[];
  final List<Pt> strays = <Pt>[];
  final List<({Pt at, double angle})> plugs = <({Pt at, double angle})>[];
  final List<Chip> chips = <Chip>[];

  // pulse engine bindings, rebuilt on every draw
  final List<BoardCable> pulsePath = <BoardCable>[];
  final List<GraphModule> pulseModules = <GraphModule>[];
  GraphModule? mainModule;
  GraphModule? sinkModule;
  Lamp? restLamp;
  Lamp? runLamp;
  Lamp? heldLamp;
  Pt? frozenPulse;

  double maxX = 760;
  double maxY = 480;
  String title = '';
  String caption = '';
  String label = '';
}

class _Edge {
  _Edge(this.from, this.to, this.label, {this.sink = false, this.route = false});
  final String from;
  final String to;
  final String label;
  final bool sink;
  final bool route;
}

/// The board is drawn from the buffer, never by hand: parse, lay the data-flow
/// DAG out, then measure everything else from what was found.
GraphBoard buildGraph(
  StyioModel m, {
  required String fileName,
  required Set<String> hanging,
  Glyphs glyphs = const ApproxGlyphs(),
}) {
  final GraphBoard board = GraphBoard();
  final Map<String, GraphModule> nodes = <String, GraphModule>{};
  final List<_Edge> edges = <_Edge>[];
  final List<InputRoute> routeEdges = <InputRoute>[];

  GraphModule node(String name) => nodes.putIfAbsent(name, () => GraphModule(name));

  final Map<String, String> producers = <String, String>{};
  for (final Chain c in m.chains) {
    if (c.kind == 'pipe') {
      for (int k = 0; k < c.parts.length - 1; k++) {
        final String from = producers[c.parts[k]] ?? c.parts[k];
        edges.add(_Edge(from, c.parts[k + 1], c.parts[k]));
        node(from);
        node(c.parts[k + 1]);
      }
      producers[c.out] = c.parts[c.parts.length - 1];
    } else {
      final String from = producers[c.parts[0]] ?? c.parts[0];
      edges.add(_Edge(from, c.parts[1], c.parts[0]));
      node(from);
      node(c.parts[1]);
      edges.add(_Edge(c.parts[1], c.out, c.out, sink: true));
      node(c.out).kind = 'CHANNEL';
      producers[c.out] = c.out;
    }
  }
  for (final InputRoute r in m.routes) {
    node(r.source).kind = 'EXTERNAL';
    routeEdges.add(r);
    edges.add(_Edge(r.source, r.target, r.name, route: true));
    node(r.target);
  }
  final Map<String, int> inDeg = <String, int>{};
  for (final _Edge e in edges) {
    if (e.route) continue;
    inDeg[e.to] = (inDeg[e.to] ?? 0) + 1;
  }
  for (final GraphModule n in nodes.values) {
    if (n.kind != null) continue;
    n.kind = (inDeg[n.name] ?? 0) > 0 ? 'PIPE' : 'ORIGIN';
  }

  // layers over the data-flow DAG; input routes hang below, not across
  final List<_Edge> dataEdges = edges.where((_Edge e) => !e.route).toList();
  for (int pass = 0; pass < 8; pass++) {
    for (final _Edge e in dataEdges) {
      final GraphModule a = nodes[e.from]!, b = nodes[e.to]!;
      if (b.layer < a.layer + 1) b.layer = a.layer + 1;
    }
  }
  final Map<int, List<GraphModule>> byLayer = <int, List<GraphModule>>{};
  for (final GraphModule n in nodes.values) {
    if (n.kind == 'EXTERNAL') continue;
    byLayer.putIfAbsent(n.layer, () => <GraphModule>[]).add(n);
  }
  for (final List<GraphModule> list in byLayer.values) {
    for (int i = 0; i < list.length; i++) {
      list[i].x = 64 + list[i].layer * 196;
      list[i].y = 108 + i * 96;
    }
  }
  for (final GraphModule n in nodes.values) {
    n.w = math.max(
      96,
      26 +
          math.max(
            glyphs.width(n.name, GraphFont.modName),
            glyphs.width(n.kindText, GraphFont.modKind),
          ),
    );
    n.h = 48;
  }
  for (int i = 0; i < routeEdges.length; i++) {
    final InputRoute r = routeEdges[i];
    final GraphModule? e = nodes[r.source], t = nodes[r.target];
    if (e != null && t != null) {
      e.x = t.x + t.w / 2 - e.w / 2 + i * 24;
      e.y = 252;
    }
  }
  final bool hasData = dataEdges.isNotEmpty;
  for (int i = 0; i < m.fns.length; i++) {
    final String f = m.fns[i];
    final GraphModule n = node(f);
    n.kind = 'FN · ENTRY';
    n.w = math.max(110, 30 + glyphs.width(f, GraphFont.modName));
    n.h = 48;
    if (hasData) {
      EmitDecl? emit;
      for (final EmitDecl e in m.emits) {
        if (e.fn == f) {
          emit = e;
          break;
        }
      }
      _Edge? tapped;
      if (emit != null) {
        for (final _Edge e in dataEdges) {
          if (e.label == emit.value) {
            tapped = e;
            break;
          }
        }
      }
      final GraphModule? anchor = tapped != null
          ? nodes[tapped.from]
          : ((byLayer[1]?.isNotEmpty ?? false) ? byLayer[1]!.first : null);
      n.x = anchor != null ? anchor.x + anchor.w / 2 - n.w / 2 : 64 + i * 200;
      n.y = 252;
    } else {
      n.x = 64 + i * 200;
      n.y = 108;
    }
  }

  GraphModule? stateNode;
  final List<StateDecl> stateList = m.stateList;
  if (stateList.isNotEmpty) {
    stateNode = node('state');
    stateNode.kind = 'STATE';
    stateNode.isState = true;
    stateNode.w = 140;
    stateNode.h = 34 + stateList.length * 15 + 12;
    final GraphModule? f0 = m.fns.isNotEmpty ? node(m.fns.first) : null;
    stateNode.x = f0 != null ? f0.x + f0.w + 200 : 64;
    stateNode.y = f0 != null ? f0.y - 8 : 108;
  }
  for (int i = 0; i < m.consts.length; i++) {
    final ConstDecl c = m.consts[i];
    final GraphModule n = node(c.name);
    if (n.kind != null && n.kind != 'PIPE' && n.kind != 'ORIGIN') continue;
    n.kind = 'CONST';
    n.kindDetail = c.value;
    n.w = math.max(
      96,
      26 +
          math.max(
            glyphs.width(c.name, GraphFont.modName),
            glyphs.width(c.value, GraphFont.modKind),
          ),
    );
    if (hasData) {
      n.x = (stateNode != null ? stateNode.x + stateNode.w + 40 : 64) + i * 150;
      n.y = 252;
    } else {
      n.x = 64 + (m.fns.length + i) * 200;
      n.y = 108;
    }
  }

  // ---- draw ----
  final Set<String> jackSet = <String>{};
  void jack(double x, double y) {
    if (jackSet.add('${x.round()},${y.round()}')) board.jacks.add(Pt(x, y));
  }

  void plug(double x, double y, double deg) =>
      board.plugs.add((at: Pt(x, y), angle: deg));

  void chipOn(Cubic pe, String label, {double at = 0.5, bool cv = false}) {
    final Pt pt = pe.pointAtLength(pe.length * at);
    board.chips.add(
      Chip(pt, label, glyphs.width(label, GraphFont.chip) + 16, cv: cv),
    );
  }

  BoardCable addCable(Cubic c, String from, String to, String label,
      {bool cv = false, bool route = false}) {
    final BoardCable bc = BoardCable(c, from, to, label, cv: cv, route: route);
    board.cables.add(bc);
    return bc;
  }

  final Map<_Edge, BoardCable> drawn = <_Edge, BoardCable>{};
  for (final _Edge e in edges) {
    final GraphModule a = nodes[e.from]!, b = nodes[e.to]!;
    final bool isRoute = e.route;
    if (isRoute) {
      // an input route rises from the external's top edge to the target's underside
      final double x1 = a.x + a.w - 20, y1 = a.y;
      final bool bare = hanging.contains(e.label);
      final double x2 = b.x + 20, y2 = b.y + b.h + (bare ? 26 : 0);
      final Cubic c = Cubic(Pt(x1, y1), Pt(x1, y1 - 36), Pt(x2, y2 + 40), Pt(x2, y2));
      final BoardRoute r = BoardRoute(e.label, bare)
        ..curve = c
        ..startX = x1
        ..startY = y1
        ..endX = x2
        ..endY = y2;
      board.routes.add(r);
      drawn[e] = addCable(c, e.from, e.to, e.label);
      if (bare) {
        board.strays.add(Pt(x2, y2));
        r.sled = Pt(x2, y2);
        final String label = '${e.label} — never consumed';
        final double w = glyphs.width(label, GraphFont.chipWarn) + 16;
        final Chip chip = Chip(
          Pt(x2 + 12 + w / 2, y2), /* the plate stands right of the frayed end; the cable never crosses its legend */
          label,
          w,
          warn: true,
        );
        r.warnChip = chip;
        board.chips.add(chip);
        jack(x1, y1);
      } else {
        jack(x1, y1);
        jack(b.x + 20, b.y + b.h);
        plug(x1, y1, -90);
        plug(b.x + 20, b.y + b.h, -90);
        chipOn(c, e.label);
      }
      continue;
    }
    final double x1 = a.x + a.w, y1 = a.y + 24;
    final double x2 = b.x, y2 = b.y + 24;
    final CableGeometry g = cableD(x1, y1, x2, y2);
    final BoardCable bc = addCable(g.curve, e.from, e.to, e.label)
      ..angleStart = g.angleStart
      ..angleEnd = g.angleEnd
      ..plugStart = Pt(x1, y1)
      ..plugEnd = Pt(x2, y2);
    drawn[e] = bc;
    jack(x1, y1);
    jack(x2, y2);
    plug(x1, y1, g.angleStart);
    plug(x2, y2, g.angleEnd);
    chipOn(g.curve, e.label);
    bc.chip = board.chips.last;
  }

  for (final GraphModule n in nodes.values) {
    if (n.isState) {
      for (int i = 0; i < stateList.length; i++) {
        n.lamps.add(
          Lamp(
            stateList[i].name,
            Pt(n.x + 20, n.y + 42 + i * 15),
            initial: stateList[i].initial,
          ),
        );
      }
    }
    board.modules.add(n);
  }
  if (stateNode != null) board.stateLamps.addAll(stateNode.lamps);

  // control voltages: transitions ride below the data band, buckled like every cable
  if (stateNode != null && m.fns.isNotEmpty) {
    final GraphModule f0 = nodes[m.fns.first]!;
    int fwd = 0, back = 0;
    for (final Transition t in m.transitions) {
      if (t.back) {
        final double x1 = stateNode.x + 20, y1 = stateNode.y + stateNode.h;
        final double x2 = f0.x + f0.w - 20, y2 = f0.y + f0.h;
        final double drop = 34 + back * 18;
        final Cubic c =
            Cubic(Pt(x1, y1), Pt(x1, y1 + drop), Pt(x2, y2 + drop), Pt(x2, y2));
        addCable(c, 'state', f0.name, t.label, cv: true);
        jack(x1, y1);
        jack(x2, y2);
        chipOn(c, t.label, cv: true);
        back++;
      } else {
        final double x1 = f0.x + f0.w, y1 = f0.y + 18 + fwd * 14;
        final double x2 = stateNode.x, y2 = stateNode.y + 30 + fwd * 15;
        final double sag = 14 + fwd * 26;
        final CableGeometry g = cableD(x1, y1, x2, y2, sag);
        addCable(g.curve, f0.name, 'state', t.label, cv: true);
        jack(x1, y1);
        jack(x2, y2);
        chipOn(g.curve, t.label, at: fwd.isOdd ? 0.62 : 0.38, cv: true);
        fwd++;
      }
    }
  }
  // emit taps: a dashed feeler from the fn up to the cable that carries the value
  for (final EmitDecl em in m.emits) {
    final GraphModule? f0 = nodes[em.fn];
    if (f0 == null) continue;
    BoardCable? tapped;
    for (final BoardCable c in board.cables) {
      if (!c.cv && c.label == em.value && c.chip != null) {
        tapped = c;
        break;
      }
    }
    if (tapped == null) continue;
    final Pt pt = tapped.curve.pointAtLength(tapped.curve.length / 2);
    final double x1 = f0.x + 20, y1 = f0.y;
    final Cubic c = Cubic(Pt(x1, y1), Pt(x1, y1 - 40), Pt(pt.x, pt.y + 42), pt);
    final String label = 'emit ${em.value}';
    // the chip rides the feeler halfway up — never at the tap point, where it
    // would double-seat over the carrier cable's own chip
    final Pt chipAt = c.pointAtLength(c.length / 2);
    final Chip chip = Chip(chipAt, label, glyphs.width(label, GraphFont.chip) + 16, cv: true);
    board.taps.add(BoardTap(c, pt, chip));
    board.chips.add(chip);
    addCable(c, f0.name, '', label, cv: true);
  }

  // bind the pulse engine to what was just drawn
  GraphModule? sink;
  for (final GraphModule n in nodes.values) {
    if (n.kind == 'CHANNEL') {
      sink = n;
      break;
    }
  }
  if (sink != null) {
    String cur = sink.name;
    int guard = 0;
    final List<BoardCable> found = <BoardCable>[];
    while (guard++ < 24) {
      _Edge? hit;
      for (final _Edge e in dataEdges) {
        if (drawn.containsKey(e) && e.to == cur) {
          hit = e;
          break;
        }
      }
      if (hit == null) break;
      found.insert(0, drawn[hit]!);
      cur = hit.from;
    }
    for (final BoardCable c in found) {
      board.pulsePath.add(c);
      board.pulseModules.add(nodes[c.from]!);
    }
  }
  board.mainModule = m.fns.isNotEmpty ? nodes[m.fns.first] : null;
  board.sinkModule = sink;
  final GraphModule? lastStage =
      board.pulseModules.isNotEmpty ? board.pulseModules.last : null;
  board.frozenPulse = lastStage != null ? Pt(lastStage.x, lastStage.y + 24) : null;

  for (final Lamp l in board.stateLamps) {
    if (l.initial) board.restLamp = l;
  }
  if (m.transitions.isNotEmpty) {
    final String target = m.transitions.first.to;
    for (final Lamp l in board.stateLamps) {
      if (l.name == target) board.runLamp = l;
    }
  }
  for (final Lamp l in board.stateLamps) {
    if (l.name == 'held') board.heldLamp = l;
  }

  for (final GraphModule n in nodes.values) {
    board.maxX = math.max(board.maxX, n.x + n.w + 48);
    board.maxY = math.max(board.maxY, n.y + n.h + 72);
  }
  board.title = m.pipeline != null
      ? 'PIPELINE ${m.pipeline!.toUpperCase()} — SIGNAL ROUTING'
      : '${fileName.toUpperCase()} — SIGNAL ROUTING';
  board.caption = 'LIVE PROJECTION · ${fileName.toUpperCase()}';
  final String chainDesc =
      dataEdges.map((_Edge e) => e.label).join(' through ');
  final String hang = hanging.isEmpty
      ? ''
      : '; hanging input routes: ${(hanging.toList()..sort()).join(', ')}';
  board.label = 'Signal routing of ${m.pipeline ?? fileName}: '
      '${chainDesc.isEmpty ? 'no data cables yet' : chainDesc}$hang';
  return board;
}
