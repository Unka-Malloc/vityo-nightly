# ADR-0020: Source-Authoritative Flow Hero

**Purpose:** Establish the source, semantic, transaction, Agent, and execution ownership for the interactive Flow Hero editor.

**Last updated:** 2026-10-02

**Status:** Accepted

**Date:** 2026-10-02

**Deciders:** Architecture owner

## Context

The Flow Hero interface is a presentation and interaction direction for a Styio editor. Users need to edit real program text, move visual nodes, reconnect supported flows, and see changes reflected in both views. Agent-originated changes must appear as they are actually proposed or applied. The canvas must retain the current visual baseline, and adopting an established canvas package is preferred where its public APIs support the required lifecycle.

The current package entry point starts `FlowHeroApp` directly. Flow Hero currently has a local sample graph, demonstration source and parser, timer-driven run presentation, and a scripted Agent transcript. `AppBootstrap.load()` and `VityoApp` exist but are not called from `lib/main.dart`. The separate Agent Client and IDE transaction services are not connected to this route. See [Vityo-System-Architecture.md](../design/Vityo-System-Architecture.md#13-application-composition-and-current-flow-hero-entry) and [Vityo-Implementation-Gaps.md](../design/Vityo-Implementation-Gaps.md).

Styio owns source syntax, language meaning, and valid rewrites. Pafio's project graph is workspace/package metadata and cannot stand in for program data flow. A visual graph must therefore remain a revisioned projection of source semantics, not an independent program representation.

## Decision

1. **One editable program authority.** The IDE workspace/document services own source text, document revisions, history, and persistence. The source dock edits that document, using an anchored selected range if it presents only one part of the program. It does not keep a duplicate snippet buffer.
2. **The graph is derived.** A typed Styio language snapshot for a document revision supplies semantic nodes, directional ports/edges, identities, source locations, diagnostics, and editability facts. View state adds node positions and viewport state without changing program semantics.
3. **Text edits and graph edits converge.** Full-editor edits, dock edits, and accepted semantic rewires enter the same document transaction and analysis path. A node move changes view state only.
4. **Reconnection proposes a source edit.** A drop intent identifies the current connection/endpoint and expected document revision. Styio determines whether the proposed connection is legal and, if so, returns a source edit proposal or a diagnostic. Vityo applies an accepted edit once through its revision-checked workspace transaction path, then refreshes semantic facts. During validation the committed edge remains authoritative. Cancel, rejection, or a stale revision leaves source and graph unchanged. Async semantic validation belongs in the application service, not a synchronous canvas completion predicate.
5. **Agent changes use the same path.** The Agent runtime sends protocol updates and revision-bound change proposals. IDE policy and the existing Workbench review/permission path govern their application. A proposed edit remains visually distinct from a committed edit; subsequent analysis produces the graph update and animation.
6. **Execution stays separate from editing.** Runtime animation consumes ordered execution facts bound to an execution identity and source revision. Graph highlighting requires a source/semantic mapping from the language or runtime owner. Replay is labeled as replay; editing animation is never presented as runtime activity.
7. **Keep rendering incremental and familiar.** Preserve stable semantic identity, manual positions, and Vityo's current card, port, cable, palette, and motion design. Update and animate only affected graph items. Automatic layout runs on initial arrangement or an explicit arrange action, not on each keystroke. Respect reduced-motion settings.
8. **Reuse generic canvas infrastructure when it meets the contract.** A graph package may own pointer interactions, viewport, retained rendering, path effects, and generic node/edge layout. It does not own Styio syntax or validity. Vyuh Node Flow is the current canvas candidate, not an adopted production dependency. The inspected 0.31.0 and 0.32.0 connection lifecycle removes a single-port connection when drag begins and does not preserve it on veto/cancel; the locked-edge path also bypasses policy. Its completion callback is synchronous and also serves connection validation queries, so it cannot represent one asynchronous source-edit request. Version 0.32.0 also requires `vector_math ^2.4.2`, which does not resolve with the current pinned Flutter test SDK. These are adoption blockers to address through upstream changes or a supported public API before production use. GraphView is an optional directed layout-coordinate source only; keep one canvas renderer. Do not create a maintained fork as part of this foundation. Preserve `prototype/` as a permanent independent asset.

The required semantic handoff belongs to the existing [Styio Language Service Adapter Contract](../external/for-styio/Styio-Language-Service-Adapter-Contract.md). This ADR defines behavior, not a public wire schema. The runtime event envelope remains owned by [RuntimeEventAdapter](../contracts/RuntimeEventAdapter.md).

## Consequences

1. `AppBootstrap` becomes the single source of shared IDE service instances for Flow Hero. The current direct `FlowHeroApp` package entry is not evidence of that wiring.
2. Source syntax, typed flow snapshots, stable semantic identities, source locations, and semantic rewire edit proposals are Styio capabilities. Vityo must expose a capability gap if the selected Styio service cannot provide them.
3. Stale analysis cannot replace facts for a newer document revision. An incomplete parse may keep the last known layout visible only with its stale/incomplete state identified.
4. Node placement may be persisted as view state independently from the source file. It cannot change edge endpoints.
5. Agent progress can be animated only from protocol facts or applied document changes actually received. UI timers and demo text cannot claim live Agent edits, test success, or execution events.
6. CI can prove the editor, adapter, transaction, protocol, and renderer behavior deterministically with source fixtures and protocol events. A real provider conversation is separate live acceptance.
7. Existing component research is evidence for a later package decision, not evidence of production dependency adoption or complete visual/performance parity.

## Required deterministic acceptance

Before this editor is accepted as production-wired, tests must exercise the actual implementation and prove:

1. An ordinary supported Styio fixture yields directional graph facts tied to its document identity and revision; syntax errors never create fabricated semantic edges.
2. Editing source in the dock changes the same document observed by the full editor, undo/redo, language service, and save path.
3. Moving a node changes layout state but not source or semantic endpoints.
4. An accepted supported rewire produces a valid Styio edit and one undoable revision. Invalid, cancelled, and stale requests preserve source and committed graph; concurrent analysis cannot overwrite newer facts.
5. Deterministic Agent protocol fixtures show proposal, permission/review, accepted transaction, rejected proposal, and resulting graph transitions through the production services. No real model is needed for these checks.
6. Source-bound ordered execution fixtures highlight only the corresponding semantic identity and revision; replay is not reported as a live stream.
7. The selected styled canvas matches or improves the tagged Vityo baseline for the accepted themes, selection, edge direction, dragging, reconnection feedback, animation, and reduced-motion behavior. The proof covers an ordinary supported SDK resolution and public APIs; it does not rely on private package imports or dependency overrides.

## Alternatives considered

1. **Keep the canvas as an independent program store:** rejected because two editable authorities create conflicting history, stale state, and ambiguous Agent updates.
2. **Treat any dropped visual edge as a valid program connection:** rejected because only Styio can validate source semantics and produce a valid rewrite.
3. **Use a generic canvas package as language/runtime graph authority:** rejected because canvas libraries do not know Styio's compiler or runtime contracts.
4. **Keep the bespoke canvas as the final renderer by default:** not selected. It remains a possible option only if established components cannot satisfy lifecycle or visual-parity requirements through their supported APIs.

## Component references

- [Vyuh Node Flow 0.32.0](https://pub.dev/packages/vyuh_node_flow/versions/0.32.0)
- [Vyuh connection API at the inspected source revision](https://github.com/vyuh-tech/vyuh_node_flow/blob/72bd69500d882f175970b5e6eac646b2de09c583/packages/vyuh_node_flow/lib/src/editor/controller/connection_api.dart)
- [GraphView 1.5.1](https://pub.dev/packages/graphview/versions/1.5.1)
- [GraphView Sugiyama layout implementation](https://github.com/nabil6391/graphview/blob/b9572aaf789fc98961d7b97063a68aea351bd200/lib/layered/SugiyamaAlgorithm.dart)

## Related records

- [Vityo System Architecture](../design/Vityo-System-Architecture.md)
- [Vityo Product Spec](../design/Vityo-Product-Spec.md)
- [Vityo Implementation Gaps](../design/Vityo-Implementation-Gaps.md)
- [Styio Language Service Adapter Contract](../external/for-styio/Styio-Language-Service-Adapter-Contract.md)
- [LanguageServiceAdapter](../contracts/LanguageServiceAdapter.md)
- [RuntimeEventAdapter](../contracts/RuntimeEventAdapter.md)
- [ADR-0019: Vityo Is the Styio Agent-Native IDE](./ADR-0019-vityo-is-the-styio-agent-native-ide.md)
