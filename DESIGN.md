---
name: Vityo — Step-Row Workbench
description: "The Agent-Native IDE as an early-80s rhythm machine: a sixteen-step loop you program by hand."
colors:
  signal-red: "#ff3b30"
  signal-red-bright: "#ff5a4d"
  signal-red-deep: "#e02820"
  signal-orange: "#ff9a00"
  signal-yellow: "#ffe100"
  paper-white: "#f2f2f2"
  paper-low: "#dcdcdc"
  room-black: "#0b0b0b"
  panel-charcoal: "#1a1a1a"
  chassis-highlight: "#212121"
  recess-black: "#121212"
  well-black: "#0e0e0e"
  seam-light: "#2d2d2d"
  seam-shadow: "#000000"
  module-face-hi: "#1f1f1f"
  module-face-lo: "#171717"
  chip-label: "#9a9a9a"
  chip-warn: "#151310"
  chip-cv: "#141414"
  terminal-ring: "#3a3a3a"
  key-cap: "#2b2b2b"
  key-cap-low: "#1e1e1e"
  led-off: "#2a2a2a"
  plug-body: "#242424"
  plug-ring: "#4c4c4c"
  silk: "#8d8d8d"
  silk-high: "#c9c9c9"
  silk-dim: "#6f6f6f"
  gutter-grey: "#828282"
  bone: "#e9e7e1"
typography:
  display:
    fontFamily: "IBM Plex Sans Condensed, IBM Plex Sans, sans-serif"
    fontSize: "14px"
    fontWeight: 700
    lineHeight: 1
    letterSpacing: "0.08em"
  key:
    fontFamily: "IBM Plex Sans Condensed, IBM Plex Sans, sans-serif"
    fontSize: "14px"
    fontWeight: 700
    lineHeight: 1
    letterSpacing: "0.1em"
  key-small:
    fontFamily: "IBM Plex Sans Condensed, IBM Plex Sans, sans-serif"
    fontSize: "11px"
    fontWeight: 700
    lineHeight: 1
    letterSpacing: "0.1em"
  silk:
    fontFamily: "IBM Plex Sans, system-ui, sans-serif"
    fontSize: "11px"
    fontWeight: 600
    lineHeight: 1.5
    letterSpacing: "0.12em"
  body:
    fontFamily: "IBM Plex Sans, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.6
  code:
    fontFamily: "IBM Plex Mono, ui-monospace, monospace"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: "24px"
  data:
    fontFamily: "IBM Plex Mono, ui-monospace, monospace"
    fontSize: "11px"
    fontWeight: 500
    lineHeight: 1.5
    letterSpacing: "0.05em"
  graph-title:
    fontFamily: "IBM Plex Sans, system-ui, sans-serif"
    fontSize: "11px"
    fontWeight: 600
    lineHeight: 1
    letterSpacing: "0.14em"
  graph-name:
    fontFamily: "IBM Plex Sans, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 600
    lineHeight: 1
    letterSpacing: "0.12em"
  graph-label:
    fontFamily: "IBM Plex Mono, ui-monospace, monospace"
    fontSize: "11px"
    fontWeight: 500
    lineHeight: 1
    letterSpacing: "0.05em"
  graph-chip:
    fontFamily: "IBM Plex Mono, ui-monospace, monospace"
    fontSize: "11px"
    fontWeight: 500
    lineHeight: 1
    letterSpacing: "0.04em"
rounded:
  xs: "3px"
  sm: "4px"
  md: "5px"
  lg: "6px"
  round: "50%"
spacing:
  cap-gap: "4px"
  key-gap: "6px"
  block-gap: "8px"
  panel-pad: "14px"
  transport-pad: "12px"
  bay-gap: "16px"
components:
  step-key-edit:
    backgroundColor: "{colors.signal-red}"
    rounded: "{rounded.md}"
    height: "38px"
    width: "100%"
  step-key-analyze:
    backgroundColor: "{colors.signal-orange}"
    rounded: "{rounded.md}"
    height: "38px"
    width: "100%"
  step-key-test:
    backgroundColor: "{colors.signal-yellow}"
    rounded: "{rounded.md}"
    height: "38px"
    width: "100%"
  step-key-run:
    backgroundColor: "{colors.paper-white}"
    rounded: "{rounded.md}"
    height: "38px"
    width: "100%"
  key-run:
    backgroundColor: "{colors.signal-red}"
    textColor: "#ffffff"
    typography: "{typography.key}"
    rounded: "{rounded.md}"
    height: "36px"
    width: "100%"
  key-run-replay:
    backgroundColor: "{colors.signal-red}"
    textColor: "#ffffff"
    typography: "{typography.key}"
    rounded: "{rounded.md}"
    height: "36px"
    width: "100%"
  key-clear:
    backgroundColor: "{colors.key-cap}"
    textColor: "{colors.silk-high}"
    typography: "{typography.key-small}"
    rounded: "{rounded.md}"
    height: "36px"
    width: "100%"
  tempo-key:
    backgroundColor: "{colors.key-cap}"
    textColor: "{colors.silk-high}"
    typography: "{typography.key}"
    rounded: "{rounded.sm}"
    size: "30px"
  transport-well:
    backgroundColor: "{colors.well-black}"
    rounded: "{rounded.lg}"
    padding: "10px 12px"
    width: "220px"
  maker-mark:
    textColor: "{colors.silk-high}"
    typography: "{typography.display}"
  editor-buffer:
    backgroundColor: "{colors.recess-black}"
    textColor: "{colors.bone}"
    typography: "{typography.code}"
  gutter-column:
    textColor: "{colors.gutter-grey}"
    typography: "{typography.data}"
    width: "58px"
  editor-input:
    backgroundColor: "transparent"
    textColor: "transparent"
    typography: "{typography.code}"
  highlight-line:
    typography: "{typography.code}"
    height: "24px"
  diagnostic-strip:
    textColor: "{colors.signal-red}"
    typography: "{typography.data}"
    height: "27px"
    padding: "0 16px"
  explorer-row:
    textColor: "{colors.bone}"
    typography: "{typography.data}"
    rounded: "{rounded.xs}"
    height: "30px"
    width: "100%"
  rail-key:
    backgroundColor: "{colors.key-cap}"
    textColor: "{colors.silk}"
    rounded: "{rounded.md}"
    width: "44px"
    height: "44px"
  rail-icon:
    textColor: "{colors.silk}"
    size: "20px"
  rail-icon-selected:
    textColor: "{colors.bone}"
  authorize-key:
    backgroundColor: "{colors.signal-red}"
    textColor: "#ffffff"
    typography: "{typography.key}"
    rounded: "{rounded.md}"
    height: "44px"
  seven-seg-readout:
    backgroundColor: "{colors.well-black}"
    rounded: "{rounded.sm}"
    height: "37px"
    padding: "5px 9px 3px"
  notation-tab:
    backgroundColor: "{colors.key-cap}"
    textColor: "{colors.silk}"
    typography: "{typography.data}"
    rounded: "{rounded.xs}"
    height: "26px"
    padding: "0 12px"
  notation-tab-selected:
    backgroundColor: "{colors.paper-low}"
    textColor: "{colors.well-black}"
  icon:
    textColor: "{colors.silk}"
    size: "13px"
  icon-small:
    textColor: "{colors.silk}"
    size: "12px"
  icon-lock:
    textColor: "#ffffff"
    size: "14px"
  file-type-icon:
    textColor: "{colors.silk}"
    size: "13px"
  flow-well:
    backgroundColor: "{colors.well-black}"
    rounded: "{rounded.lg}"
    padding: "14px"
  graph-module:
    backgroundColor: "{colors.module-face-hi}"
    textColor: "{colors.silk-high}"
    typography: "{typography.graph-name}"
    rounded: "{rounded.md}"
    height: "48px"
  graph-module-glow:
    backgroundColor: "{colors.module-face-lo}"
  jack:
    backgroundColor: "{colors.well-black}"
    rounded: "{rounded.round}"
    size: "10px"
  jack-hole:
    backgroundColor: "{colors.seam-shadow}"
    rounded: "{rounded.round}"
    size: "3.2px"
  cable-chip:
    backgroundColor: "{colors.recess-black}"
    textColor: "{colors.chip-label}"
    typography: "{typography.graph-chip}"
    rounded: "{rounded.xs}"
    height: "16px"
  chip-cv:
    backgroundColor: "{colors.chip-cv}"
    textColor: "{colors.chip-label}"
    typography: "{typography.graph-chip}"
    rounded: "{rounded.xs}"
    height: "16px"
  chip-warn:
    backgroundColor: "{colors.chip-warn}"
    textColor: "{colors.signal-orange}"
    typography: "{typography.graph-chip}"
    rounded: "{rounded.xs}"
    height: "16px"
  signal-pulse:
    backgroundColor: "{colors.signal-red}"
    rounded: "{rounded.round}"
    size: "8px"
  sled-lamp:
    backgroundColor: "{colors.led-off}"
    rounded: "{rounded.round}"
    size: "6px"
  silk-label:
    textColor: "{colors.silk}"
    typography: "{typography.silk}"
---

<!-- POST-BUILD RECORD: this file documents the world established by the direction proof `.impeccable/mocks/vityo-step-row.html` (direction contract in its opening comment) and, since rev 9, its self-contained Flutter port in `products/vityo_app/lib/src/view_render/workbench_demo/`. It does not yet describe the shipping shell, whose surfaces are still the incumbent world — re-run `$impeccable document` in scan mode against them once they are converted. -->

# Design System: Vityo — Step-Row Workbench

## Overview

**Creative North Star: "The Workbench as an Early-80s Rhythm Machine"**

Vityo is drawn as a piece of hardware, not a window. The edit → analyze → test → run → observe
loop becomes a sixteen-step transport band along the bottom of a matte charcoal panel: four
quarters of four, red then orange then yellow then white, each step a physical cap with a slot
window cut into it and an LED above. There is no activity bar, no sidebar and no tab strip doing
the expressive work — the default IDE arrangement is refused as the thing that carries meaning,
and the loop is the surface.

Trust is rendered as machinery rather than explained in prose. A single chase light walks the
sixteen keys when RUN is pressed; when step 11 (golden) fails, the light stops, the LED holds
steady red and the machine will not advance past it — the key that started the run turns into
REPLAY, so the failure can be watched again as slowly as the tempo is set, and CLEAR is the way out.
Agent change is a
physical interlock: a key that says AUTHORIZE and a blinking gate lamp, which latches down flat
once pressed and only then issues the session's first RECEIPT. Nothing in this world is
negotiated through a toast or a notification — state is a lamp, a numeral, or a key that has
visibly moved.

Materials are specific and consistent: matte charcoal #1A1A1A, black recesses, black seams with a
one-pixel light lip, molded key caps lit from above, screw heads at the corners of the bottom strip, a
five percent plastic grain over the whole panel. LEDs are the only light source; a red seven-segment
readout is the only instrument. Type is silkscreened: IBM Plex Sans in condensed cuts for
display, 11px uppercase tracked labels for every machine name, IBM Plex Mono for code and data.
The proof carries bilingual fine print (Chinese glosses under English machine labels) — this is
silkscreen practice, not a second language layer.

The program itself is a score, and the panel is where it is read. The PROGRAM well opens on
**FLOW** — the program drawn as patched signal routing: modules built as miniature device panels,
data cables seated in jacks with plugs, and a run shown as red signal pulses riding those cables on
the same beat as the step row's chase light. The board is not a picture of a program: it is parsed
out of the open buffer and rebuilt on every keystroke, so a new line is a new module and a deleted
one takes its cable with it. **SOURCE** is one gesture away and stays canonical; the graph is a live
projection of the text, never a replacement for it. This is the vision the product
pins (PRODUCT.md principle 6, "Flow made visible", user-pinned 2026-09-30): dependencies, data flow
and the execution graph are shown graphically and first, with plain text the authority underneath.

