import 'package:flutter_test/flutter_test.dart';
import 'package:vityo_app/src/view_render/workbench_demo/flow_model.dart';

/// The three buffers the machine ships with, verbatim from the direction proof.
const String mainStyio = 'pipeline mainFlow\n'
    'let staged := source |> normalize\n'
    'let routeOut = staged -> render\n'
    'let routeIn = source <- bridge\n'
    'let promote = state => running\n'
    'let fallback = state <= idle\n'
    'fn main(input) {\n'
    '  state idle\n'
    '  when input.ready -> state running\n'
    '  emit staged\n'
    '}';

const String utilStyio = 'fn clamp01(x) {\n'
    '  when x < 0 -> 0\n'
    '  when x > 1 -> 1\n'
    '  emit x\n'
    '}\n'
    'let gain := 0.8\n'
    'let bias := 0.02';

const String styioToml = '[workspace]\n'
    'name = "demo/app"\n'
    'rev = 142\n'
    '\n'
    '[loop]\n'
    'tempo = 128.0\n'
    'steps = 16';

GraphModule moduleNamed(GraphBoard b, String name) =>
    b.modules.firstWhere((GraphModule m) => m.name == name);

void main() {
  group('the reader', () {
    test('main.styio parses to a four-node data chain with a channel sink', () {
      final StyioModel m = parseStyio(mainStyio);
      expect(m.pipeline, 'mainFlow');
      expect(m.fns, <String>['main']);
      expect(m.chains.length, 2);
      expect(m.chains.first.parts, <String>['source', 'normalize']);
      expect(m.chains.first.out, 'staged');
      expect(m.chains.last.parts, <String>['staged', 'render']);
      expect(m.chains.last.out, 'routeOut');
      expect(m.routes.single.name, 'routeIn');
      expect(m.routes.single.target, 'source');
      expect(m.routes.single.source, 'bridge');
      expect(m.consts, isEmpty);
      expect(
        m.transitions.map((Transition t) => '${t.label}|${t.back}|${t.to}'),
        <String>[
          'promote => running|false|running',
          'fallback <= idle|true|idle',
          'input.ready →|false|running',
        ],
      );
      expect(m.emits.single.fn, 'main');
      expect(m.emits.single.value, 'staged');
    });

    test('the state list is deduped in source order and appends held', () {
      final List<StateDecl> states = parseStyio(mainStyio).stateList;
      // `let promote = state => running` claims the name before the fn declares
      // its own initial state, so the proof keeps running first — replicated.
      expect(states.map((StateDecl s) => s.name), <String>['running', 'idle', 'held']);
      expect(states[0].initial, isFalse);
      expect(states[1].initial, isFalse);
      expect(states[2].initial, isFalse);
    });

    test('util.styio parses as two consts, a function and no data cables', () {
      final StyioModel m = parseStyio(utilStyio);
      expect(m.fns, <String>['clamp01']);
      expect(m.pipeline, isNull);
      expect(m.chains, isEmpty);
      expect(m.routes, isEmpty);
      expect(m.states, isEmpty);
      expect(
        m.consts.map((ConstDecl c) => '${c.name}=${c.value}'),
        <String>['gain=0.8', 'bias=0.02'],
      );
    });
  });

  group("the analyzer's one rule", () {
    test('an input route used fewer than twice is a finding', () {
      final List<Diagnostic> d = lintText(mainStyio);
      expect(d.length, 1);
      expect(d.single.ident, 'routeIn');
      expect(d.single.line, 3);
    });

    test('consuming the route clears the finding', () {
      final String fixed = mainStyio.replaceFirst('  emit staged', '  emit staged\n  emit routeIn');
      expect(lintText(fixed), isEmpty);
    });

    test('a buffer with no input route is clean', () {
      expect(lintText(utilStyio), isEmpty);
      expect(lintText(styioToml), isEmpty);
    });
  });

  group('the board is generated from the buffer', () {
    final GraphBoard board = buildGraph(
      parseStyio(mainStyio),
      fileName: 'main.styio',
      hanging: <String>{'routeIn'},
    );

    test('the data chain is layered at 196px pitch in one row', () {
      for (final List<Object> spec in <List<Object>>[
        <Object>['source', 64.0, 108.0, 'ORIGIN'],
        <Object>['normalize', 260.0, 108.0, 'PIPE'],
        <Object>['render', 456.0, 108.0, 'PIPE'],
        <Object>['routeOut', 652.0, 108.0, 'CHANNEL'],
      ]) {
        final GraphModule n = moduleNamed(board, spec[0] as String);
        expect(n.x, spec[1]);
        expect(n.y, spec[2]);
        expect(n.kind, spec[3]);
        expect(n.w, 96);
        expect(n.h, 48);
      }
      expect(
        board.modules.map((GraphModule m) => m.name),
        <String>['source', 'normalize', 'render', 'routeOut', 'bridge', 'main', 'state'],
      );
    });

    test('the fn sits in the control band on the cable its emit taps', () {
      final GraphModule main = moduleNamed(board, 'main');
      expect(main.kind, 'FN · ENTRY');
      expect(main.w, 110);
      expect(main.x, 253); // centred on NORMALIZE, the tapped cable's producer
      expect(main.y, 252);
    });

    test('STATE is 200px right of the first fn and lists every state', () {
      final GraphModule state = moduleNamed(board, 'state');
      expect(state.x, 563);
      expect(state.y, 244);
      expect(state.h, 91);
      expect(state.lamps.map((Lamp l) => l.name), <String>['running', 'idle', 'held']);
      expect(state.lamps.first.at.x, 583);
      expect(state.lamps.first.at.y, 286);
      expect(state.lamps[1].at.y, 301);
      expect(state.lamps[2].at.y, 316);
      // the proof's own initial flag is claimed by `state => running` first, so
      // no lamp rests lit — exactly what the artifact does at rest
      expect(board.restLamp, isNull);
      expect(board.runLamp!.name, 'running');
      expect(board.heldLamp!.name, 'held');
    });

    test('EXTERNAL hangs under its target with a fraid cable', () {
      final GraphModule bridge = moduleNamed(board, 'bridge');
      expect(bridge.kind, 'EXTERNAL');
      expect(bridge.x, 64);
      expect(bridge.y, 252);
      final BoardRoute route = board.routes.single;
      expect(route.name, 'routeIn');
      expect(route.bare, isTrue);
      expect(route.startX, 140);
      expect(route.startY, 252);
      expect(route.endX, 84);
      expect(route.endY, 182); // 26px short of the target's underside
      expect(board.strays.single.x, 84);
      expect(route.warnChip!.label, 'routeIn — never consumed');
      expect(board.jacks.contains(const Pt(84, 182)), isFalse);
    });

    test('a consumed route seats at both ends and wears its name', () {
      final String fixed = mainStyio.replaceFirst('  emit staged', '  emit staged\n  emit routeIn');
      final GraphBoard b = buildGraph(
        parseStyio(fixed),
        fileName: 'main.styio',
        hanging: <String>{},
      );
      final BoardRoute route = b.routes.single;
      expect(route.bare, isFalse);
      expect(route.endY, 156); // source's underside, seated
      expect(route.warnChip, isNull);
      expect(b.strays, isEmpty);
      expect(b.chips.any((Chip c) => c.label == 'routeIn'), isTrue);
    });

    test('cables carry the sag, the tangent angles and a mid-path buckle', () {
      final BoardCable first = board.cables.first;
      expect(first.curve.p0.x, 160);
      expect(first.curve.p0.y, 132);
      expect(first.curve.p3.x, 260);
      expect(first.curve.p3.y, 132);
      expect(first.curve.c1.y, 148); // sag 16 on a 100px gap
      expect(first.angleStart, closeTo(23.96, 0.01));
      expect(first.angleEnd, closeTo(-23.96, 0.01));
      expect(first.chip!.label, 'source');
      expect(first.chip!.center.x, closeTo(210, 0.5));
      expect(board.plugs.length, 6);
    });

    test('the emit feeler taps the cable that carries the value', () {
      final BoardTap tap = board.taps.single;
      expect(tap.chip.label, 'emit staged');
      expect(tap.point.x, closeTo(406, 0.5));
      expect(tap.point.y, closeTo(144, 0.5));
    });

    test('the pulse path is the data edges walked back from the channel', () {
      expect(
        board.pulsePath.map((BoardCable c) => c.label),
        <String>['source', 'staged', 'routeOut'],
      );
      expect(
        board.pulseModules.map((GraphModule m) => m.name),
        <String>['source', 'normalize', 'render'],
      );
      expect(board.frozenPulse!.x, 456);
      expect(board.frozenPulse!.y, 132);
      expect(board.sinkModule!.name, 'routeOut');
      expect(board.mainModule!.name, 'main');
    });

    test('bounds, plate title and the live caption are recomputed', () {
      expect(board.maxX, 796);
      expect(board.maxY, 480);
      expect(board.title, 'PIPELINE MAINFLOW — SIGNAL ROUTING');
      expect(board.caption, 'LIVE PROJECTION · MAIN.STYIO');
      expect(board.label, contains('source through staged through routeOut'));
      expect(board.label, contains('hanging input routes: routeIn'));
    });

    test('util.styio grows its own board: clamp01, gain, bias and no cables', () {
      final GraphBoard util = buildGraph(
        parseStyio(utilStyio),
        fileName: 'util.styio',
        hanging: <String>{},
      );
      expect(
        util.modules.map((GraphModule m) => m.name).toList(),
        <String>['clamp01', 'gain', 'bias'],
      );
      expect(moduleNamed(util, 'clamp01').x, 64);
      expect(moduleNamed(util, 'gain').x, 264);
      expect(moduleNamed(util, 'bias').x, 464);
      expect(moduleNamed(util, 'gain').kindText, '0.8');
      expect(util.cables, isEmpty);
      expect(util.stateLamps, isEmpty);
      expect(util.title, 'UTIL.STYIO — SIGNAL ROUTING');
    });
  });

  group('the tempo is read from the configuration buffer', () {
    test('styio.toml configures the machine', () {
      expect(parseTomlTempo(styioToml), 128.0);
      expect(parseTomlTempo('tempo = 87.5'), 87.5);
      expect(parseTomlTempo('steps = 16'), isNull);
    });
  });

  group('the lexer colours the buffer', () {
    test('styio keywords, names, operators and punctuation', () {
      final List<Token> toks = lexStyio('fn main(input) {');
      expect(toks.first.kind, TokenKind.keyword);
      expect(toks[2].text, 'main');
      expect(toks[2].kind, TokenKind.name);
      expect(toks.last.kind, TokenKind.punct);
    });

    test('toml sections, keys and values', () {
      expect(lexToml('[loop]').single.kind, TokenKind.name);
      final List<Token> kv = lexToml('tempo = 128.0');
      expect(kv[1].text, 'tempo');
      expect(kv[2].kind, TokenKind.operator);
      expect(kv[3].kind, TokenKind.literal);
    });
  });
}
