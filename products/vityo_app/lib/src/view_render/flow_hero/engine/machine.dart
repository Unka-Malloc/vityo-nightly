/// The machine: one charcoal panel holding a rail, the PROGRAM well, the
/// instrument body, the sixteen-step transport band and the status strip. This
/// file also owns the operator's state — buffers, tempo, the run, the interlock.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../ide/editor/document/document_state.dart';
import '../../../ide/workspace/workspace_document_store_types.dart';
import 'editor.dart';
import 'flow_board.dart';
import '../flow_model.dart';
import 'instruments.dart';
import '../tokens.dart';
import 'transport.dart';

/// ------------------------------------------------------------------ buffers ---
class BufferFile {
  BufferFile(
    this.name,
    this.text, {
    required this.lang,
    this.path,
    this.documentRevision,
    this.workspaceRevision,
    this.persistedText,
  });
  final String name;
  final String lang; // styio | toml | plain
  String text;

  /// Set for buffers backed by a real file on disk (workspace drawer opens);
  /// null for the built-in demo buffers, which have nowhere to save.
  final String? path;

  /// Workspace transaction revision for the persisted source, when loaded.
  int? documentRevision;

  /// Workspace-wide revision captured with [documentRevision].
  int? workspaceRevision;

  /// Last source content known to be persisted, used to detect external edits.
  String? persistedText;

  /// Monotonic editor revision used to preserve edits across async commits.
  int sourceRevision = 0;

  /// Edits since the last save. Demo buffers stay clean: they cannot persist.
  bool dirty = false;

  bool get drawable => lang == 'styio';
  bool get savable => path != null;

  /// Measured from the text, so the number changes when you type.
  int get byteSize => _utf8Length(text);
  int get lineCount => text.split('\n').length;
}

String langForPath(String path) {
  final String ext = path.contains('.')
      ? path.split('.').last.toLowerCase()
      : '';
  return switch (ext) {
    'sty' || 'styio' => 'styio',
    'toml' => 'toml',
    _ => 'plain',
  };
}

int _utf8Length(String s) {
  int n = 0;
  for (final int r in s.runes) {
    if (r < 0x80) {
      n += 1;
    } else if (r < 0x800) {
      n += 2;
    } else if (r < 0x10000) {
      n += 3;
    } else {
      n += 4;
    }
  }
  return n;
}

