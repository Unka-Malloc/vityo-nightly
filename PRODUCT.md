# Product

<!-- impeccable:product-schema 1 -->

> Init note: the harness session ran in auto-permission mode with the structured
> question tool disabled, so the init interview could not be run live. Facts below
> are taken from strong repository evidence (README, docs/design, docs/specs,
> code); facts that are inferences rather than documented truth are marked
> *(inferred)*. Correct any line and future work will follow the correction.

## Platform

adaptive

(Vityo is a single Flutter codebase shipping a desktop workbench and a mobile
body from one design language: `products/vityo_app` targets macOS, Web, iOS and
Android capability profiles, with distinct desktop/mobile shell bodies in
`vityo_shell_scaffold.dart`. The archived `prototype/` web shell is a permanent
reference asset, not a shipping target.)

## Users

- Primary: Styio developers in long, focused desktop sessions running the full
  `edit -> analyze -> test -> run -> observe` loop (README).
- Secondary: developers supervising connected coding agents — reading plans,
  tool activity, permission requests, change previews and verification receipts
  (README, Agent Workbench surfaces). *(inferred as audience: the repo builds
  the surface; how many users live in it daily is unconfirmed)*

## Product Purpose

Vityo is the Agent-Native IDE for Styio. It unifies source editing, authoritative
language/compile/run facts, and auditable agent collaboration into one trusted
workbench. Without any agent connected it remains a complete IDE; with an agent,
plans, tool calls, permissions, diffs and verification receipts stay visible and
controllable. Success = a user can trust agent-produced change because every
machine fact and every agent action is inspectable in the same surface where
code is edited.

## Positioning

The agent is a governed collaborator rendered as inspectable workbench state —
not a chat sidebar bolted onto an editor. The IDE owns source, workspace
revision, and language/compile/run truth; agents attach only through a
versioned protocol (`packages/vityo_agent_protocol`) and never own product
state. No neighboring IDE truthfully claims "authority and auditability as the
primary UI surface" as its organizing mechanism. *(positioning statement
inferred from README + architecture docs; not marketing-verified)*

**User-pinned (2026-09-30, verbatim):** “Vityo 就像音符一样，是流动的。它的核心
是表达数据的流动性，而音乐天然就随着时间流动。Vityo 忠于表达程序的依赖、数据
流动和执行图，以图像的形式展示，而不是纯文本。” — Flow is the product's core
metaphor: dependencies, data flow and the execution graph are expressed
*graphically and first*, with plain text remaining the canonical source beneath
the projection. This binding statement is why the rhythm-machine world was
chosen, and it constrains every future surface.

## Operating Context

- Desktop workstation, keyboard-first (command palette on Cmd/Ctrl+K), dark
  theme is the out-of-box default (`obsidian` preset).
- Terminal-adjacent workflows: runtimes, PTY output, debug console, CI-like
  verification receipts.
- Multi-repo toolchain reality: upstream `styio` / `pafio` supply machine
  contracts; Vityo renders them.
- Archived web prototype (`prototype/`) is a permanent reference asset by repo
  governance and must never be removed.

## Capabilities and Constraints

- Flutter single codebase; default client `products/vityo_app`.
- Visual quality bar (`docs/design/Vityo-IDE-Interaction-Quality-Bar.md`):
  editor text contrast >= 4.5:1, UI text >= 3:1, focus indicators >= 3:1,
  diagnostics distinguishable by pattern not color alone, font floors 12px
  editor / 11px UI, breakpoints 600-899px and 360-599px, keystroke-to-paint
  <= 16ms.
- Font licensing policy (`docs/specs/OPEN-SOURCE-UI-ASSET-POLICY.md`): UI
  allow-list IBM Plex Sans / Inter / Noto Sans / Recursive; editor JetBrains
  Mono / IBM Plex Mono / Recursive; glyph STIX Two Math / Noto Sans Math.
  Current shipped faces (Plus Jakarta Sans, Azeret Mono) are OFL but not on the
  allow-list — reconciliation is an open decision.
- No commercial brand names as default theme labels; neutral naming required.
- Theme system must cover shell, editor, semantic blocks, glyph, diagnostics,
  runtime, Agent Workbench, with token-level customization
  (`docs/design/Vityo-IDE-Benchmark-Matrix.md`).
- Repo branch/PR flow: work happens on temporary task branches merged via PR;
  never commit directly on `nightly` (AGENTS.md).

## Brand Commitments

- Name: **Vityo**; product family Styio (language), Pafio (toolchain) — coined,
  short, vowel-ending names. Only Vityo is this repo's product.
- In-app brand device: the "V" monogram in a rounded accent square
  (`workbench_chrome.dart`).
- Gold accent lineage: prototype canonical `#F4C76A` -> app `obsidian`
  `#E6B566`. *(inferred as a recognizable trait, not confirmed binding — the
  redesign may keep, evolve, or retire it; flagged for user decision)*
- App icons are unmodified Flutter template placeholders; no logo/wordmark
  assets exist yet.

## Evidence on Hand

- Archived prototype with 13 style experiments (`prototype/vityo-*.html`) and
  the Graphite+Gold canonical draft (`prototype/editor.html`).
- Reference imagery in `reference-images/`: three photographic studies of
  layered glass / fluid translucent materials (dark violet workflow UI; light
  iridescent fluid ribbons) and one annotated cream workbench screenshot.
  *(inferred: these mark the user's current taste interest — depth, translucency,
  layered material — opposite of the incumbent flat hairline world)*
- Interaction/design handbook: `docs/specs/HANDWRITTEN-WEB-IDE-ENGINEERING-HANDBOOK.md`
  (source-over-display, IDE density over landing-page drama, surface/section/leaf
  layering).
- No testimonials, benchmarks, or commercial proof assets exist; none may be
  fabricated.

## Product Principles

1. Authority must be visible: machine facts and agent actions are rendered as
   inspectable surface state, never hidden in logs.
2. Complete without an agent: the edit-analyze-test-run-observe loop never
   depends on a connected runtime.
3. Source is canonical: display projections (glyphs, semantic blocks) never
   rewrite source text.
4. IDE density over landing-page drama: high information density, restrained
   feedback, tool-grade craft.
5. Open-source assets only: fonts, icons and imagery must be license-clean.
6. Flow made visible: dependencies, data flow and the execution graph are
   rendered graphically first; plain text remains the canonical source beneath
   the projection, one gesture away (user-pinned, 2026-09-30).

## Accessibility & Inclusion

Contrast floors (4.5:1 editor / 3:1 UI / 3:1 focus), diagnostics carry pattern
or shape in addition to color, font size floors, and responsive behavior across
the 360-599px and 600-899px bands are hard requirements, not aspirations.