**Key Characteristics:**
- Sixteen step keys in four phase quarters, read left to right as one sequence.
- FLOW is the first score in the PROGRAM well; SOURCE is one keystroke away and remains canonical.
- One chase light, one direction, extinguished behind itself — and one pulse stream on the beat.
- A signal pulse is the same class of light as an LED: one lamp grade, two sizes (a 3px sled, a 4px
  pulse).
- A fault holds: steady red LED, red numeral, no auto-clear — and the graph freezes rather than
  lying about state.
- Diagnostics are drawn, not listed: an unconsumed declaration is a cable that never reaches a jack.
- The board is generated, not illustrated: the graph is parsed out of the open buffer on every
  keystroke, and nothing on it is placed by hand.
- Permission is a key you press; a receipt is what its result looks like.
- No top bar: the machine starts with its work, and the faceplate signs itself at the bottom edge.
- Every control on the machine is fitted and does something; an unbuilt instrument, an empty bank or
  a tabless notation simply does not appear.
- Everything inside a well is real: the editor edits, the explorer opens, the graph answers the
  buffer, and the readouts report the machine's actual state.
- Depth from seams, recesses and key travel — no ambient shadow, no glass, no blur.
- LEDs, signal lamps, signal pulses and the seven-segment tube are the only emissive elements in the
  system.

## Colors

A near-monochrome charcoal machine painted with four signal colors, each of which means a phase or
a state rather than decorating a surface.

