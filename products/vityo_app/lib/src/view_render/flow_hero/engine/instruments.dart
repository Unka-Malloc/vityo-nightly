/// The right-hand instrument body: the agent's numbered task rows with their
/// permission interlock and receipts, the explorer's real file rows, and the
/// runtime's fact table. One instrument at a time — an unfit instrument simply
/// does not appear.
library;

import 'package:flutter/material.dart';

import 'machine.dart';
import '../tokens.dart';

class InstrumentBody extends StatelessWidget {
  const InstrumentBody({super.key, required this.controller});
  final WorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    final WorkbenchController c = controller;
    return Container(
      width: 322,
      color: C.recess,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SeamBottom(
            child: Container(
              height: 38,
              color: C.panel,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: <Widget>[
                  Text(c.instrumentTitle, style: T.silkHi),
                  const Spacer(),
                  Text(c.instrumentState, style: T.silkDim),
                ],
              ),
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: c.instrument.index,
              children: <Widget>[
                FilesInstrument(controller: c),
                AgentInstrument(controller: c),
                RunInstrument(controller: c),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// ------------------------------------------------------------------ agent ---
class AgentInstrument extends StatelessWidget {
  const AgentInstrument({super.key, required this.controller});
  final WorkbenchController controller;

  static const List<List<String>> _rows = <List<String>>[
    <String>['READ', 'main.styio'],
    <String>['PLAN', '3 hunks'],
    <String>['EDIT', 'lines 4–9'],
    <String>['VERIFY', 'run golden'],
    <String>['RECEIPT', 'pending'],
  ];

  @override
  Widget build(BuildContext context) {
    final WorkbenchController c = controller;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Column(
              children: <Widget>[
                for (int i = 0; i < _rows.length; i++) ...<Widget>[
                  if (i > 0) const SizedBox(height: 2),
                  SizedBox(
                    height: 30,
                    child: Row(
                      children: <Widget>[
                        SizedBox(
                          width: 22,
                          child: Text(
                            '${i + 1}'.padLeft(2, '0'),
                            style: T.monoMed.copyWith(
                              color: C.orange,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              style: T.mono,
                              children: <InlineSpan>[
                                TextSpan(text: _rows[i][0]),
                                TextSpan(
                                  text: ' ${_rows[i][1]}',
                                  style: T.mono.copyWith(color: C.silk),
                                ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (i < 3)
                          const Led(on: true, size: 6, color: C.paper)
                        else if (i == 3)
                          Led(
                            on: c.verifyWhite || c.verifyRed,
                            size: 6,
                            color: c.verifyRed ? C.red : C.paper,
                          )
                        else
                          Led(on: c.authorized, size: 6, color: C.paper),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          _Gate(controller: c),
          _Receipts(receipts: c.receipts),
        ],
      ),
    );
  }
}

class _Gate extends StatelessWidget {
  const _Gate({required this.controller});
  final WorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    final WorkbenchController c = controller;
    final bool done = c.authorized;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      child: Well(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Led(
                    on: true,
                    size: 6,
                    color: done ? C.paper : C.red,
                    blink: !done && !c.authorizeArmed,
                  ),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'PERMISSION GATE · REQUIRES OPERATOR',
                    style: T.silk,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 9),
            AuthKey(controller: c),
            const SizedBox(height: 9),
            const Text('Agent 无法自行落章 · 验证回执在授权后签发', style: T.fine),
          ],
        ),
      ),
    );
  }
}

/// The largest control in the system: 44px, condensed white legend, a padlock
/// beside it — and a key that has physically stayed down once latched.
class AuthKey extends StatefulWidget {
  const AuthKey({super.key, required this.controller});
  final WorkbenchController controller;

  @override
  State<AuthKey> createState() => _AuthKeyState();
}

class _AuthKeyState extends State<AuthKey> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sync);
    _pulse.dispose();
    super.dispose();
  }

  void _sync() {
    final bool wants = !widget.controller.authorized;
    if (wants && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!wants && _pulse.isAnimating) {
      _pulse.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final WorkbenchController c = widget.controller;
    final String label = c.authorized
        ? 'AUTHORIZED'
        : (c.authorizeArmed ? 'ARMED — APPLYING…' : 'AUTHORIZE — APPLY 3 HUNKS');
    return AnimatedBuilder(
      animation: _pulse,
      builder: (BuildContext context, Widget? _) => Semantics(
        button: true,
        enabled: !c.authorized,
        label: label,
        child: CapKey(
          height: 44,
          latched: c.authorized,
          glow: c.authorized ? 0 : _pulse.value,
          tooltip: c.authorized ? null : 'Authorize the agent’s patch',
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[C.redBright, C.redDeep],
          ),
          onTap: c.authorize,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              HandIcon(
                painter: c.authorized ? Pen.lockOpen : Pen.lockClosed,
                size: 14,
                color: c.authorized ? C.silk : Colors.white,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  style: T.auth.copyWith(
                    color: c.authorized ? C.silk : Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Receipts extends StatelessWidget {
  const _Receipts({required this.receipts});
  final List<Receipt> receipts;

  @override
  Widget build(BuildContext context) {
    if (receipts.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(14, 26, 14, 14),
        child: Text(
          'No receipts · awaiting first authorization',
          style: T.silkDim,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final Receipt r in receipts)
            SizedBox(
              height: 28,
              child: Row(
                children: <Widget>[
                  const Led(on: true, size: 6, color: C.paper),
                  const SizedBox(width: 9),
                  Text(
                    'RECEIPT ${r.id}',
                    style: T.monoData.copyWith(
                      color: C.paper,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Flexible(
                    child: Text(
                      'VERIFIED · ${r.hunks} HUNKS',
                      style: T.monoData.copyWith(color: C.silkHi),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// --------------------------------------------------------------- explorer ---
class FilesInstrument extends StatelessWidget {
  const FilesInstrument({super.key, required this.controller});
  final WorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    final WorkbenchController c = controller;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('EXPLORER · DEMO/APP', style: T.silk),
          ),
          for (final BufferFile f in c.files)
            _FileRow(
              file: f,
              open: f.name == c.activeFile.name,
              onTap: () => c.openFile(f.name),
            ),
        ],
      ),
    );
  }
}

class _FileRow extends StatefulWidget {
  const _FileRow({required this.file, required this.open, required this.onTap});

  final BufferFile file;
  final bool open;
  final VoidCallback onTap;

  @override
  State<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends State<_FileRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bool toml = widget.file.lang == 'toml';
    return Semantics(
      button: true,
      selected: widget.open,
      label: 'Open ${widget.file.name}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            height: 30,
            decoration: BoxDecoration(
              color: _hover ? const Color(0x08FFFFFF) : null,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Row(
              children: <Widget>[
                Led(on: widget.open, size: 6, color: C.orange),
                const SizedBox(width: 10),
                HandIcon(
                  painter: toml ? Pen.slider : Pen.patchLink,
                  size: 13,
                  color: C.silk,
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(widget.file.name, style: T.mono)),
                const SizedBox(width: 10),
                Text('${widget.file.byteSize} B', style: T.mono.copyWith(color: C.silk)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// ---------------------------------------------------------------- runtime ---
class RunInstrument extends StatelessWidget {
  const RunInstrument({super.key, required this.controller});
  final WorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    final WorkbenchController c = controller;
    final String last = c.lastRunSeconds == null
        ? '—'
        : '${c.lastRunSeconds!.toStringAsFixed(1)}s'
            '${c.lastRunKind.isEmpty ? '' : ' · ${c.lastRunKind}'}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('RUNTIME · LOOP FACTS', style: T.silk),
          ),
          _Fact(keyText: 'TEMPO', value: '${c.bpm.toStringAsFixed(1)} BPM'),
          _Fact(keyText: 'LAST RUN', value: last),
          _Fact(keyText: 'ARMED', value: '${c.armedCount}/16'),
          _Fact(keyText: 'FAULTS', value: '${c.faults}'),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.keyText, required this.value});
  final String keyText;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minHeight: 30),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: C.factRule)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(keyText, style: T.mono.copyWith(color: C.silk)),
            Text(
              value,
              style: T.mono.copyWith(
                color: C.paper,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
}