String _canonicalDocumentPath(String path) {
  final absolute = File(path).absolute.path.replaceAll(r'\', '/');
  return Platform.isWindows ? absolute.toLowerCase() : absolute;
}

const String kMainStyio =
    'pipeline mainFlow\n'
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

const String kUtilStyio =
    'fn clamp01(x) {\n'
    '  when x < 0 -> 0\n'
    '  when x > 1 -> 1\n'
    '  emit x\n'
    '}\n'
    'let gain := 0.8\n'
    'let bias := 0.02';

const String kStyioToml =
    '[workspace]\n'
    'name = "demo/app"\n'
    'rev = 142\n'
    '\n'
    '[loop]\n'
    'tempo = 128.0\n'
    'steps = 16';

/// The sixteen stations, in four quarters of four.
const List<String> kStepNames = <String>[
  'buffer',
  'tokens',
  'blocks',
  'save',
  'parse',
  'sema',
  'diag',
  'facts',
  'build',
  'unit',
  'golden',
  'bench',
  'launch',
  'trace',
  'observe',
  'receipt',
];
const List<String> kPhaseNames = <String>['Edit', 'Analyze', 'Test', 'Run'];

/// step 11 · golden
const int kFaultStep = 10;

/// ------------------------------------------------------------- run plumbing ---
enum RunPhase { idle, running, held }

enum LedMode { off, red, white, amber, dimRed }

enum Instrument { files, agent, run }

class Pulse {
  int seg = 0;
  double d = 0;
}

class Receipt {
  const Receipt(this.id, this.hunks);
  final String id;
  final int hunks;
}

class WorkbenchController extends ChangeNotifier {
  WorkbenchController() {
    files.addAll(<BufferFile>[
      BufferFile('main.styio', kMainStyio, lang: 'styio'),
      BufferFile('util.styio', kUtilStyio, lang: 'styio'),
      BufferFile('styio.toml', kStyioToml, lang: 'toml'),
    ]);
    activeFile = files.first;
    _graph = _buildGraphFor(activeFile);
    _analyzeMain();
    _analyzeActive();
    readTempoFromToml();
    cursorLine = 1;
    cursorColumn = 1;
  }

  final List<BufferFile> files = <BufferFile>[];
  final Map<String, BufferFile> _pathBuffers = <String, BufferFile>{};
  WorkspaceDocumentOperationStore? _documentStore;
  late BufferFile activeFile;
  bool showFlow = true;

  /// Bumped whenever the buffer is replaced wholesale, so the editor can take
  /// the new text without treating it as a keystroke.
  int bufferEpoch = 0;

  List<Diagnostic> activeDiags = <Diagnostic>[];
  List<Diagnostic> mainDiags = <Diagnostic>[];

  double bpm = 128;
  final List<bool> armed = List<bool>.filled(16, true);

  RunPhase phase = RunPhase.idle;
  int chaseStep = -1;
  bool faultStepLit = false;
  LedMode runLed = LedMode.off;
  bool verifyWhite = false;
  bool verifyRed = false;
  String status = 'LOOP IDLE';
  bool statusRed = false;
  double? lastRunSeconds;
  String lastRunKind = ''; // '' | 'held' | 'replay'
  int faults = 0;
  bool runInvite = true;
  bool runHeld = false;
  bool faulted = false;
  bool running = false;
  int _runToken = 0;

  bool authorized = false;
  bool authorizeArmed = false;
  final List<Receipt> receipts = <Receipt>[];

  Instrument instrument = Instrument.agent;

  int cursorLine = 1;
  int cursorColumn = 1;

  // ---- flow engine state ----
  GraphBoard _graph = GraphBoard();
  GraphBoard get graph => _graph;
  bool flowOn = false;
  bool flowHold = false;
  bool restLit = false;
  bool frozenVisible = false;
  bool sinkFlash = false;
  Timer? _sinkTimer;
  final List<Pulse> pulses = <Pulse>[];

  bool get flowTabEnabled => activeFile.drawable;

  String get instrumentTitle {
    switch (instrument) {
      case Instrument.files:
        return 'Explorer';
      case Instrument.agent:
        return 'Agent — Task 07';
      case Instrument.run:
        return 'Runtime';
    }
  }

  String get instrumentState {
    switch (instrument) {
      case Instrument.files:
        return 'demo/app';
      case Instrument.agent:
        return 'Review';
      case Instrument.run:
        return 'Loop Facts';
    }
  }

  String get tail {
    if (!showFlow) {
      return '${activeFile.name} · ${activeFile.lineCount} lines · LF';
    }
    return 'Styio · Graph · main.styio';
  }

  int get armedCount => armed.where((bool a) => a).length;

  double get stepMs => 60000 / bpm / 4;

  Diagnostic? get firstDiag => activeDiags.isEmpty ? null : activeDiags.first;

  // ------------------------------------------------------------------ graph ---
  GraphBoard _buildGraphFor(BufferFile f) => buildGraph(
    parseStyio(f.text),
    fileName: f.name,
    hanging: lintText(f.text).map((Diagnostic d) => d.ident).toSet(),
    glyphs: const FlutterGlyphs(),
  );

  void _analyzeMain() {
    mainDiags = lintText(files.first.text);
  }

  void _analyzeActive() {
    activeDiags = activeFile.drawable
        ? lintText(activeFile.text)
        : <Diagnostic>[];
  }

  /// Editing: the buffer is the instrument; the board answers every keystroke.
  void onBufferChanged(String text, {required int line, required int column}) {
    activeFile.text = text;
    activeFile.sourceRevision++;
    if (activeFile.savable) activeFile.dirty = true;
    cursorLine = line;
    cursorColumn = column;
    _analyzeActive();
    _analyzeMain();
    if (activeFile.drawable) {
      _graph = _buildGraphFor(activeFile);
    }
    if (activeFile.lang == 'toml') readTempoFromToml();
    notifyListeners();
  }

  void updateCursor(int line, int column) {
    if (line == cursorLine && column == cursorColumn) return;
    cursorLine = line;
    cursorColumn = column;
    notifyListeners();
  }

  void openFile(String name) {
    if (name != activeFile.name) loadFile(name);
    setNotation(false);
  }

  void loadFile(String name) {
    activeFile = files.firstWhere((BufferFile f) => f.name == name);
    bufferEpoch++;
    if (activeFile.drawable) _graph = _buildGraphFor(activeFile);
    _analyzeActive();
    _analyzeMain();
    cursorLine = 1;
    cursorColumn = 1;
    notifyListeners();
  }

  /// Open a real file from disk (workspace drawer). Re-activates the buffer if
  /// the path is already open; returns false when the file is not readable
  /// text (binary, permissions).
  Future<bool> openPath(String path) async {
    final BufferFile? opened = _pathBuffers[_canonicalDocumentPath(path)];
    if (opened != null) {
      activeFile = opened;
      bufferEpoch++;
      if (activeFile.drawable) _graph = _buildGraphFor(activeFile);
      _analyzeActive();
      notifyListeners();
      return true;
    }
    final String text;
    int? documentRevision;
    int? workspaceRevision;
    final store = _documentStore;
    if (store != null) {
      try {
        final snapshot = await store.readWorkspaceSnapshot(path);
        final document = snapshot.document;
        if (document == null) return false;
        text = document.text;
        documentRevision = document.revision;
        workspaceRevision = snapshot.workspaceRevision;
      } on Object {
        return false;
      }
    } else {
      try {
        text = await File(path).readAsString();
      } on FileSystemException {
        return false;
      } on FormatException {
        return false; // not UTF-8 text
      }
    }
    // Another request may have opened this path while the workspace read was
    // in flight. Keep the first live buffer as the sole editor authority.
    final BufferFile? raced = _pathBuffers[_canonicalDocumentPath(path)];
    if (raced != null) {
      activeFile = raced;
      bufferEpoch++;
      _refreshActiveDocument();
      notifyListeners();
      return true;
    }
    final BufferFile f = BufferFile(
      path.split(RegExp(r'[/\\]')).last,
      text,
      lang: langForPath(path),
      path: path,
      documentRevision: documentRevision,
      workspaceRevision: workspaceRevision,
      persistedText: text,
    );
    files.add(f);
    _pathBuffers[_canonicalDocumentPath(path)] = f;
    activeFile = f;
    bufferEpoch++;
    if (f.drawable) _graph = _buildGraphFor(f);
    _analyzeActive();
    cursorLine = 1;
    cursorColumn = 1;
    notifyListeners();
    return true;
  }

  /// ⌘S: write the active buffer back to its file. Returns false when there
  /// is nothing to save to (demo buffers) or the write failed.
  Future<bool> saveActive() async {
    final BufferFile f = activeFile;
    if (!f.savable || !f.dirty) return f.savable && !f.dirty;
    final store = _documentStore;
    if (store != null) {
      final sourceRevision = f.sourceRevision;
      final contents = f.text;
      try {
        final relativePath = store.relativeDocumentPath(f.path!);
        final snapshot = await store.readWorkspaceSnapshot(f.path!);
        final currentDocument = snapshot.document;
        final expectedWorkspaceRevision = f.workspaceRevision;
        if (currentDocument == null ||
            expectedWorkspaceRevision == null ||
            currentDocument.revision != f.documentRevision ||
            currentDocument.text != f.persistedText) {
          return false;
        }
        final receipt = await store.saveDocumentsAtomically(
          <DocumentState>[
            DocumentState(
              documentId: f.path!,
              text: contents,
              revision: f.documentRevision ?? 0,
            ),
          ],
          expectedWorkspaceRevision: expectedWorkspaceRevision,
          expectedDocumentRevisions: <String, int>{
            f.path!: f.documentRevision ?? 0,
          },
        );
        final revision = receipt.documentRevisions[relativePath];
        if (revision == null) return false;
        f.documentRevision = revision;
        f.workspaceRevision = receipt.workspaceRevision;
        f.persistedText = contents;
        f.dirty = f.sourceRevision != sourceRevision;
      } on Object {
        return false;
      }
      notifyListeners();
      return !f.dirty;
    }
    try {
      await File(f.path!).writeAsString(f.text);
    } on FileSystemException {
      return false;
    }
    f.dirty = false;
    f.persistedText = f.text;
    notifyListeners();
    return true;
  }

  /// Binds live file buffers to the existing revisioned workspace owner.
  /// Buffers opened before the Agent connection remain authoritative and are
  /// imported atomically before file callbacks are advertised.
  Future<void> attachWorkspaceDocumentStore(
    WorkspaceDocumentOperationStore store,
  ) async {
    _documentStore = store;
    final snapshots = <(BufferFile, int, String, int)>[];
    var activeBufferChanged = false;
    for (final file in files.where((file) => file.savable)) {
      final sourceRevision = file.sourceRevision;
      final baseline = file.persistedText;
      final wasDirty = file.dirty;
      final workspaceSnapshot = await store.readWorkspaceSnapshot(file.path!);
      final document = workspaceSnapshot.document;
      file.workspaceRevision = workspaceSnapshot.workspaceRevision;
      if (document == null) {
        file.documentRevision = null;
        continue;
      }
      final changedDuringRead = file.sourceRevision != sourceRevision;
      if (baseline == null || document.text != baseline) {
        if (!wasDirty && !changedDuringRead) {
          file.text = document.text;
          file.persistedText = document.text;
          file.documentRevision = document.revision;
          file.workspaceRevision = workspaceSnapshot.workspaceRevision;
          file.sourceRevision++;
          activeBufferChanged =
              activeBufferChanged || identical(file, activeFile);
        } else {
          // Preserve local edits when the opened source no longer matches its
          // disk baseline. A later save must first resolve that conflict.
          file.documentRevision = null;
          file.workspaceRevision = null;
        }
        continue;
      }
      file.documentRevision = document.revision;
      file.workspaceRevision = workspaceSnapshot.workspaceRevision;
      file.persistedText = document.text;
      final currentRevision = file.sourceRevision;
      final currentText = file.text;
      if (document.text != currentText) {
        snapshots.add((
          file,
          currentRevision,
          currentText,
          workspaceSnapshot.workspaceRevision,
        ));
      }
    }
    if (snapshots.isEmpty) {
      if (activeBufferChanged) {
        _refreshActiveDocument();
        bufferEpoch++;
      }
      if (activeBufferChanged || files.any((file) => file.savable)) {
        notifyListeners();
      }
      return;
    }
    final observedWorkspaceRevisions = snapshots
        .map((snapshot) => snapshot.$4)
        .toSet();
    if (observedWorkspaceRevisions.length != 1) {
      throw StateError('Workspace changed while open buffers were attached.');
    }
    final expectedWorkspaceRevision = observedWorkspaceRevisions.single;
    final receipt = await store.saveDocumentsAtomically(
      snapshots.map(
        (snapshot) => DocumentState(
          documentId: snapshot.$1.path!,
          text: snapshot.$3,
          revision: snapshot.$1.documentRevision ?? 0,
        ),
      ),
      expectedWorkspaceRevision: expectedWorkspaceRevision,
      expectedDocumentRevisions: <String, int>{
        for (final snapshot in snapshots)
          snapshot.$1.path!: snapshot.$1.documentRevision ?? 0,
      },
    );
    for (final (file, sourceRevision, committedText, _) in snapshots) {
      final relativePath = store.relativeDocumentPath(file.path!);
      final revision = receipt.documentRevisions[relativePath];
      if (revision == null) {
        throw StateError(
          'The workspace omitted a committed document revision.',
        );
      }
      file.documentRevision = revision;
      file.workspaceRevision = receipt.workspaceRevision;
      file.persistedText = committedText;
      file.dirty = file.sourceRevision != sourceRevision;
    }
    if (activeBufferChanged ||
        snapshots.any((snapshot) => identical(snapshot.$1, activeFile))) {
      _refreshActiveDocument();
      bufferEpoch++;
    }
    notifyListeners();
  }

  BufferFile? openedBuffer(String absolutePath) =>
      _pathBuffers[_canonicalDocumentPath(absolutePath)];

  /// Reflects a committed Agent write only if no user edit arrived while the
  /// workspace transaction was pending.
  void acceptAgentDocumentWrite({
    required String absolutePath,
    required String text,
    required int expectedSourceRevision,
    required int documentRevision,
    required int workspaceRevision,
  }) {
    final file = openedBuffer(absolutePath);
    if (file == null) return;
    file.documentRevision = documentRevision;
    file.workspaceRevision = workspaceRevision;
    file.persistedText = text;
    if (file.sourceRevision != expectedSourceRevision) {
      file.dirty = true;
      notifyListeners();
      return;
    }
    file.text = text;
    file.sourceRevision++;
    file.dirty = false;
    if (identical(file, activeFile)) {
      _refreshActiveDocument();
      bufferEpoch++;
    }
    notifyListeners();
  }

  void _refreshActiveDocument() {
    _analyzeActive();
    _analyzeMain();
    if (activeFile.drawable) _graph = _buildGraphFor(activeFile);
    if (activeFile.lang == 'toml') readTempoFromToml();
  }

  void setInstrument(Instrument i) {
    instrument = i;
    notifyListeners();
  }

  void setNotation(bool flow) {
    if (flow && !flowTabEnabled) {
      return; // this buffer has no program to project
    }
    if (showFlow == flow) {
      if (flow) _graph = _buildGraphFor(activeFile);
      notifyListeners();
      return;
    }
    showFlow = flow;
    if (flow) _graph = _buildGraphFor(activeFile); // repaint graph truth
    notifyListeners();
  }

  // ------------------------------------------------------------------ tempo ---
  void setBpm(double v) {
    // floor 10: slow enough to watch a single signal think; ceiling 240
    bpm = math.min(240, math.max(10, v.roundToDouble()));
    notifyListeners();
  }

  void readTempoFromToml() {
    final double? t = parseTomlTempo(files.last.text);
    if (t != null) bpm = math.min(240, math.max(10, t.roundToDouble()));
  }

  // -------------------------------------------------------------- step row ---
  void toggleStep(int i) {
    if (running) return;
    if (faulted && i == kFaultStep) {
      _status('STEP 11 GOLDEN · 2 SUBPIXEL DIFFS · PRESS CLEAR', red: true);
      return;
    }
    armed[i] = !armed[i];
    notifyListeners();
  }

  void _restLeds() {
    chaseStep = -1;
    faultStepLit = false;
    notifyListeners();
  }

  void _status(String text, {bool red = false}) {
    status = text;
    statusRed = red;
    notifyListeners();
  }

  // -------------------------------------------------------------- the loop ---
  Future<void> run() async {
    if (running) return;
    if (faulted) {
      await replayFault();
      return;
    }
    running = true;
    phase = RunPhase.running;
    final int runGeneration = ++_runToken;
    final bool willHold = mainDiags.isNotEmpty;
    runHeld = true;
    runInvite = false; // the invitation is spent
    _restLeds();
    flowStart();
    notifyListeners();
    final Stopwatch clock = Stopwatch()..start();

    for (int i = 0; i < 16; i++) {
      if (runGeneration != _runToken) return;
      if (i > 0) {
        // the chase is one light: extinguish where it has been
        if (chaseStep == i - 1) chaseStep = -1;
      }
      if (armed[i]) chaseStep = i;
      _status(
        'RUNNING · ${(i + 1).toString().padLeft(2, '0')} ${kStepNames[i].toUpperCase()}',
        red: true,
      );
      if (i.isEven) flowEmit();
      if (i == kFaultStep && willHold) {
        await Future<void>.delayed(
          Duration(microseconds: (stepMs * 1000).round()),
        );
        if (runGeneration != _runToken) return;
        chaseStep = -1;
        faultStepLit = true;
        verifyRed = true;
        flowFreeze();
        final double secs = clock.elapsedMilliseconds / 1000;
        status = 'HELD · STEP 11 GOLDEN · REPLAY OR CLEAR';
        statusRed = true;
        lastRunSeconds = secs;
        lastRunKind = 'held';
        faults = 1;
        runHeld = false;
        running = false;
        faulted = true;
        phase = RunPhase.held;
        notifyListeners();
        return; // the loop stops here; steps 12–16 never ran
      }
      await Future<void>.delayed(
        Duration(microseconds: (stepMs * 1000).round()),
      );
    }
    if (runGeneration != _runToken) return;
    // full pass: every station clean
    chaseStep = -1;
    final double secs = clock.elapsedMilliseconds / 1000;
    lastRunSeconds = secs;
    lastRunKind = '';
    faults = 0;
    status = 'PASS · 16/16 · GOLDEN CLEAN';
    statusRed = false;
    verifyWhite = true;
    verifyRed = false;
    flowStop();
    runHeld = false;
    running = false;
    phase = RunPhase.idle;
    notifyListeners();
  }

  /// HELD is not a dead end: the same eleven steps, as slow as the tempo is set.
  Future<void> replayFault() async {
    running = true;
    phase = RunPhase.running;
    final int runGeneration = ++_runToken;
    runHeld = true;
    notifyListeners();
    faultStepLit = false;
    chaseStep = -1;
    verifyRed = false;
    frozenVisible = false;
    flowStart();
    notifyListeners();
    final Stopwatch clock = Stopwatch()..start();
    for (int i = 0; i <= kFaultStep; i++) {
      if (runGeneration != _runToken) return;
      if (i > 0 && chaseStep == i - 1) chaseStep = -1;
      if (armed[i]) chaseStep = i;
      _status(
        'REPLAY · STEP ${(i + 1).toString().padLeft(2, '0')} ${kStepNames[i].toUpperCase()}'
        ' · FAULT IN ${kFaultStep - i}',
        red: true,
      );
      if (i.isEven) flowEmit();
      // stepMs reads bpm live: the operator can slow the microscope as the
      // fault approaches
      await Future<void>.delayed(
        Duration(microseconds: (stepMs * 1000).round()),
      );
      if (runGeneration != _runToken) return;
    }
    chaseStep = -1;
    faultStepLit = true;
    verifyRed = true;
    flowFreeze();
    final double secs = clock.elapsedMilliseconds / 1000;
    status = 'HELD · STEP 11 GOLDEN · REPLAY OR CLEAR';
    statusRed = true;
    lastRunSeconds = secs;
    lastRunKind = 'replay';
    runHeld = false;
    running = false;
    notifyListeners();
  }

  void clearLoop() {
    _runToken++;
    running = false;
    faulted = false;
    phase = RunPhase.idle;
    runHeld = false;
    chaseStep = -1;
    faultStepLit = false;
    verifyWhite = false;
    verifyRed = false;
    flowReset();
    status = 'LOOP IDLE';
    statusRed = false;
    lastRunSeconds = null;
    lastRunKind = '';
    faults = 0;
    notifyListeners();
  }

  // ------------------------------------------------------- permission gate ---
  void authorize() {
    if (authorized || authorizeArmed) return;
    authorizeArmed = true;
    notifyListeners();
    Timer(const Duration(milliseconds: 700), () {
      authorizeArmed = false;
      authorized = true;
      receipts.insert(0, const Receipt('0142', 3));
      notifyListeners();
    });
  }

  // ------------------------------------------------------------ flow engine ---
  void flowStart() {
    flowOn = true;
    flowHold = false;
    frozenVisible = false;
    restLit = false;
  }

  void flowFreeze() {
    flowOn = false;
    flowHold = true;
    pulses.clear();
    frozenVisible = _graph.frozenPulse != null;
  }

  void flowStop() {
    flowOn = false;
    restLit = true;
  }

  void flowReset() {
    flowOn = false;
    flowHold = false;
    pulses.clear();
    frozenVisible = false;
    restLit = false;
    sinkFlash = false;
  }

  /// Called by the step loop: one signal every two steps, at most five in
  /// flight — a full line drops the beat rather than queuing.
  void flowEmit() {
    if (!flowOn || flowHold || _graph.pulsePath.isEmpty || pulses.length >= 5) {
      return;
    }
    pulses.add(Pulse());
  }

  void tickPulses(double dtMs, {required bool visible}) {
    final int n = _graph.pulsePath.length;
    if (flowHold) return;
    bool changed = false;
    for (final Pulse p in pulses) {
      p.d += 0.55 * (bpm / 128) * dtMs;
      while (p.seg < n && p.d >= _graph.pulsePath[p.seg].curve.length) {
        p.d -= _graph.pulsePath[p.seg].curve.length;
        p.seg++;
        if (p.seg == n && visible) {
          sinkFlash = true;
          _sinkTimer?.cancel();
          _sinkTimer = Timer(const Duration(milliseconds: 140), () {
            sinkFlash = false;
            notifyListeners();
          });
        }
      }
      changed = true;
    }
    pulses.removeWhere((Pulse p) => p.seg >= n);
    if (changed || pulses.isNotEmpty) notifyListeners();
  }

  bool moduleLampLit(GraphModule m) {
    final List<GraphModule> path = _graph.pulseModules;
    for (final Pulse p in pulses) {
      if (p.seg < path.length && identical(path[p.seg], m)) return true;
    }
    return false;
  }

  bool stateLampLit(Lamp l) {
    if (identical(l, _graph.runLamp)) return flowOn;
    if (identical(l, _graph.heldLamp)) return flowHold;
    if (identical(l, _graph.restLamp)) return restLit;
    return false;
  }

  bool stateLampAmber(Lamp l) => identical(l, _graph.restLamp);

  /// The entry function stays lit while a run is live or held.
  bool get mainModuleLit => flowOn || flowHold;

  bool get sinkLampLit => sinkFlash;

  @override
  void dispose() {
    _sinkTimer?.cancel();
    super.dispose();
  }
}

/// --------------------------------------------------------------- the shell ---
class Machine extends StatefulWidget {
  const Machine({super.key, required this.controller});
  final WorkbenchController controller;

  @override
  State<Machine> createState() => _MachineState();
}

class _MachineState extends State<Machine> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  /// Space runs, C clears, arrows set the tempo; a focused text field keeps its
  /// native keys.
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    final WorkbenchController c = widget.controller;
    final FocusNode? f = FocusManager.instance.primaryFocus;
    final bool typing =
        f?.context?.widget is EditableText ||
        (f?.context?.findAncestorWidgetOfExactType<EditableText>() != null);
    if (typing) return false;
    if (e.logicalKey == LogicalKeyboardKey.keyC) {
      c.clearLoop();
      return true;
    }
    if (e.logicalKey == LogicalKeyboardKey.space) {
      if (c.faulted) {
        c.clearLoop();
      } else {
        unawaited(c.run());
      }
      return true;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      c.setBpm(c.bpm + 1);
      return true;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      c.setBpm(c.bpm - 1);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final WorkbenchController c = widget.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (BuildContext context, Widget? _) => Stack(
        children: <Widget>[
          Column(
            children: <Widget>[
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    InstrumentRail(controller: c),
                    Expanded(child: _ProgramPanel(controller: c)),
                    InstrumentBody(controller: c),
                  ],
                ),
              ),
              LoopBar(controller: c),
              StatusStrip(controller: c),
            ],
          ),
        ],
      ),
    );
  }
}