### Primary
- **Signal Red** (#ff3b30): the machine's authority and alarm. The chase LED when lit, the fault
  LED held, the RUN key and the AUTHORIZE key, the fault numeral, the focus ring, the editor caret
  and the diagnostic squiggle, selection wash (`rgba(255,59,48,.32)`).
- **Signal Red, bright / deep** (#ff5a4d / #e02820): the two stops of the red key cap's top-lit
  gradient, shared by RUN, the phase-one step keys and the gate key.

### Secondary
- **Analyze Orange** (#ff9a00): the phase-two quarter, the agent's task numbers, the amber
  instrument LED that marks which instrument is fitted, and numeric tokens in source.
- **Test Yellow** (#ffe100): the phase-three quarter and literal/state values in source.
- **Run White** (#f2f2f2): the phase-four quarter, the paper/pass/receipt LED, keyword weight
  (`font-weight: 600`), receipt ids, and the value column of instrument facts. Its gradient stop
  **Paper Low** (#dcdcdc) is the same family used by the selected instrument tab.

### Neutral
- **Room Black** (#0b0b0b): the void behind the machine; the page itself.
- **Panel Charcoal** (#1a1a1a): the machine's main face — the loop bar, panel heads, the editor's
  surroundings.
- **Chassis Highlight** (#212121): the raised strips — instrument rail and the bottom status strip.
  The name survives from the token's origin, but the chassis strip it was named for is gone.
- **Recess Black** (#121212): panel bodies that sit *below* the panel: the editor bed and the
  instrument bed.
- **Well Black** (#0e0e0e): the deepest level — the seven-segment tube, the permission gate, the
  FLOW well, the transport bay and every cable jack.
- **Seam Light / Seam Shadow** (#2d2d2d / #000000): the pair that makes every joint: a black cut
  plus a one-pixel light lip. Seam Light is also the 1px edge of a graph module, and Seam Shadow
  fills the 1.6px hole at the centre of every jack.
- **Module Face High / Low** (#1f1f1f / #171717): the graph module's top-lit gradient face — the
  panel material at graph scale, with a 1% white highlight along its top edge.
- **Chip Label** (#9a9a9a): the text on a label buckle riding a cable — one step brighter than Silk,
  so a buckle reads against the cable it sits on.
- **Key Cap / Key Cap Low** (#2b2b2b / #1e1e1e): the top-lit gradient of every dark key cap
  (rail, notation tab, dark step key, CLEAR).
- **LED Off** (#2a2a2a): an unlit LED lens or graph sled lamp; still a physical object, never a hole.
- **Terminal Ring** (#3a3a3a): the 1.5px collar around a cable jack, and the phase bracket rule
  under the step row.
- **Plug Body / Plug Ring** (#242424 / #4c4c4c): the darker sleeve and the metal band of the plug
  that seats a patched cable in its jack.
- **Silk** (#8d8d8d): all silkscreen labels, and the cable's own insulation — **Silk High** (#c9c9c9)
  for the label that names the active thing and for module names; **Silk Dim** (#6f6f6f) for fine
  print, empty states, control-voltage lines and cable labels.
- **Gutter Grey** (#828282): line numbers and comment tokens.
- **Bone** (#e9e7e1): source text, agent task descriptions, fact values — the reading color.

### Named Rules
**The LED Monopoly Rule.** Lamps are the only emitters: the machine's LEDs, the graph's sled lamps,
the signal pulses and the seven-segment tube. No key, panel, gate, module or cable gains a colored
halo, bloom or drop shadow to look alive; brightness changes belong to a lamp, and a lamp is a
3–7px circle.

**The One Lamp Grade Rule.** A signal pulse and a sled lamp use the identical glow recipe
(`drop-shadow(0 0 3px …)` plus `drop-shadow(0 0 8px …)` at the same alphas) — a pulse is not a
brighter lamp, it is a lamp that moves. Only its radius differs (4px pulse, 3px sled).

**The Static-vs-Blinking Rule.** Blinking is reserved for "an action is required now" (the
permission gate lamp, the diagnostic gutter lamp). A standing fact is a lamp held steady — the
unconsumed `routeIn` strand carries a steady amber sled, never a blink.

**The Meaning-Carrying Color Rule.** Color is phase and state, never decoration. Red = authority,
chase, fault. Orange = analyze, active instrument. Yellow = test, literals. White = run, paper,
receipt. A surface that wants a fifth accent does not get one.

**The Matte Rule.** Flat charcoal, black recesses, no gloss except the top-lit gradient of a molded
key cap. Nothing in this world reflects the room.

## Typography

**Display Font:** IBM Plex Sans Condensed (with IBM Plex Sans, sans-serif)
**Body Font:** IBM Plex Sans (with system-ui, sans-serif)
**Label/Mono Font:** IBM Plex Mono (with ui-monospace, monospace)

**Character:** Silkscreen and terminal. Condensed bold caps behave like a printed machine legend;
11px tracked uppercase Sans is the silkscreen; Mono carries every value the machine reports and
every line of source. The three faces are one family, so the whole panel reads as one industrial
print run.

### Hierarchy
- **Maker's mark** (700 condensed, 14px, line-height 1, 0.08em): the small VITYO signature at the left
  end of the status strip, beside a lit 6px LED. It is the only display type left in the system — the
  faceplate signs itself small at the bottom edge instead of carrying a title bar.
- **Key legend** (700 condensed, 11–15px, 0.08–0.1em): printed on key caps — the tempo adjust keys
  (15px `–` / `+`), RUN (14px), AUTHORIZE (14px), CLEAR (11px). Uppercase.
- **Data** (Mono 500, 11px, 0.05em): everything the machine reports — step numbers, tempo, receipts,
  agent steps, status text, tabs, loop facts, the cursor's `Ln n, Col n`, and the diagnostic strip.
  Numerals are the machine's voice.
- **Code** (Mono 400, 13px on a **24px line grid**): the editor bed. The line box is an integer
  (24px), not a ratio — the 1.85 multiplier it replaced drifted against the highlight layer over a
  long buffer. Gutter numbers are 11px in Gutter Grey on the same 24px rows, separated from source by
  a 1px #232323 rule. Token colors: keywords Paper White at 600, names/numbers orange, literals
  yellow, operators Silk High, punctuation Silk, comments Grey.
- **Body** (Sans 400, 13px, 1.6): bilingual fine print under labels and in empty states.
- **Label** (Sans 600, 11px, 0.12em, uppercase): every machine name — TEMPO · BPM, LOOP — SIXTEEN
  STEPS, PROGRAM, INSTRUMENT headings, phase names. The instrument rail is the one place with no
  silk at all: its keys are icons, and the whole word lives in the accessible name.
- **Graph title** (Sans 600, 11px, 0.14em, uppercase): the FLOW plate title, with its corner caption
  ("LIVE PROJECTION · MAIN.STYIO") in Silk Dim.
- **Module name** (Sans 600, 12px, 0.12em, uppercase): the name on a graph module (SOURCE,
  NORMALIZE, RENDER, ROUTEOUT, BRIDGE, MAIN, STATE) in Silk High, with its kind set beneath in 11px
  Mono Silk Dim (ORIGIN / PIPE / CHANNEL / EXTERNAL / FN · ENTRY).
- **Graph label** (Mono 500, 11px, 0.05em): cable names, the control-voltage annotations and the
  diagnostic line, in Silk Dim — the diagnostic alone is orange.
- **Chip label** (Mono 500, 11px, 0.04em): the text inside a label buckle on the board, in Chip
  Label; the warning buckle's text is the same size in Analyze Orange.

### Named Rules
**The 11px Floor Rule.** No UI text below 11px, no editor text below 13px. Measured in the build:
Bone on Recess Black is 15.15:1 and the 11px Silk label on Panel Charcoal is 5.24:1 — both clear
the 4.5:1 editor-text floor with room, and no label relies on Silk Dim alone for a required fact.

**The Silkscreen Rule.** A machine name is uppercase, tracked at 0.12em, set in Silk, and never
shouted with weight above 600 or size above 11px. Emphasis is a lighter silk, not a bigger font.

**The ≥1:1 Rule.** The graph is drawn on the board its own content requires — at least 760×480, larger
when the program is: bounds are `max(760, rightmost + 48)` by `max(480, lowest + 72)`, and the viewBox,
the min sizes and the dot grid are all set from them. The board fills the well it sits in
(`width: 100%; height: 100%`), so a roomy well draws a larger board and the graph's 11px labels grow
with it. The floor is fixed and not negotiable: at 760×480 one user unit is one CSS pixel, below that
the well pans, and no zoom level may push an 11px graph label under 11px. Scaling up is allowed;
scaling type down is not.

**Font policy open.** The proof sets IBM Plex Sans Condensed / IBM Plex Sans / IBM Plex Mono,
loaded from the Google Fonts CDN. PRODUCT.md's allow-list names IBM Plex Sans, Inter, Noto Sans and
Recursive for UI, and IBM Plex Mono, JetBrains Mono and Recursive for the editor; the Condensed cut
is not named on it, and the currently shipped app faces (Plus Jakarta Sans, Azeret Mono) are off it.
Reconciliation is still an open decision in PRODUCT.md — treat the family, not the cut, as settled.

## Layout

One vertical machine, top to bottom: a **main region**, a **full-width loop bar** — the sixteen-step
transport band, riding at the bottom with the **transport bay** recessed into its right end — and a
**32px status strip**. There is no top bar: the title strip that used to sit above everything was
paying 70px of height for a name, a tube and two keys, so its contents were either demoted (the name,
to a maker's mark in the status strip) or moved down into the transport (the tube and the keys). The
main region is a three-column grid — `68px` instrument rail, fluid editor, `322px` instrument body —
with the rail and instrument as fixed rails and the editor taking the slack.

The transport sits below the work, not above it. The loop bar was the first thing on the panel and it
earned its place; once it was doing its job it stopped needing to shout, so it reads as the machine's
transport mechanism — the band the work travels along — rather than as a headline. The bay at its
right end is a drum machine's transport: a 220px milled well holding TEMPO · BPM, a `–` / seven-segment
readout / `+` row, and CLEAR + RUN beneath. Controls live with the thing they control.

Nothing rides on the machine that the machine cannot drive, and nothing in a well is a picture. The
rail carries three instruments and no more; the transport carries one readout and four keys; the
editor edits, the explorer opens files, the graph answers the buffer, and the analyzer's findings are
the ones the loop actually obeys. A fixture that is not fitted is absent, not greyed — the machine
shows its real inventory, and that is what makes the inventory readable.

The loop bar's sixteen keys share the width with a 6px gap; each key is 38px tall with a slot window
cut near its top, its LED above, its number below, and a phase bracket grouping every four. Panels
are regions, not cards: square corners, a 38px panel head, and bodies that recess one level below the
face they sit in. Spacing is literal rather than tokenized — 4px inside a cap group, 6px between keys,
8px between label and fixture, 14px as panel padding, 12px as transport padding, 16px between the
loop track and its bay.

The **PROGRAM well** is the one panel that holds two notations. Its head carries the notation
tablist `[FLOW | SOURCE]` and a tail caption — `Styio · Graph · LF` on FLOW, `main.styio · 11 lines ·
LF` on SOURCE. There are no file tabs: with one notation per score and one source file, a tab strip
would hold a single live target and a dead one. The body below is a single 14px-padded well; the
graph board fills it down to its 760×480 floor and pans below that. The well does not resize between
notations.

Responsive behavior, as the proof establishes it:
- **≤720px** — one breakpoint, not two: with the top bar gone there is nothing left to wrap at 900px.
  The machine becomes a column: the instrument rail turns into a horizontal strip of 44×44px icon caps
  at the top (key width 56px, spacer hidden), the editor well takes `min-height: 554px` (a 480px graph
  board plus its padding and head), the instrument `min-height: 280px`, and the status strip wraps.
  Panel heads drop their fixed height, wrap their controls onto a second line, and hide the tail
  caption (`#pgmTail`). The transport bay uncouples from the loop bar and rides above it as a row —
  `width: auto`, the TEMPO · BPM caption hidden, the `–`/tube/`+` group fixed and CLEAR/RUN taking the
  slack, rising to 48px. **The step row never wraps**: it becomes a single horizontal track (`794px` of
  content) with `44px` fixed-width keys that scrolls sideways as one piece, phase brackets riding along
  with it. Notation tabs rise to 44px touch size. The FLOW well becomes a block and pans rather than
  cropping, holding the board at its 760×480 floor.

**The One Track Rule.** The sixteen steps are one horizontal object. They scroll, they never wrap,
and they never reflow into a grid — a loop read as two lines is no longer a loop.

**The Two Scores, One Well Rule.** FLOW and SOURCE share one well and one panel head; switching
notations swaps the body, never the frame. A second window, drawer or split for the graph breaks the
machine's single-panel discipline.

## Elevation & Depth

There are no ambient shadows and no box-shadow vocabulary in the usual sense; depth is entirely
physical, and it comes from five devices. **Seams** separate planes with a 1px pure-black cut plus
a 1px light lip on the lower side (#2d2d2d) — the panel's own edge catching light. **Recesses** put
a body below its face: the editor and instrument beds drop to #121212, and the seven-segment tube,
permission gate, FLOW well and transport bay drop to #0e0e0e with an inset shadow
(`inset 0 2px 6px rgba(0,0,0,.8)` and `inset 0 2px 8px rgba(0,0,0,.75)`) that reads as a milled well.
**Key travel** gives every cap a 3px black pad beneath it (`0 3px 0 rgba(0,0,0,.55)`), which
compresses to 1px while the cap moves down 2px under the finger. **Cable shadow** puts every graph
cable above its own shadow: the silk insulation is 2.5px with round caps, and a 4.5px black stroke at
`opacity: .45` sits 2px below it, so the cable reads as lying on the well floor rather than drawn on
it — the same top-light rule as every other fixture. **Light direction** is fixed and top-down: caps
carry a top-lit gradient and a 1px top highlight (`inset 0 1px 0 rgba(255,255,255,.22)`); the black
cut is always below.

The editor adds the one state that is not a shadow: **focus is a lit rim**. The buffer sits inside
`.editwrap`, and focusing it draws `inset 0 0 0 1px rgba(255,154,0,.28)` around the bed — a 1px amber
ring, no offset, no browser default. The textarea itself reports focus only through its red caret
(`caret-color: #ff3b30`), since a caret and a ring are different statements: the ring says "this
region is live", the caret says "this column is where you are".

The graph's hardware obeys the same law. A jack is a 5px circle filled Well Black with a 1.5px
Terminal Ring collar — a hole in the module face; a seated plug (#242424 body, #4c4c4c band) sits on
top of it, rotated to the cable's own tangent angle, so the cable visibly enters the hole. A module
box is a 1px #2d2d2d edge on a #1a1a1a face: it is the panel material again, one level up from the
well it sits in — never a floating card.

Texture supports the material at 5% — a 128px tiled plastic grain over the machine, blended
`overlay` at `opacity: .05`, invisible until you look for it. Screws (10px radial-gradient heads
with a rotated slot) sit at the status corners as physical fasteners, not decoration; with the top
bar gone they are the machine's only exposed hardware.

### Named Rules
**The Seam, Not the Border Rule.** Two adjacent planes are separated by a black cut and a light
lip. Never by a stroke, a card outline, or a shadow floating above a surface.

**The Flat-Until-Touched Rule.** Nothing floats. A key gains depth only when pressed; a lamp gains
light only when lit; a panel gains prominence only by moving up or down one material level.

## Shapes

Strictly rectilinear. Radii are tight and few — 3px for small caps, tabs and explorer rows, 4px for
the readout and the tempo adjust keys, 5px for anything a finger lands on (keys, step caps, the gate,
the rail cap) and for graph modules, 6px for the wells (FLOW and the transport bay). Panels and
regions have square corners because they are areas of the machine rather than cards — the editor bed
is a region, and its rows are ruled by the 24px line grid rather than by any border. Circles appear
only as hardware: LED lenses (4–7px), graph sled lamps (3px), signal pulses (4px), cable jacks (5px)
and screw heads (10px, `border-radius: 50%`).

The recurring silhouette is **the cap**: a rounded rectangle with a shadow pad beneath it; a step key
additionally cuts a slot window near its top edge (spanning from 18% to 82% of the width, 7px down,
5px tall, 2px radius). Step keys, rail keys, notation tabs, RUN/CLEAR and the 30×30px `–`/`+` adjust
keys are all this object at different scales — and the rail's cap is the square one, 44×44px, holding
a 20px stroke icon instead of a word. The second recurring form is the **bracket**: a 1px rule in
#3a3a3a spanning one quarter of the loop bar with a centered 11px phase name beneath it. The third is
the **module**: a miniature device panel — a 48px-tall rounded rectangle with a 1px #2d2d2d edge, a
top-lit gradient face (#1f1f1f → #171717) and a 1px white highlight along its top, a silk name in the
upper left, its kind beneath, a sled lamp in the top-right corner, and 5px jacks on
the edges that carry a connection. Modules are the graph's only container, and both their width and
the number of them are decided by the program: width is measured from the name and kind (floored at
96, and 110 for a `fn`), height is always 48px except STATE, which is `34 + 15 × states + 12`.

A jack appears only where a connection really is: a 5px Well Black circle with a 1.5px Terminal Ring
collar and a 1.6px black hole at its centre. It is created by the cable that lands in it, not by the
module — an unconnected edge has no jack to explain, and an empty hole would be the same lie as a
dead button.

**The Buckle Rule.** A label on the board never floats: it is a 16px chip buckled onto the path it
names, at that path's midpoint, with its width measured from its own text (`length × 6.8 + 16`). A
cable that cannot be labelled is a cable that should not have been drawn.

**The Square Icon Rule.** A control that names an area of the machine carries an icon, not a word,
and its cap is square. The icon is drawn inline at 20px in a 24-unit box with `stroke: currentColor`
and no fill, so one drawing serves both the rest and the selected state — Silk at rest, Bone when
its instrument is fitted. The whole word is not lost: it lives in the accessible name and the
tooltip.

**The Icon Restraint Rule.** Icons appear on four classes of thing and nowhere else: **action keys**
(RUN, CLEAR, AUTHORIZE, the rail), **tabs** (FLOW, SOURCE), **file types** (`.styio`, `.toml`) and
**warnings** (the diagnostic triangle). Panel heads, the loop head, the status strip, the agent's
step rows and the graph's own labels stay word-and-number. A numbered list keeps its numbers — order
matters more than an icon there — and a heading that already says what it is does not need to draw
it. Every icon is the same pen: a 24-unit box, 1.8px stroke, round caps and joins, `currentColor`,
no fill, no external set.

The graph's smaller hardware follows from those circles: a **plug** is a 13×8px rectangle at 3px
radius with a 1.5px band across it, rotated to the angle of the cable it terminates; a **strand** (a
cable end that reaches no jack) splits into three 1.2px bare tails. Nothing in the graph is drawn
with a corner radius outside the 3–6px family.

**The No-Pill Rule.** Buttons are caps, not pills. The only curves in the system belong to LEDs,
lamps, pulses, jacks and screws.

## Components

Every control is physical, top-lit, and moves 2px when pressed. There are no ghost buttons, no
flat text actions, and no control that responds without moving.

### Icons (one pen, four places)
Every icon in the machine is hand-drawn inline SVG in a 24-unit box: `stroke-width: 1.8`,
`stroke-linecap/linejoin: round`, `stroke: currentColor`, no fill, no icon font, no sprite, no
external package. Size is set per site (12px in the transport, 13px on tabs and keys, 14px on the
authorize key, 20px on the rail caps) and the drawing scales with it, so one pen reads at every size.

- **Wrapped, always.** Each icon sits in `<span class="ic">` — `inline-flex`, `flex:none`,
  `justify-content:center`, with `svg { display: block }` — so it neither stretches in a flex row nor
  sits on a text baseline. The wrapper carries no color of its own; color comes from the control, so
  a selected tab's icon is the same dark legend as its word.
- **The four places.** Action keys, tabs, file-type glyphs and the diagnostic warning. Nothing else —
  see The Icon Restraint Rule in Shapes.
- **The set.** FLOW is a **patch cable** (two jacks with a sagging lead); SOURCE is **angle brackets**;
  the transport's caption is a **metronome**; RUN is a **play triangle**, CLEAR a **square stop**;
  AUTHORIZE is a **padlock**, and its latch is a second drawing (see the gate, below). In the file
  list, `.styio` files wear a **patch link** and `.toml` files a **slider**; the diagnostic strip's
  triangle carries an **exclamation** so it reads as a warning and not as a folder.
- **Swap the drawing, not the label.** A control whose icon changes state must keep its text in its
  own node. The authorize key is `icon + icon(hidden) + #authLabel`, and its JS writes
  `authLabel.textContent`; setting `textContent` on the button itself would have taken the icon with
  it.
- **A hidden icon must be hidden.** `.ic` sets `display: inline-flex`, which outranks the user-agent
  rule for `[hidden]`; the first cut of this revision therefore rendered both lock drawings at once.
  The fix is explicit: `.ic[hidden] { display: none }`. Any class that sets `display` on an element
  that can carry `[hidden]` has to state the hidden case too.

### Physical keys (RUN / CLEAR / rail / notation tab / tempo)
- **Shape:** 3–5px radius caps; a black 3px pad beneath at rest, compressing to 1px on press.
- **RUN:** the primary action — Signal Red top-lit gradient, white 14px condensed legend, `flex: 1` in
  the transport's key row at 36px tall, with a 13px **play triangle** beside the word (gap 7px).
  Before the first run it carries the invite: a 1.6s breathing
  animation over `brightness` 1 → 1.22, the machine asking to be started. The first run spends it —
  `run()` removes the class and nothing restores it, not even CLEAR. While the loop runs the key is
  held down visually (`translateY(2px)`, inset shadow) and stops responding.
- **RUN, after a fault (REPLAY):** the same cap, saying something else. When the machine is held the
  key's icon becomes a 13px **rotate-left arrow** and its legend reads REPLAY, because that is what
  pressing it will now do; `title` is rewritten with the mode too, so the affordance is not carried by
  the label alone. The swap is the authorize key's pattern again — two icon spans with `hidden`, one
  `#runLabel` node, and a single `setRunKey(mode)` that owns all three (`icon`, `hidden`, `label`,
  `title`). CLEAR puts it back to RUN.
- **CLEAR:** flat dark cap in Key Cap Charcoal with a Silk High 11px legend, the same `flex: 1` share
  of the key row, with a 12px **square stop** beside the word. It is the machine's only release: it
  clears a held fault and resets every lamp.
- **Tempo keys (`–` / `+`):** 30×30px dark caps, 4px radius, a 15px condensed glyph with no tracking.
  They clamp the beat to **10–240 BPM** — the floor is low enough to watch a single signal think —
  and the tube between them always shows what they set.
- **Rail (FILES / AGENT / RUN):** three 44×44px square caps with their 6px LEDs beneath, in a 68px
  vertical rail — one instrument per lane, no text on the cap at all. Each cap holds a 20px inline
  stroke icon: a **folder** for FILES, a **four-point spark** for AGENT, a **pulse waveform** for RUN.
  The drawings are the machine's own — 24-unit box, 1.6–1.8px stroke, round joins, `currentColor`,
  no fill — so the selected cap only changes color (Silk at rest, Bone when fitted) and never swaps
  artwork. The whole word stays reachable as the accessible name and the tooltip (`aria-label` +
  `title`), and the internal instrument code (`EXP`/`AGT`/`RUN`) stays invisible in `data-inst`. The
  fitted instrument's cap is latched down and its LED lit amber. There is no fourth key: an
  instrument this build does not fit does not appear.
- **Notation tabs (FLOW / SOURCE):** the same 26px Mono 11px cap, now `inline-flex` with a 6px gap,
  and the first control in the PROGRAM head. FLOW wears a 13px **patch cable** (two jacks and a
  sagging lead), SOURCE a 13px **angle-bracket pair** — the two notations drawn as what they are.
  FLOW is selected on load. They are a real tablist — `role="tablist"` with
  `role="tab"` children, `aria-selected` on both, `aria-controls` pointing at the two panels, and a
  roving tabindex so only the active tab sits in the tab order; ←/→ switches notation and moves
  focus to the newly selected tab. The selected cap inverts to the paper gradient with a dark
  legend, and its icon takes that same dark legend because the icon is `currentColor`. These are the
  only tabs in the product surface.
- **Hover / press:** brightness 1.07–1.12 on hover, then 2px of travel plus a shadow collapse in
  40ms. Focus is `outline: 1px solid #ff3b30; outline-offset: 2px` — the same red as the machine's
  authority, never a browser default ring.

### The transport bay
A 220px milled well recessed into the right end of the loop bar: Well Black, 1px black hairline, 6px
radius, `inset 0 2px 8px rgba(0,0,0,.75)` with a 1px light lip below — the same milled depth as the
permission gate, because it is the same kind of object: a control surface set into the panel face.
Three stacked rows with 8px between them: the silkscreen caption `Tempo · BPM` beside a 12px
**metronome**; a `–` / tube / `+`
row spaced apart; and a CLEAR + RUN row where the two keys split the width evenly. The bay is the
drum machine answer to "where do the transport controls go" — the controls live at the right hand of
the thing they drive, not in a bar across the top.

### The maker's mark
The left end of the status strip signs the machine: `VITYO` at 14px condensed 700, 0.08em, in Silk
High, beside a lit 6px LED. It is what is left of the wordmark after the top bar was removed — same
face, same tracking family, one tenth of the height, at the bottom edge where a faceplate's maker
usually signs. It is not a heading and gets no space of its own.

### The editor (real buffer)
The SOURCE notation is a working editor, not a listing.
- **The instrument is a transparent textarea.** A real `<textarea>` (`wrap="off"`, no spellcheck,
  autocapitalize/autocomplete/autocorrect off) sits absolutely over a highlight layer at identical
  metrics: 13px Mono, `line-height: 24px`, `tab-size: 2`, `padding: 14px 16px 18px`, white-space
  pre. The gutter is a separate 58px column whose rows are also 24px. All three ride the same
  integer line grid; the textarea's text is `color: transparent` with a red caret, so the painted
  highlight layer is what you read and the textarea is what you type into.
- **The highlight layer answers, it does not lead.** A small real lexer paints the buffer — keywords
  (Paper White 600), state literals, `fn` names and numbers (orange/yellow), operators (Silk High),
  punctuation (Silk), comments (Grey) for Styio; sections, comments, `key =` and string/number values
  for TOML.
- **Editing behaves like an editor.** Tab inserts two spaces; Enter carries the current line's indent
  forward; both go through `setRangeText` so the browser's own undo stack survives. Selection paints
  `rgba(255,59,48,.32)` with transparent text, so only the wash moves. Scrolling the gutter with the
  wheel falls through to the buffer — the gutter is not a wall.
- **The line grid is integer on purpose.** The old `line-height: 1.85` multiplied to ~24.05px and
  drifted against the highlight layer over a long buffer; 24px is exact, and the gutter, the
  highlight layer and the textarea all use it.
- **Focus is a lit rim and a caret** (see Elevation & Depth): `inset 0 0 0 1px rgba(255,154,0,.28)`
  around the bed, plus the red caret. No browser outline.

### The explorer (real files)
Explorer rows are real `<button class="frow">` elements, 30px tall at 3px radius, Mono 11px in Bone,
a 4px state LED, then the file's **type glyph** in Silk (13px: a **patch link** for `.styio`, a
**slider** for `.toml`), then the filename, then the byte size pushed right in Silk. Clicking a row
loads that buffer into the editor and switches to SOURCE; the open file's LED is amber and its
`aria-pressed` is true. Three buffers exist — `main.styio` (the eleven-line program the graph
projects), `util.styio` (two small functions and two lets) and `styio.toml` (workspace and loop
configuration). Byte sizes are computed from the text with `TextEncoder`, so the number changes when
you type. There is no permission gate on this: the gate governs the agent's patch, not your own
typing.

### The diagnostic strip (and the analyzer behind it)
An analyzer with exactly one honest rule: **an input route (`a <- b`) must be consumed.** The check
counts whole-word uses of the declared identifier; fewer than two (the declaration plus a use) is a
finding. It is deliberately one rule — a fake analyzer with many rules would be a worse lie than a
real one with one.
- **Three renderings, one finding.** The identifier takes a 1px red wavy underline in the highlight
  layer; the gutter row for that line takes a blinking red 5px LED; and a 27px diagnostic strip sits
  at the bottom of the editor well (seam above, Mono 11px red) reading
  `<ident> 从未被消费 · analyze · step 06 · warning`, with `· +N more` when there are more findings.
  Its icon is an 11px **warning triangle with an exclamation inside** — the fourth and last place an
  icon is allowed (The Icon Restraint Rule).
- **Why the strip and not an inline note.** The previous revision drew the note inline in the source
  flow; an inserted row breaks the alignment between the textarea's line boxes and the highlight
  layer's rows. Anything that adds a line to the buffer must live outside the text flow.
- **The strip is the analyzer's voice on the panel**, and the analyzer is what the machine obeys.

### The sixteen step keys (signature component)
The loop's transport band rides at the bottom of the machine, under the work area and above the
status strip: the work travels left to right along it. Each step is an LED, a 38px cap (44px on a
narrow body) and a number, stacked:
- **Phase quartering:** quarter 1 red, 2 orange, 3 yellow, 4 white — the cap gradients are the only
  place in the system where the full phase ramp appears at once.
- **Armed at rest:** an armed step's LED is the red lens at 62% with a 4px halo — visibly on, not
  lit. Disarmed steps go dark: the cap drops to the recessed charcoal gradient, the LED goes to
  LED Off, the number to #7a7a7a, and the count in the loop head drops ("16/16 Armed").
- **Chase:** exactly one light. The current step gains `brightness(1.22) saturate(1.1)`, its LED
  goes to full red with a 6px + 16px halo, and the previous step is extinguished back to its armed
  or disarmed rest state before the next advances. Step cadence is derived, not hard-coded:
  `60000 / bpm / 4` milliseconds — 117ms at the default 128 BPM, so a full pass is ~1.9s and
  rescales with whatever the tube is set to.
- **Fault:** at step 11 (golden coverage) the run stops dead — but only when the analyzer has a
  finding in `main.styio`. The chase is removed, the cap takes `brightness(1.28) saturate(1.15)`,
  the LED holds steady full red (no blink) and the step number turns red at weight 600. Steps 12–16
  never run. RUN keeps its press but changes to REPLAY, and CLEAR is the only way out of the hold.
- **Pass:** with a clean buffer the same sixteen steps run to the end and the machine reports
  `PASS · 16/16 · GOLDEN CLEAN`. There is no third ending.
- **The step caps carry no text** — the slot window and the number beneath are the whole legend,
  with the step name in the accessible label.

### FLOW notation (the second score) — a generated board
The PROGRAM well's default body: the program drawn as patched signal routing. This is where the
product's pinned vision lands in the world — dependencies, data flow and the execution graph shown
graphically and first, with source text one gesture away and still canonical.

Nothing on the board is placed by hand. There is no static SVG furniture left in the artifact: a
parser reads the open buffer, a layout pass positions what it found, and one draw pass paints it.
Type a new `let … |> …` line and a module and a cable appear; delete the `fn` and its control voltage
goes with it. The board is a projection of the buffer in the literal sense — the relationship FLOW
was always supposed to have to SOURCE.

- **Parse.** `parseStyio(text)` reads the buffer into a small model: `pipeline <name>`, `|>` chains
  (each with its output name), `->` routes, `<-` input routes (`{name, target, source}`), `state`
  declarations and `=>` / `<=` / `when … -> state …` transitions, `emit <value>` inside a function,
  and `const` bindings for everything else. Function scope is tracked (`fn … }`): `state`, `when` and
  `emit` are read only inside one.
- **Layout.** Nodes and edges are built from that model — a value's producer is *found*, not assumed
  (`producers[out] = last stage`) — then laid out as a DAG: layers relax over the data edges, layer
  *x* = `64 + layer × 196`, rows 96px apart in the data band. Input routes neither make a node a pipe
  nor take part in layering; the `EXTERNAL` module hangs under the target it declares, offset 24px
  per route so several can coexist. A `fn` sits in the control band (y = 252), centred on the `from`
  node of the cable its `emit` taps; the `STATE` box sits 200px right of the first `fn` and is
  `34 + 15 × states + 12` tall; `CONST` modules queue to the right of STATE. Module width is measured
  from the longer of its name and kind (`name × 7.4` / `kind × 6.8`, floored at 96), never fixed.
- **Draw.** Cables first, modules over them, jacks and plugs on top, chips last. Every piece of
  furniture is generated in that order, so a longer program lengthens the board instead of colliding
  inside it.
- **The plate.** A 24px dot grid under everything (`#gridDots`: a 1.2px radius dot at 4% white,
  redrawn to the board's extent). Modules are a top-lit linear gradient face (#1f1f1f → #171717) with
  a 1px #2d2d2d edge and a 1px white highlight along the top — the panel material at graph scale. The
  board's `viewBox`, its `min-width`/`min-height`, the grid rect, the plate title
  (`PIPELINE <NAME> — SIGNAL ROUTING`, or `<FILE> — SIGNAL ROUTING` when the buffer declares no
  pipeline), the `LIVE PROJECTION · <FILE>` corner caption and the `aria-label` are all recomputed
  from what was parsed. The bounds are `max(760, rightmost + 48)` by `max(480, lowest + 72)`, so the
  floor stays and nothing is ever clipped.
- **Modules.** One panel per thing the program declares — a `|>` stage, a `->` channel, a `fn`, a
  `const`, an `EXTERNAL` source — 48px tall, name in Silk High, kind beneath in Silk Dim (a `CONST`
  shows its literal value instead of a kind), 5px jack on each edge a cable actually reaches, and a
  sled lamp in the top-right corner. The lamp is not decoration: it lights while a pulse is inside
  that module. Kinds: ORIGIN (declared but nothing feeds it), PIPE (something feeds it), CHANNEL
  (a `->` target), EXTERNAL (a `<-` source), FN · ENTRY, CONST, STATE.
- **STATE is the machine's condition, in as many lamps as the program declares** — every `state` in
  source order, each with its own name, the initial one lit amber at rest. `held` is appended if the
  program does not declare it, because it is the machine's own state and a stopped run must never be
  able to read RUNNING. Exactly one lamp is lit at a time.
- **Data cables.** Horizontal-tangent cubic Béziers with a computed sag
  (`min(30, max(12, gap × 0.16))`), Silk 2.5px over a 4.5px black shadow. Every end is jacked, and
  each plug's rotation is `atan2` of the cable's own tangent at that end — the angle is derived at
  draw time, never stored per cable.
- **Labels are chips (buckles).** Every label on the board rides its own cable: a 16px buckle at the
  path's midpoint, #121212 fill, #262626 stroke, 3px radius, 11px Mono at 0.04em in #9a9a9a, its
  width measured from the text (`length × 6.8 + 16`). A label can no longer float free of the cable
  it names, and one cable with two labels (a route's stage and its output) wears two buckles.
- **Control voltages are dashed chips.** Transitions and emit taps keep the 1.8px dashed Silk-Dim
  line and swap their chip to the `chip-cv` variant (3/3 dashed stroke), so control never reads as
  data. Forward transitions from a `fn` to STATE stagger their sag (`14 + n × 26`) and their buckle
  position (0.38 / 0.62 alternating); backward `<=` transitions drop from STATE's underside
  (`34 + n × 18`). Staggering is what keeps several transitions legible instead of stacked.
- **Input routes run vertically.** A `<-` is drawn from the `EXTERNAL` module's top edge down to the
  declared target's underside — across nothing. Consumed, it seats a jack and plugs at both ends and
  wears its name; unconsumed, it frays 26px short of the target (three bare strands, a steady amber
  sled, a `chip-warn` plate reading `<name> — never consumed`); undeclared, it does not exist.
- **The pulse engine is bound, not hard-wired.** An `FR` binding object is rebuilt on every draw: the
  run's path is the data edges walked *backwards* from the CHANNEL, so pulses ride whatever the
  program actually routes; the frozen pulse is placed at the last stage's left jack; IDLE, RUNNING
  and HELD are resolved to the generated lamps by name (RUNNING is the lamp of the first transition's
  target). Red 4px circles on the same glow recipe as a sled (The One Lamp Grade Rule) travel those
  paths by arc length (`getPointAtLength`) at **0.55px/ms at the 128 BPM reference beat**, scaled
  linearly with the tempo in force (`× bpm / 128`) — so slowing the machine slows the signal with it,
  and at the 10 BPM floor a pulse crawls into RENDER's jack slowly enough to read. The step loop emits
  one every second
  step, so signals ride the chase's own clock; at most **five** are in flight, and a full line drops
  the beat rather than queuing (deliberate, not a leak). A pulse lights the sled of the module it is
  inside, and arrival at the sink flashes that module's lamp for 140ms.
- **Fault, drain, reset.** A held run freezes the graph: in-flight pulses are removed, the frozen
  pulse is shown at the last stage's door, the data sleds go dark, the entry function stays lit and
  STATE switches to HELD. A clean pass lets the last pulses drain out and STATE falls back to rest.
  CLEAR hides the frozen pulse and returns every lamp to its rest state.
- **Render discipline.** The board is redrawn on every keystroke in the buffer (`input` → parse →
  layout → draw). The model advances whether or not FLOW is visible, but nothing touches the DOM
  while it is hidden; the animation frame lives only as long as signals are in flight
  (`flowOn || pulses.length`), so an idle machine burns no frames. SVG class changes go through
  `setAttribute("class", …)` — `className` is read-only on SVG elements. Returning to FLOW repaints
  the graph's truth immediately.

**Honest unavailability.** FLOW projects Styio, so a buffer that is not Styio cannot be projected:
with `styio.toml` open the FLOW tab is `disabled` (dimmed to 38%, no hover lift) and its tooltip says
「FLOW 只投影 styio 程序」, and `setNotation()` refuses at the top. This is the No Display-Only Rule
applied to a whole view: a graph of a config file would be a picture, so the view is not offered.

**The Generated-Board Rule.** Nothing on the board is placed by hand, and nothing is on it that the
buffer did not say. Geometry is derived — layers from the DAG, cables from node edges, plug angles
from their tangents, label buckles from their own text, bounds from the widest and lowest thing
drawn, the title and `aria-label` from what was parsed. A hand-placed node, a hard-coded coordinate
or a label that floats free of its cable is the same lie as a dead button, and it will survive
exactly until the source changes underneath it.

### FLOW: input routes in three states
The input-route cable is regenerated with everything else, so it is always telling the truth about
the buffer:
- **declared but unconsumed** — the cable frays before it seats: three bare strands, a steady amber
  sled, and a `chip-warn` plate reading `<name> — never consumed`.
- **consumed** — the cable seats in a jack on the target's underside, plugs at both ends rotated to
  the vertical run, wearing its own name.
- **undeclared** — the module is not an EXTERNAL and the cable does not exist.

Type a `let routeIn = source <- bridge` line into `main.styio` and add a use for it: the fray grows
a plug and seats. Delete the line: the cable leaves the board. The graph is not illustrating the
source here; it is reading it.

### Run outcomes: fault or pass
The analyzer decides where a run ends, and both endings are reachable.
- **A finding holds the loop.** `run()` snapshots the analyzer's findings at start; with a finding,
  step 11 (golden) stops the machine — chase removed, cap `brightness(1.28) saturate(1.15)`, steady
  red LED, red numeral, in-flight pulses collapsed to one held at RENDER's door, status
  `HELD · STEP 11 GOLDEN · REPLAY OR CLEAR`, `FAULTS 1`. Steps 12–16 never run. Read the diagnostic
  strip, fix the line — or press REPLAY and watch the fault again.
- **A clean buffer passes.** With no finding, all sixteen steps run and the machine reports
  `PASS · 16/16 · GOLDEN CLEAN` with the verify LED lit white and `FAULTS 0`. That ending was
  unreachable before the analyzer was real; it is now the reward for reading the graph's bare strand
  and doing something about it.

### Replay (the fault under the microscope)
A held machine used to be a dead end: the only way out was CLEAR, and RUN answered a press with
`FAULT HELD · PRESS CLEAR`. Now the fault offers its own re-run.
- **The key changes its mind, not just its text.** While held, RUN is REPLAY — a rotate-left arrow
  instead of the play triangle, the word REPLAY in the legend, and a `title` that says what the press
  will do ("Replay the run-up to the fault — slow the tempo to watch"). One `setRunKey(mode)` owns the
  icon, the hidden spans, the label and the tooltip, so the three can never disagree.
- **Replay is the same eleven steps.** `replayFault()` first clears the stage — the `fault` and
  `chase` classes and every LED from step 1 to step 11 go back to rest, the verify lamp goes dark, the
  frozen pulse is hidden, and `flowStart()` refills the machine — then walks 0→11 with the chase,
  the status narration and the pulse emission exactly as a real run does. At step 11 the fault lands
  again: cap faulted, LED steady red, verify red, `flowFreeze()` collapses the signals to the held
  pulse. It can be replayed indefinitely.
- **The strip counts the fault down.** During a replay the status reads
  `REPLAY · STEP 04 SAVE · FAULT IN 7` — the operator always knows how far the signal is from being
  stopped, which is the whole point of watching.
- **`faulted` stays true.** Replay is a microscope, not a repair: the machine is still held, CLEAR is
  still the only way out, and CLEAR is what restores the key to RUN and resets every lamp. `runToken`
  guards the loop as everywhere else, so CLEAR interrupts a replay mid-step without leaving a chase
  behind. Last-run is marked `· replay` in the status strip so a replayed sighting is not mistaken for
  a fresh one.

### Permission gate and the authorize key
The gate is a milled well (#0e0e0e, black hairline, inset shadow) standing in the instrument body.
It opens with a blinking red LED (500ms, `steps(1,end)` — a hard on/off, never a fade) and the
silkscreen "PERMISSION GATE · REQUIRES OPERATOR". The key inside is the largest control in the
system (44px, condensed 14px white legend, a 14px **padlock** beside it) and it *pulses*
(`brightness` 1 → 1.22 over 1.1s) to
ask to be pressed. Pressing it reads "ARMED — APPLYING…", turns the gate LED steady red, and after
700ms **latches**: the cap sinks flat to dark charcoal with an inset shadow, `animation: none`,
the legend becomes silk "AUTHORIZED", `aria-disabled` is set, and the LED goes white. Only then
does the receipt appear. A latched key is not a disabled button; it is a key that has physically
stayed down.

The padlock draws the latch itself. The key holds two drawings — a closed lock and an open one whose
shackle is lifted clear of the body — and the latch swaps them, so the interlock can be read without
reading the word. Both live inside the button next to a dedicated `#authLabel` span, and the JS
writes only that span; setting `textContent` on the button would have deleted the icon with the
label. The two drawings are hidden/shown with `[hidden]`, which is exactly the case that needed
`.ic[hidden] { display: none }` (see Icons).

### Receipts
A receipt is a Mono 11px row: a white LED, a Paper White bold `RECEIPT 0142`, and `VERIFIED · 3
HUNKS`. The session opens with an empty state in Silk Dim — "No receipts · awaiting first
authorization" — so the first receipt is an event, not a list item.

### Readouts and facts
The seven-segment tube (SVG segment geometry, not a font) reports one fact: TEMPO, in Signal Red with
a 2px drop-shadow on lit segments and 6% red on unlit ones. It is not a decoration and not a demo: the
`–` / `+` keys and ↑/↓ on the keyboard set the same `bpm` the step loop divides, so the tube reports
the loop's actual beat — change it and the chase changes speed. `styio.toml`'s `tempo = 128.0` is read
at load and again on every edit, so the config file genuinely configures the machine. The range runs
down to **10 BPM**, where a single step takes 1.5 seconds and the pulses crawl; the tube is not just a
readout, it is the machine's time microscope. Run duration
goes to the status strip and the Runtime instrument's fact table; the armed count goes to the loop
head and that same table; the Runtime table's TEMPO row is written from the same value as the tube —
none of these four ever disagree, because all of them are read from state rather than remembered.

### Panels, labels and status
Panel heads are 38px tall, opened by a Silk High name, closed with a seam, and may end in a Silk Dim
tail caption pushed to the right — the PROGRAM head's tail names the notation and the buffer behind
it (`Styio · Graph · main.styio` on FLOW, which always projects the entry file; `<file> · <N> lines ·
LF` on SOURCE, with N counted from the live buffer). Below 720px a head drops its fixed height, wraps
its controls and hides the tail. The status strip is 32px of Mono 11px, and it is now the machine's
only signage: the maker's mark (VITYO + lit LED) and the loop state on the left, revision, workspace,
last run and the key legend ("Space Run · C Clear · ↑↓ Tempo") in the middle, the cursor position
(`Ln 1, Col 1`, live from the editor's selection) and the demonstration-data notice on the right.

The left field is the machine's voice and it names the station, not just the mode: `LOOP IDLE` at
rest, `RUNNING · 04 SAVE` for the duration of each step while the loop runs, `PASS · 16/16 · GOLDEN
CLEAN` after a clean pass, `HELD · STEP 11 GOLDEN · REPLAY OR CLEAR` when a finding has stopped it,
and `REPLAY · STEP 04 SAVE · FAULT IN 7` while a replay walks back up to the fault — the countdown
that makes the slow-motion worth watching. Its element carries `role="status"`, so the
narration is announced rather than only seen.

**The Synthetic-Data Rule.** Any fabricated demonstration data is labelled where it is shown —
"Demonstration data — synthetic" sits in the status strip of every proof surface.

**The No Display-Only Rule.** Nothing inside a well is there to be looked at. The editor edits, the
explorer opens files, the graph reads the buffer, the tube reports the beat the loop actually runs at,
the diagnostic strip reports the analyzer's real finding. A dead control and a painted buffer are the
same defect — the surface is lying about what it is — so the fix is never to grey it out or caption it
"demo": build it, or take it off the machine. This is what the earlier No Dead Controls Rule was a
special case of.

**The State-Is-Truth Rule.** Every number on the panel is read from state at the moment it is drawn:
the tube and the Runtime table from one `bpm`, the tail's line count from the live buffer, the byte
sizes from the text, the cursor from the selection, the fault count from the run that happened. No
constant is printed twice and no readout is a placeholder. The machine may be wrong about the world;
it may not be wrong about itself.

## Do's and Don'ts

### Do:
- **Do** light from the top: top-lit cap gradients, a light lip below, a black cut beneath the
  higher plane. Every fixture obeys the same sun.
- **Do** keep one chase light and extinguish behind it; running two lit steps at once breaks the
  machine's only story.
- **Do** hold a fault until an operator clears it — steady LED, red numeral, stopped loop, CLEAR as
  the only exit.
- **Do** express state as a lamp, a latched cap, or a numeral before reaching for text.
- **Do** keep the step row a single horizontal track at 44px touch size on narrow bodies.
- **Do** keep machine names as 11px Silkscreen labels and values in Mono 11px; keep 11px as the
  floor for UI and 13px for the editor.
- **Do** separate planes with the seam pair (#000000 cut + #2d2d2d lip) rather than with strokes.
- **Do** give diagnostics a pattern as well as a color — the proof uses a 1px red wavy underline under
  the identifier, a blinking gutter LED and a plain-language strip; on the graph, a bare unterminated
  strand plus a steady amber sled. Never color alone.
- **Do** mark demonstration data synthetic wherever it appears.
- **Do** fit every control: if the machine cannot honour it, it does not appear. Three instruments,
  one transport, two keys in it — the machine shows its real inventory.
- **Do** make every surface in a well real before styling it: a buffer that accepts typing, a file
  list that opens files, a graph that re-reads its source, a readout wired to the value it names.
- **Do** derive what can be derived — step timing from the tempo, line counts from the buffer, byte
  sizes from the text, the tail from the open file — rather than printing a second constant.
- **Do** keep the editor, the highlight layer and the gutter on one integer line box (13px Mono on
  24px), and put anything that would add a row (diagnostics, notes) outside the text flow.
- **Do** let the gutter scroll with the buffer and take the wheel; a column of numbers is part of the
  buffer, not a wall next to it.
- **Do** make the keyboard complete where it is already conventional: Tab indents, Enter carries the
  indent, ↑/↓ set the tempo when no text field has focus.
- **Do** parse the buffer and derive the board: a value's producer is looked up rather than assumed,
  and layer, cable, plug angle, buckle width, bounds, title and `aria-label` are all computed from
  what was found.
- **Do** recompute the frame every redraw — viewBox, min sizes, dot grid, plate title, corner caption
  and `aria-label` — so the board never describes the program it used to show.
- **Do** stagger repeated control annotations (sag and buckle position) instead of letting several
  transitions stack their words on one line.
- **Do** refuse to draw what cannot be projected: a buffer with no program disables the FLOW tab
  rather than showing an empty or invented board.
- **Do** give every held state a next action: a fault that only offers CLEAR is a dead end, so the key
  that started the loop offers to replay the run-up to the failure.
- **Do** make the tempo do work beyond decoration — slow enough (10 BPM) that a signal can be watched
  entering a jack, and scale the signal's own speed with the beat so both slow together.
- **Do** keep one owner per control state: `setRunKey(mode)` writes the icon, which drawing is hidden,
  the label and the tooltip, so a key can never say REPLAY while pressing it runs.
- **Do** keep one pen for every icon: a 24-unit box, 1.8px stroke, round caps and joins,
  `currentColor`, no fill, drawn inline — no icon font, no sprite, no package.
- **Do** wrap an icon in `.ic` (`inline-flex`, `flex:none`, `svg { display: block }`) so it neither
  stretches in a flex row nor sits on a text baseline, and let the control own its color.
- **Do** put an icon only where it disambiguates: action keys, tabs, file types, warnings — and keep a
  numbered list numbered.
- **Do** label a rail key with its whole word in the accessible name and tooltip, and let the cap
  carry only the icon; keep the internal code out of the interface.
- **Do** draw a rail icon as inline SVG with `stroke: currentColor`, one 24-unit box per icon, so the
  selected state is a color change and not a second drawing.
- **Do** let RUN invite the first run once — a 1.6s breath that the first press spends for good.
- **Do** narrate the current station in the status strip while the loop runs (`RUNNING · 04 SAVE`),
  and hold the fault reading until CLEAR.
- **Do** keep the graph at ≥1:1 — it fills its well and holds a 760×480 floor; above the floor it
  grows and its labels with it, below the floor the well pans and no zoom takes a label under 11px.
- **Do** seat every patched cable in a jack with a plug rotated to the cable's tangent, and leave a
  value nothing consumes as a cable that never lands.
- **Do** keep the graph's state honest: exactly one STATE lamp lit, and a freeze rather than a
  RUNNING reading while the machine is held.
- **Do** drop the beat when more than five pulses would be in flight; a bounded line is the machine's
  character, and a queued backlog is not.
- **Do** make the run visible twice from one clock — the chase light on the step row and the pulses on
  the cables advance off the same 117ms step.

### Don't:
- **Don't** add colored halos or glow to keys, panels, gates or cards. Lamps and the seven-segment
  tube are the only emitters; a lit lamp is a 3–7px circle with a halo measured in single pixels.
- **Don't** color the cables. They are silk grey with a black under-shadow; a colored cable competes
  with the signal it carries, and color in this world belongs to light.
- **Don't** blink a standing fact. Blinking means "press something" — the gate lamp and the
  diagnostic gutter lamp. Steady amber is how a fact holds.
- **Don't** scale, squeeze or re-lay-out the graph to fit a narrow column; pan it, or reduce what is
  on the board.
- **Don't** let the graph become an independent truth. FLOW is a projection of the source that stays
  one gesture away; a graph that can disagree with the text, or that hides the text, is a second
  system.
- **Don't** ship a control that answers nothing: no cap for an instrument that is not built, no tab
  without a target, no key that swallows a press.
- **Don't** ship a surface that only displays. A read-only "listing" where an editor belongs, a file
  tree that cannot open a file, a diagram that never changes when the source does — a well that
  cannot be touched is a screenshot, and this machine does not ship screenshots.
- **Don't** print a number the panel does not own: no hard-coded tempo beside a real one, no byte
  count that ignores the text, no fixed line count in a live buffer's caption.
- **Don't** hard-code the step timing while the tempo is settable; derive it, or the chase and the
  tube will disagree.
- **Don't** insert rows into the source flow for notes or diagnostics — the textarea and the
  highlight layer share one line grid, and an extra row breaks it.
- **Don't** leave a fault as a dead end, and don't answer a press with a refusal where a useful action
  exists: a held machine still has something to show.
- **Don't** let a control's shape and its effect drift apart — if the key says REPLAY it replays, and
  the mode owner is what keeps them tied.
- **Don't** let the tempo scale the chase without scaling the signals: a slow beat with fast pulses is
  a machine lying about its own speed.
- **Don't** let a display rule outrank `[hidden]`: if a class sets `display` on an element that can be
  hidden, state the hidden case (`.ic[hidden] { display: none }`) or two drawings will render at once.
- **Don't** rewrite a control's whole `textContent` when that control has an icon — write its label
  node, or the icon goes with the text.
- **Don't** put an icon on a panel head, the loop head, the status strip or an agent step row; those
  say what they are in words and numbers.
- **Don't** hand-place a node, hard-code a coordinate, or keep a static SVG that only looks like a
  projection. A board that does not change when the source does is a screenshot.
- **Don't** let a label float free of the cable it names — buckle it — and don't let two annotations
  collide on one line when staggering would separate them.
- **Don't** announce a board you did not draw: the `aria-label` describes the parsed program, and it
  is recomputed with it.
- **Don't** put back a top bar. The name belongs at the bottom edge and the transport belongs with
  the loop; nothing that is not work earns height above the work.
- **Don't** put a word on a rail cap. The rail is icons; the whole word belongs in the accessible
  name and the tooltip, and a squeezed legend is what made the rail look untidy.
- **Don't** swap a rail icon in its selected state — change its color, don't redraw it.
- **Don't** ship an icon key without `aria-label` and `title`; an icon without a name is a mystery
  button, which is the defect this world exists to avoid.
- **Don't** scale the graph below its 760×480 floor, and don't letterbox it to a postage stamp in a
  large well — the board fills the well up to that floor.
- **Don't** use decorative glow, bloom, blur, glass or translucent layered material anywhere. That
  is the direction this world was chosen to replace.
- **Don't** put pills, large radii or round buttons in the system — circles are hardware (LED,
  screw), not controls.
- **Don't** reintroduce cream-paper nostalgia (warm off-whites, sepia, paper grain used as mood);
  the machine's paper is a signal color, not a material.
- **Don't** saturate with em dashes outside the machine idiom. The machine's separator is `·`
  (facts, states, key legends); the em dash is reserved for a title/subtitle or key/action joint.
  The proof mixes the two and that mixing is a defect to fix at port time, not a convention.
- **Don't** animate anything that is not a physical state change or the RUN sweep: no fades, no
  easing curves on lamps, no pulsing decoration. The blink is a hard 500ms step function.
- **Don't** auto-clear a fault, auto-advance past a failure, or let an agent action land without a
  pressed key.
- **Don't** put legible prose on a key cap — caps carry a short legend and an accessible name; only a
  step key cuts a slot window.

## Scope and Port-Time Checklist

**What this document records.** The world established by the direction proof at
`.impeccable/mocks/vityo-step-row.html` — a self-contained HTML/CSS/JS first-viewport proof, now
carrying two notations in its PROGRAM well (the sixteen-step loop plus the FLOW signal-routing
graph). Its direction contract (THESIS / OWN-WORLD / STORY / FIRST VIEWPORT / FORM) is the opening
comment of that file; the decision record is `.impeccable/decision-record.json` (seed key
`82e2aec9`), where the catalog challenger `signals-instruments-drum-machine-step-row` was adopted via
"Adopt anyway" over a declined verdict. The build was code-led; no image generation took place. The
FLOW view answers the product's user-pinned vision — PRODUCT.md principle 6, "Flow made visible"
(2026-09-30), with the verbatim statement in its Positioning section. Every value above is read out
of the artifact. Anything not present there is marked below as port scope.

**This world replaces an incumbent.** The shipping client is the Flutter app in
`products/vityo_app`, whose current world is the flat hairline `obsidian` preset with a gold accent
lineage and a "V" monogram device. That app is the incumbent this world supersedes. The world is now
implemented inside that repository as a self-contained desktop demo (see *Flutter Port* below); the
shipping shell's own surfaces have not been converted, so those screens are still the incumbent's and
this file should be re-derived in scan mode against them once they are.

**Review rounds.** Round 1 (before FLOW existed) closed with disposition *ship* and left the seven
notes below. Round 2 reviewed the added FLOW view, opened *fix-first*, and closed with **ship** after
the fixes. It raised eleven findings: ten were resolved, and one — recoloring the cables — was
adjudicated *not adopted*, on the reasoning that color in this world belongs to light, so the cables
stay Silk grey with their black under-shadow. Of the residual six, four findings were fixed before
ship (six changes: the mobile editor well raised to `min-height: 554px` so a 480px board fits, ←/→
focus following the selected notation with a roving tabindex, the `#pgmTail` selector narrowed from a
class to the id, the held pulse's radius unified at 4, the unused `.sled.blink` class removed, and
the pulse drop-beat behavior commented as deliberate). Two were deferred to port time — they appear
as (b) and the well-width note below.

**User-feedback revision (immersion and legibility) — not a scored round.** After round 2 shipped,
the reviewer reported the proof as not immersive enough and many of its controls as unexplained. The
revision that followed is recorded here because the artifact changed, not because a review round ran.
It removed everything that was not actually fitted — the SCM/EXT/SET rail keys, the WORKSPACE BANK
A–D block, and the SOURCE file tabs — relabelled the rail in whole words (FILES / AGENT / RUN, rail
58px → 76px with 52×36px caps, 56×44px on mobile), let the graph board fill its well behind a
760×480 floor (the 1:1 rule became the ≥1:1 rule), gave RUN a one-time breathing invitation, and made
the status strip narrate the current station by name. Three round-1 notes were closed by it: the
inert `UTIL.STYIO` tab and the empty-bank mismatch are gone with the controls that caused them, and
`#loopState` now carries `role="status"`. The screenshot set in `.impeccable/review/` was re-cut for
the states the revision touches; `desktop-running.png` still carries the pre-revision capture and
should be re-shot before it is cited as evidence.

**User-feedback revision (rail icons and the transport) — not a scored round.** The reviewer then
looked at the live proof on screen and gave two notes: 「左侧的按钮换图标吧,用文字太不整齐了,用正方形。」
and 「上方的 Loop 太显眼,但又没什么用,挪到底部吧。」 The revision implemented both. The rail's three
keys lost their words and became square icon caps — 68px rail, 56px key, 44×44px cap, a hand-drawn
inline SVG each: a **folder** for FILES, a **four-point spark** for AGENT, a **pulse waveform** for
RUN, all `stroke: currentColor` so the selected state is Silk → Bone and no second drawing. Each key
keeps the whole word in `aria-label` and `title`, so nothing is lost to a screen reader or a hover.
The loop bar moved from above the work area to below it — after `</main>`, before the status strip,
`seam-b` → `seam-t`, comment "the transport rides at the bottom" — and its desktop key height came
down from 46px to 38px (mobile stays 44px), which is what let a sixteen-step band sit under the work
without competing with it. This supersedes the previous revision's rail line: the whole-word
silkscreen (52×36px caps, 0.06em tracking) is gone, and the rail is now the one surface in the design
with no type on it at all. The direction contract's FIRST VIEWPORT and FORM lines were synced, and
the reviewer confirmed both shapes on screen in the live window and the re-shot captures.

**User-feedback revision (realness) — not a scored round.** Looking at the live proof again, the
reviewer asked two things: 「上方的标题栏似乎没什么用，还占用了很多空间，有什么办法能简化设计的同时保持风格吗？」
and 「现在右侧的文件浏览器不能交互，文本编辑器也不能交互，你把功能做成真实的，别做假的。」 The first removed the top
bar (see Layout: the name became the maker's mark, the tube and keys moved into the transport bay, the
`@media (max-width: 900px)` chassis block went with it, and the machine now has one breakpoint). The
second is the more consequential one, and it turned four display surfaces into working ones:

- **SOURCE is a real editor.** A transparent textarea over a real highlight layer on one 24px integer
  line grid, a gutter column that scrolls with it, Tab and Enter that behave, a red caret and an amber
  focus rim, a live `Ln n, Col n` in the status strip, and two small real lexers (Styio, TOML) behind
  the color.
- **FILES is a real file list.** Three named buffers, opened by clicking rows that are real buttons,
  with byte sizes computed from the text and the open file marked by an amber LED.
- **The analyzer is a real rule.** One honest check — an input route (`a <- b`) must be consumed —
  rendered three ways (identifier underline, gutter lamp, diagnostic strip) and obeyed twice: the FLOW
  bridge cable mirrors it in three states, and the run's outcome depends on it. The `PASS · 16/16 ·
  GOLDEN CLEAN` ending was unreachable while the fault was scripted; it is a real branch now.
- **TEMPO is real.** A `bpm` state with `–`/`+` keys and ↑/↓, a step clock derived as
  `60000/bpm/4` instead of a 117ms constant, the tube and the Runtime fact written from the same
  value, and `styio.toml`'s `tempo` read at load and on every edit.

It also settled the earlier dead-code notes: the `BANKS` array, `.bankkey` CSS and media rule, the
`#instEmpty` body and the `No files fitted` copy are gone from the artifact, and with them port notes
(f) and (g) below. The screenshots were re-cut across `desktop`, `desktop-source`, `desktop-held`,
`desktop-fixed`, `desktop-patched`, `desktop-pass` and `mobile`, and `shot.js` was extended with the
three new states (`fixed`, `patched`, `pass`).

**Generator revision — not a scored round.** The board was still furniture: seven modules at fixed
coordinates, a hand-drawn routeIn group toggled between two states, and an `analyzeMain()` that
patched the picture rather than reading the program. This revision deletes all of it and generates
the board from the buffer: `parseStyio()` produces the model (pipeline, `|>` chains, `->` routes,
`<-` input routes, state transitions, emits, consts), `renderGraph()` builds a DAG, layers it (196px
pitch, 96px rows), places each kind where its meaning puts it, and draws once in a fixed order —
cables, modules, jacks, plugs, labels. Concretely:

- **Everything is derived.** Producer lookup instead of assumed wiring; plug angles from the cable's
  tangent (`atan2`); label buckles measured from their own text and buckled onto the path they name;
  bounds, viewBox, min sizes, dot grid, plate title, corner caption and `aria-label` recomputed from
  what was parsed — `max(760, rightmost + 48)` by `max(480, lowest + 72)`.
- **The visual language grew a plate.** A 24px dot grid, a top-lit module gradient with a top
  highlight line, horizontal-tangent Bézier cables, and one label form everywhere: the buckle, with a
  dashed variant for control voltages.
- **Input routes were re-decided.** `<-` now runs vertically from the EXTERNAL's top edge to the
  declared target's underside; consumed it seats at both ends, unconsumed it frays 26px short with a
  steady amber sled and a warning buckle. The earlier "patched into MAIN" shortcut is gone.
- **The pulse engine re-binds.** `FR` is rebuilt per draw: the run's path is the data edges walked
  backwards from the CHANNEL, the frozen pulse lands at the last stage's left jack, and a missing `to`
  field that had left the RUNNING lamp permanently dark was fixed.
- **Honest unavailability.** With `styio.toml` open the FLOW tab is `disabled` with the tooltip
  「FLOW 只投影 styio 程序」, and `setNotation()` guards at the top.
- **Cleanup.** The dead `.mod-box` CSS is gone; transition labels moved from free text (pierced by
  the dashed line) into buckles, staggered by sag and position; STATE's distance from the first `fn`
  grew 60 → 200px to seat those buckles.

Verified with `node .impeccable/shot.js` (all states green) and eleven screenshots in
`.impeccable/review/` — `desktop`, `desktop-flow-running`, `desktop-held`, `desktop-pass`,
`desktop-patched`, `desktop-source`, `desktop-explorer`, `desktop-authorized`, `desktop-fixed`,
`util-flow`, `mobile` — all inspected, and the live window reloaded and confirmed.

**Icon revision — not a scored round.** Several controls had been named but not drawn: the notation
tabs, the transport's caption and keys, the authorize key and the file rows were all word-only, and
the words were doing work a drawing does faster. This revision gives them the same pen the rail
already used — a 24-unit box, 1.8px stroke, round caps and joins, `currentColor`, inline, no
dependency — and drew: a **patch cable** for FLOW, **angle brackets** for SOURCE, a **metronome** for
TEMPO, a **play triangle** for RUN, a **square stop** for CLEAR, a **padlock** for AUTHORIZE (with an
open-shackle second drawing for the latched state), a **patch link** and a **slider** for the two file
types, and an **exclamation** inside the diagnostic triangle.

The restraint is the point: icons went to action keys, tabs, file types and warnings, and nowhere
else — panel heads, the loop head, the status strip and the agent's numbered step rows stay
word-and-number, because a numbered list's order is its meaning and a heading that says what it is
needs no glyph. Two engineering notes came out of it: the authorize key now carries
`icon + icon(hidden) + #authLabel` (the JS writes the label node; replacing the button's whole
`textContent` would have deleted the icon), and `.ic` needed an explicit `.ic[hidden] { display: none }`
because its own `display: inline-flex` outranked the user-agent `[hidden]` rule and rendered both lock
drawings at once — the double-lock bug, fixed and re-checked in the explorer and authorized
screenshots. Verified with `node .impeccable/shot.js` (all green) and the `desktop`, `authorized`,
`explorer` and `mobile` captures.

**Replay revision (HELD slow-motion replay) — not a scored round.** A held machine was a dead end:
CLEAR or nothing, and RUN answered a press with `FAULT HELD · PRESS CLEAR`. This revision makes the
fault replayable. The RUN key swaps to REPLAY while held — a rotate-left arrow in place of the play
triangle, the legend changed, the `title` rewritten — using the authorize key's own pattern (two icon
spans with `hidden`, one `#runLabel` node) behind a single `setRunKey(mode)`, and `run()` now routes a
press while faulted to `replayFault()` instead of refusing it.

`replayFault()` clears the stage first (the `fault`/`chase` classes and LEDs from step 1 to step 11,
the verify lamp, the frozen pulse), then walks 0→11 with the chase, the narration and the pulse
emission as a real run does, counting down in the status strip — `REPLAY · STEP 04 SAVE · FAULT IN 7`
— and lands the same fault in the same place: cap faulted, steady red LED, verify red, signals
collapsed to the held pulse. It repeats indefinitely; `faulted` stays true, CLEAR is still the only
exit, and last-run is marked `· replay`. The tempo floor dropped 40 → 10 BPM and the pulse speed is
now scaled by the beat (`0.55 × bpm / 128` px/ms) with `stepMs()` read live each step, so an operator
can slow the machine while the fault approaches and watch the signal crawl into RENDER's jack. The
existing promise — pulses ride the chase's own clock — now holds across the speed dimension too.

`shot.js` gained a `desktop-replay` state (`setBpm(40)` → press REPLAY → capture 1.2s in), and restores
128 BPM afterwards so the later pass scene is not slowed. Verified with `node .impeccable/shot.js`
(all green, twelve captures) and by eye on `desktop-replay` — the tube reading 40.0, the REPLAY key
shape, the FAULT IN countdown and the crawling pulse — with `desktop-pass` and `desktop-held`
re-checked.

**Port-time checklist.** The round-1 notes still open in the proof (four of the original seven):

1. Step presses mid-run are silently ignored; a press should either be refused visibly or deferred.
2. Fault versus chase is only 1.22 vs 1.28 cap brightness apart; the distinction currently leans on
   permanence, the steady LED and the red numeral. Give the fault a non-brightness channel.
3. Separator convention mixes `·` and `—` (see the Don't above).
4. The step-11 golden fault and the source diagnostic are linked in substance — the analyzer's finding
   now *causes* the hold — but not in navigation: clicking the diagnostic strip does not move the
   caret to the line, and the graph's bare strand does not highlight the identifier it stands for.

**Added by the FLOW review (port-time).**

- **(a)** `.sled` (graph lamps) and `.led` (chrome lamps) are two class families for one grade of
  light. In Flutter they must collapse into a single token source, or the two will drift.
- **(b)** Cable material upgrade: a dark core with a lit top edge, and a recessed inner collar inside
  the jack. The proof ships a single Silk stroke with a black under-shadow; the richer material was
  proposed in round 2 and deferred.
- **(c) Partly settled in the artifact.** The board is no longer hand-authored: `parseStyio()` reads
  the open buffer and `renderGraph()` lays the DAG out and draws it. What remains for the port is the
  parser's depth (`parseStyio` is a line-regex reader for the grammar the buffers use, not a real
  Styio front end) and the layout's ambition (fixed pitch and rows, no crossing minimisation, no
  zoom/pan controls, no node selection — the well pans natively because the board can outgrow it).
- **(d)** Automated detection (`detect.mjs`) has no coverage over the SVG region; graph defects —
  type size, contrast, lamp state — need to be inside the detection pass before the port relies on
  it.
- **(e)** Desktop well width leaves empty space around the board in a wide window — now partly
  answered: the board fills the well down to its 760×480 floor, so the leftover space only appears
  when the well is smaller than the floor.
- **(f) Settled in the artifact (was: dead residue).** The `.bankkey`, `.bank-block` and `.rail-spacer`
  CSS rules, the `document.querySelectorAll(".bankkey")` no-op, the `BANKS` array, the `#instEmpty`
  body and the "No files fitted in this proof" copy are all gone — the immersion removals are now
  clean removals.
- **(g) Settled in the artifact (was: unreachable banks).** FILES is a real list of the three buffers
  that exist; there is no workspace bank concept left to reconcile.
- **(h)** The status strip changes on every step (station narration); the `role="status"` element is
  polite by default, so decide at port whether per-step announcements should be throttled or whether
  only phase changes should be announced.
- **(i) Partly settled in the port.** The transparent HTML textarea is gone: the Flutter demo uses a
  real `TextEditingController` with a painted highlight layer, riding the *same* constants
  (`kLineHeight = 24`, `kEditorFontSize = 13`, `kGutterWidth = 58`), so the overlay hack is not part
  of the port. What still remains is a full editor engine: IME composition, undo history across file
  switches, soft wrap, find/replace, multi-cursor and very large buffers.
- **(j)** The analyzer is one rule implemented with a word count. The port needs the real Styio
  analyzer's diagnostics to feed the same three renderings; the word-count heuristic (fewer than two
  occurrences) will mis-fire on shadowing, comments and strings, which the proof's lexer does not
  model.
- **(k)** The TOML reader is a regex over one key. A real config layer should parse, validate and
  report errors, and should own the tempo rather than letting a text edit mutate machine state as a
  side effect of typing.
- **(l)** Byte sizes are `TextEncoder` lengths and the tail's line count is a split; both should come
  from the workspace/revision model at port time, not from a string in the view.
- **(m)** The cursor readout reports `Ln`/`Col` of a collapsed position; a real status field should
  report a selection range when there is one, and the strip should be an accessible live region.
- **(n)** With the top bar gone, the proof now has a single 720px breakpoint. The 600–899px and
  360–599px product bands are still unexercised, and the transport bay's uncoupled mobile row is the
  first thing to re-test there.
- **(o) Partly settled in the port.** The web proof sizes a label buckle by character count
  (`length × 6.8`); the Flutter board measures real glyphs per font role instead, so a buckle is sized
  by the same engine that draws it. Character-count sizing survives only in the proof.
- **(p) Settled in the port.** The `FR` binding object is gone: `flow_model.dart` is pure Dart (points,
  curves, chips, the parser, the analyzer) and `flow_board.dart` paints it — no re-finding nodes by
  name, no DOM to keep in step. It is still a full repaint on every keystroke; diffing or a layer
  cache is the next step.
- **(q)** The disabled-FLOW-tab pattern (a view that refuses to project what it cannot project) is
  worth carrying into the port as a general rule, alongside the diagnostic strip; both are cases of
  the machine declining to draw something rather than drawing something false.
- **(r)** Icons are inline SVG per site with `currentColor` in the proof; the port draws them from one
  registry of `Path`s so the pen cannot drift between controls — keep it that way, and keep the same
  visibility discipline (a widget that sets its own display must not defeat the framework's hidden
  state; the `.ic[hidden]` bug is the browser's version of it).
- **(s)** Replay re-runs the loop from the top rather than scrubbing recorded state. A real port
  should replay from a recorded run (steps, signal positions, timings) so it can be paused, scrubbed
  and stepped backwards — and the `setRunKey(mode)` pattern (one function owning icon, hidden state,
  label and tooltip) is worth keeping as the rule for any control with modes.
- **(t)** The headless capture channel is the port's only automated pixel check; it renders widget
  states through `matchesGoldenFile` rather than verifying pixels against the web proof. Keep the
  seven states in step with any visual change, and add a state when a new one is claimed (see the
  Flutter Port section for why the golden channel, and not a hand-rolled `toImage`, is the one that
  works under `flutter_tester`).

**Open reconciliations with the product record.**

- **Font policy** (PRODUCT.md): allow-list vs. the proof's IBM Plex Sans Condensed / Sans / Mono,
  and vs. the shipped app's Plus Jakarta Sans / Azeret Mono. Open decision, not resolved here.
- **Breakpoint bands**: the proof now runs a single 720px breakpoint (the 900px chassis block left with
  the top bar); PRODUCT.md's quality bar names 600–899px and 360–599px bands, and both are still
  unexercised. The port should adopt the product bands and re-test the step track and the transport's
  mobile row there.
- **Brand devices**: the proof has no "V" monogram and no gold; its signature is a 14px condensed
  VITYO maker's mark beside a lit LED at the left end of the status strip. PRODUCT.md flags the gold
  lineage as inferred and open to keep, evolve or retire; the monogram line describes the incumbent
  app and is not contradicted by this proof.
- **Coverage**: the proof is one first viewport plus the FLOW view inside it. The graph is covered —
  generated board, modules, cables, jacks, plugs, buckles, the pulse engine and the state lamps — and
  it is drawn from whatever the open buffer declares rather than from a fixed pipeline, though the
  parser reads one curated grammar and the board has no interaction beyond panning. The fitted
  inventory is deliberately small: three instruments (FILES / AGENT / RUN), one transport bay with a
  tube and four keys, one status strip. The editor, the explorer, the analyzer, the tempo and now the
  graph are real within their limits (see the port notes). Theme token customization, glyph and
  semantic-block surfaces, a full diagnostics list, the command palette, multi-repo toolchain state and
  the agent's own file writes are still outside it, and remain to be expressed in this world.

## Flutter Port (rev 9)

The world above is no longer only a web proof: it now runs as a self-contained Flutter desktop
demo inside the shipping app's own tree. It is an **addition, not a conversion** — the demo has its
own entry point and its own widget tree, and it touches none of the incumbent shell's surfaces.

**What landed.**

- `products/vityo_app/lib/src/view_render/workbench_demo/` — eight files, 4856 lines:
  `tokens.dart` (1019, colour, type and geometry constants plus the shared primitives: lamp, cap key,
  hand icon, pen, seams, wells, the seven-segment tube), `machine.dart` (1013, the shell and the
  controller — buffers, tempo, the run, the interlock),
  `flow_model.dart` (886, the
  Styio reader, the analyzer, the routing model and all board geometry — pure Dart, no widgets),
  `flow_board.dart` (495, the board painter), `transport.dart` (472), `instruments.dart` (467, the
  rail, the agent gate, the explorer), `editor.dart` (436, the buffer, gutter and diagnostic strip),
  `workbench_demo.dart` (68, the entry point).
- Entry: `flutter run -d macos -t lib/src/view_render/workbench_demo/workbench_demo.dart`. No daemon,
  no local service and no agent connection are required — the demo is complete on its own, which is
  Product Principle 2 ("complete without an agent") exercised for the first time in the port.
- Fonts are bundled and registered in `pubspec.yaml`: **IBM Plex Mono** (400/500/600), **IBM Plex
  Sans Condensed** (600/700), **Plus Jakarta Sans** (400–800) and **Azeret Mono** (400/500/600). The
  Plex faces are the world's own; the other two are the shipping client's faces, kept so the demo
  does not fight the app's existing theme for the same process. The font-policy reconciliation in
  PRODUCT.md is unchanged by this and still open.
- The port keeps the proof's measurements rather than re-deriving them: `kLineHeight = 24`,
  `kEditorFontSize = 13`, `kGutterWidth = 58`, the same phase colours, the same 760×480 board floor,
  the same 220px transport bay.

**Four deviations found while porting, and how each was settled.** A port is where a design assumption
meets a real compositor; all four were fixed by returning to the proof, not by inventing a new answer.

- **(a) The noise layer is gone.** The proof tiles a 128px plastic grain at 5% opacity (a CSS
  `overlay` blend over a static raster). In Flutter the `_GrainPainter` — 840 random points per tile,
  drawn with a blend mode — read as dirt on the panel, not as material: random points land differently
  on every repaint and the texture has no fixed phase. The whole layer was deleted. **The Matte Rule
  survives without it**; grain is a print artefact the compositor made look like damage.
- **(b) The tube read nonsense until it was scaled.** The seven-segment glyph geometry is authored on
  a 23×40 grid but lands in a 15×27 cell; the Flutter painter drew it at full size inside the smaller
  box, so `128.0` came out as a smear. Fixed by translating and applying `scale(0.65)` to the whole
  glyph (`tokens.dart`: *the glyph grid is 23×40; the tube cell is 15×27*). The reading is exact now,
  and the rule worth keeping is that a geometry authored at one size must be scaled, never cropped,
  when it is placed at another.
- **(c) The warning plate moved off the cable.** The `routeIn — never consumed` plate had been centred
  on the frayed end, so its own legend sat under the strands and the cable crossed the text. The port
  stands the plate to the right of the end (`Pt(x2 + 12 + w/2, y2)`), which is what the proof actually
  draws: **the plate explains the end, it does not cover it.**
- **(d) One value, one buckle — the emit chip stopped double-seating.** The data cable already carries
  its own buckle (`staged`), and the emit tap had been dropping a second buckle (`emit staged`) at the
  same midpoint, so the two covered each other and the tap's weld sat on top of the text. Resolved by
  the proof's own layering: the emit buckle rides the *dashed feeler* halfway up, never at the tap
  point, and tap welds are CV furniture drawn under the chips, so a weld that lands on a buckle is
  hidden by it (`flow_board.dart`: *tap dots are CV furniture: under the modules and chips, same as
  the proof's gCV group*). The general form: **a cable wears one buckle; a second annotation belongs
  to the thing that carries it.**

**The headless capture channel.** The port is verified without a window:
`products/vityo_app/test/workbench_demo_capture_test.dart` drives `WorkbenchController` directly — no
OS mouse, no window focus — and renders seven states — `desktop`,
`running`, `held`, `replay`, `source`, `authorized`, `util-flow` — through `matchesGoldenFile` into
`.impeccable/review/flutter-*.png`, beside the web proof's own screenshots. Run it with
`flutter test test/workbench_demo_capture_test.dart --update-goldens`.

Five things about that channel are worth writing down, because each one cost time:

1. **Nothing asynchronous from `dart:io` completes inside the fake-async zone.** Under
   `flutter_tester`, `await File.writeAsBytes(...)` never returns — the zone has no event loop to
   deliver it. Capture must go through the engine (image → bytes in memory) and be handed to the
   golden machinery, which does the writing outside the zone.
2. **An engine-completed await leaves the zone with no flusher.** After `toImage`/`toByteData`
   completes, the next fake-async `pump()` parks forever: the microtask queue has nothing on the stack
   to drain it. The golden path works because its test-channel round-trip re-enters the harness and
   flushes the zone — `capture → pump → capture` is the pattern that survives, and a hand-rolled
   `RepaintBoundary.toImage` is the pattern that hangs.
3. **`flutter_tester` has no system font fallback.** Every face must be registered by exact family
   through `FontLoader`, with all bundled weights (`IBM Plex Mono`, `IBM Plex Sans Condensed`, `Plus
   Jakarta Sans`, `Azeret Mono`); a family that is only *named* in a style resolves to nothing.
4. **CJK is tofu headless.** Because there is no fallback, the demo's Chinese fine print cannot render
   in the capture channel at all. That is a property of the channel, not of the port: **the live macOS
   window is the truth for anything with a fallback chain**, and the captures are the truth for
   layout, colour and state.
5. **The channel is a regression net, not a comparison.** The goldens record the port; the port was
   compared against the web reference shots by eye, state by state (`desktop*` beside `flutter-*`),
   including the cases that are easy to get subtly wrong: `util.styio`'s three isolated modules with
   no cables at all, a single frozen pulse in HELD, and the REPLAY microscope at 40 BPM.

**Verification standing at rev 9.** 27 tests green (`workbench_demo_flow_model_test.dart` 19,
`workbench_demo_smoke_test.dart` 7, `workbench_demo_capture_test.dart` 1) by plain `flutter test`;
`flutter analyze` reports 0 issues; the seven golden captures and the web proof's screenshots sit
side by side in `.impeccable/review/`, and their layouts were compared item by item.

**What the port does not cover.** The demo is a demo: it is not wired into the shipped shell, its
goldens are per-machine (a font or Flutter upgrade will move them), the analyzer and the TOML reader
are still the proof's single-rule and regex versions (see the port notes), and everything outside
this world — theme customization, glyph and semantic-block surfaces, the command palette, the
agent's own file writes — is still the incumbent's design, not this one.