/// --------------------------------------------------------------- the rail ---
class InstrumentRail extends StatelessWidget {
  const InstrumentRail({super.key, required this.controller});
  final WorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    Widget key(Instrument inst, void Function(Path p) glyph, String label) {
      final bool on = controller.instrument == inst;
      return Semantics(
        label: label,
        button: true,
        selected: on,
        child: SizedBox(
          width: 56,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              CapKey(
                width: 44,
                height: 44,
                pressed: on,
                tooltip: label,
                onTap: () => controller.setInstrument(inst),
                child: HandIcon(
                  painter: glyph,
                  size: 20,
                  color: on ? C.bone : C.silk,
                ),
              ),
              const SizedBox(height: 5),
              Led(on: on, size: 6, color: C.orange),
            ],
          ),
        ),
      );
    }

    return Container(
      width: 68,
      decoration: const BoxDecoration(
        color: C.panelHi,
        border: Border(right: BorderSide(color: C.seamLo)),
      ),
      child: Stack(
        children: <Widget>[
          const Positioned(
            top: 0,
            bottom: 0,
            right: 1,
            width: 1,
            child: ColoredBox(color: C.seamHi),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(
              children: <Widget>[
                key(Instrument.files, Pen.folder, 'Files'),
                const SizedBox(height: 14),
                key(Instrument.agent, Pen.spark, 'Agent'),
                const SizedBox(height: 14),
                key(Instrument.run, Pen.pulse, 'Run'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// ---------------------------------------------------------- the PROGRAM well ---
class _ProgramPanel extends StatelessWidget {
  const _ProgramPanel({required this.controller});
  final WorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    final WorkbenchController c = controller;
    const Widget gap = SizedBox(width: 14);
    return Container(
      decoration: const BoxDecoration(
        color: C.recess,
        border: Border(right: BorderSide(color: C.seamLo)),
      ),
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
                  const Text('PROGRAM', style: T.silkHi),
                  gap,
                  NotationTabs(controller: c),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        c.tail,
                        style: T.silkDim,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.clip,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: c.showFlow && c.flowTabEnabled ? 0 : 1,
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.all(14),
                  child: Well(radius: 6, child: FlowBoard(controller: c)),
                ),
                SourceEditor(controller: c),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class NotationTabs extends StatelessWidget {
  const NotationTabs({super.key, required this.controller});
  final WorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    final bool enabled = controller.flowTabEnabled;
    Widget tab(
      String label,
      void Function(Path p) glyph,
      bool on, {
      VoidCallback? onTap,
      String? tooltip,
      bool disabled = false,
    }) {
      return CapKey(
        height: 26,
        radius: 3,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        disabled: disabled,
        tooltip: tooltip,
        gradient: on
            ? const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[Colors.white, C.paperLow],
              )
            : const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[C.keyCap, C.keyCapLow],
              ),
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            HandIcon(painter: glyph, size: 13, color: on ? C.well : C.silk),
            const SizedBox(width: 6),
            Text(
              label,
              style: T.tab.copyWith(color: on ? C.well : C.silk),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Focus(
        // a real tablist: ←/→ switches notation and the roving tabindex keeps
        // only the active tab in the tab order
        onKeyEvent: (FocusNode node, KeyEvent event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
              event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            controller.setNotation(!controller.showFlow);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            tab(
              'FLOW',
              Pen.patchCable,
              controller.showFlow && enabled,
              disabled: !enabled,
              tooltip: enabled ? null : 'FLOW 只投影 styio 程序',
              onTap: () => controller.setNotation(true),
            ),
            const SizedBox(width: 4),
            tab(
              'SOURCE',
              Pen.brackets,
              !controller.showFlow || !enabled,
              onTap: () => controller.setNotation(false),
            ),
          ],
        ),
      ),
    );
  }
}

/// ------------------------------------------------------------- status strip ---
class StatusStrip extends StatelessWidget {
  const StatusStrip({super.key, required this.controller});
  final WorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    final WorkbenchController c = controller;
    final String last = c.lastRunSeconds == null
        ? 'Last Run —'
        : 'Last Run ${c.lastRunSeconds!.toStringAsFixed(1)}s'
              '${c.lastRunKind.isEmpty ? '' : ' · ${c.lastRunKind}'}';
    return SeamTop(
      color: C.panelHi,
      child: SizedBox(
        height: 32,
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: <Widget>[
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 250),
                    child: StatusLeftLive(controller: c),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const NeverScrollableScrollPhysics(),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const _Silk('Rev 0142'),
                          const SizedBox(width: 18),
                          const _Silk('Workspace demo/app'),
                          const SizedBox(width: 18),
                          _Silk(last),
                          const SizedBox(width: 18),
                          const _Silk('Space Run · C Clear · ↑↓ Tempo'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  _Silk('Ln ${c.cursorLine}, Col ${c.cursorColumn}'),
                  const SizedBox(width: 14),
                  const _Silk('Demonstration data — synthetic'),
                ],
              ),
            ),
            ..._screws(),
          ],
        ),
      ),
    );
  }

  List<Widget> _screws() => const <Widget>[
    Positioned(left: 6, bottom: 6, child: Screw(angle: 41)),
    Positioned(right: 6, bottom: 6, child: Screw(angle: 78)),
  ];
}

class StatusLeftLive extends StatelessWidget {
  const StatusLeftLive({super.key, required this.controller});
  final WorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    final WorkbenchController c = controller;
    return Row(
      children: <Widget>[
        const Text('VITYO', style: T.maker),
        const SizedBox(width: 7),
        const Led(on: true, size: 6),
        const SizedBox(width: 10),
        Led(on: true, size: 6, color: c.statusRed ? C.red : C.orange),
        const SizedBox(width: 10),
        Text(
          c.status,
          style: T.monoBold.copyWith(letterSpacing: 1.1, color: C.silkHi),
        ),
      ],
    );
  }
}

class _Silk extends StatelessWidget {
  const _Silk(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: T.silk,
    maxLines: 1,
    softWrap: false,
    overflow: TextOverflow.clip,
  );
}

/// A 10px fastener head with a rotated slot — the machine's only exposed
/// hardware.
class Screw extends StatelessWidget {
  const Screw({super.key, this.angle = 24});
  final double angle;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 10,
    height: 10,
    child: CustomPaint(painter: _ScrewPainter(angle)),
  );
}

class _ScrewPainter extends CustomPainter {
  _ScrewPainter(this.angle);
  final double angle;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(
      c,
      5,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.3, -0.4),
          colors: <Color>[Color(0xFF3C3C3C), Color(0xFF151515)],
          stops: <double>[0, 0.7],
        ).createShader(Rect.fromCircle(center: c, radius: 5)),
    );
    canvas.drawCircle(
      c,
      5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x66000000),
    );
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(angle * math.pi / 180);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-3.5, -0.7, 7, 1.4),
        const Radius.circular(1),
      ),
      Paint()..color = const Color(0xFF050505),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ScrewPainter old) => old.angle != angle;
}
