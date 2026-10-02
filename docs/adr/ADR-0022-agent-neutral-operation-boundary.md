# ADR-0022: Agent-Neutral Operations Across Independent Processes

**Purpose:** Define how the Flutter IDE, first-party Coding Agent, compatible Agents, and local daemon share authorized IDE operations and state.

**Last updated:** 2026-10-02

**Status:** Accepted

**Date:** 2026-10-02

**Deciders:** Architecture owner

## Context

Vityo needs to support the first-party Coding Agent and other compatible Agents without giving any
Agent direct access to Flutter widgets or a privileged path around IDE permissions and workspace
transactions. The user-facing client is Flutter/Dart. The selected first-party Coding Agent is a
Rust executable with its own process lifecycle. `vityod` is a separate existing Rust daemon that
provides local workspace and process services; it is neither the IDE nor the Coding Agent.

The first-party and compatible Agents use the same advertised capabilities and authorization.

The current Flutter entry wraps `FlowHeroApp` in an isolated first-frame delivery probe; its normal
launch still uses that route directly. The `WorkbenchController` contains
path-bound `BufferFile` values as well as built-in demonstration buffers, and its editor-only file
path does not by itself provide the daemon's durable document revision and transaction authority.
The selected operation dispatcher must resolve an actual active workspace path and reject
pathless demo buffers. Full Flow Hero source/graph editing remains a later feature: the current
restricted graph parser does not replace Styio's syntax, semantic facts, or legal rewrites.

The repository already contains an ACP-compatible Agent process host and durable vityod workspace
and PTY services. Those lower-level components alone do not prove that standard ACP filesystem or
terminal operations are advertised, dispatched to the real IDE owners, permission-checked, and
reflected in the frontend. ACP requests may be surfaced through the host poll, but the completed
dispatcher-to-owner route is the required acceptance boundary. The client also has session
reducers and collaboration projections, so
received state can be presented without making the Flutter view the Agent's runtime or durable
authority.

## Decision

1. **Keep process lifecycles independent.** Flutter/Dart Vityo, the Rust Vityo Coding Agent, and
   Rust `vityod` remain separate processes. The IDE does not import or embed the Agent runtime.
   `flutter_rust_bridge` is not the transport for either process boundary.
2. **Use one Agent-neutral capability and permission surface.** The first-party Agent and any
   compatible Agent use the same advertised operations, workspace scope, authorization, and
   transaction outcomes. No Agent receives a first-party privilege or a widget remote-control
   API. Multi-Agent scheduling belongs to the connected Agent runtime; the IDE projects concurrent
   sessions independently.
3. **Use standard ACP operations where their semantics fit.** Client-managed file access uses ACP
   v1 `fs/read_text_file` and `fs/write_text_file`; process interaction uses `terminal/create`,
   `terminal/output`, `terminal/wait_for_exit`, `terminal/kill`, and `terminal/release` where
   supported. Agents must negotiate and observe the client capability set before using them. Vityo
   advertises only operations that have a real authorized route.
4. **Keep source-aware edits revision-bound.** The existing namespaced Vityo workspace-change
   proposal extension remains the path for previewed, atomic, source-aware edits. Flow Hero
   operations resolve to the active path-bound `WorkbenchController` buffer; durable reads and
   commits go through the existing workspace document and transaction owners, and terminal work
   goes through vityod PTY services. Pathless demonstration buffers cannot be addressed as
   workspace resources.
5. **Project authoritative state and events.** The IDE owns canonical document/workspace
   revisions, unsaved buffer identity, transaction outcomes, permission decisions, and presentation
   state. The connected Agent owns model/provider activity and durable Agent task state. The
   frontend projects actual ordered operation, status, terminal-output, proposal, commit/reject,
   and validation facts with their session/execution identity and relevant revision. It does not
   expose raw hidden reasoning or timer-generated success.
6. **Keep Flow Hero language semantics upstream-owned.** A node drag or source edit is not proof of
   a valid Styio graph change. Full semantic graph display, legal edge rewiring, source rewrites,
   and compile/runtime correspondence remain blocked until Styio exposes revision-bound typed facts
   and supported edits. Pafio metadata is not a substitute.
7. **Use ReAct as the default Coding Agent loop.** The Agent observes current authorized facts,
   chooses a permitted action, receives an actual typed result, updates task state, and continues,
   requests input, or finishes with evidence. A concise revisable plan is optional state within the
   same loop. The pattern and deterministic acceptance remain in [ADR-0021](./ADR-0021-react-agent-runtime-loop.md).

`flutter_rust_bridge` generates Dart-to-Rust FFI bindings for Rust library calls; it does not
supervise an independently executable ACP Agent or replace the local daemon protocol. Its
library-call model is documented in the [FRB contribution overview](https://cjycode.com/flutter_rust_bridge/guides/contributing/overview)
and [CST/codec description](https://cjycode.com/flutter_rust_bridge/guides/contributing/submodules/cst-codec).
ACP's separate [filesystem API](https://agentclientprotocol.com/protocol/v1/file-system) and
[terminal API](https://agentclientprotocol.com/protocol/v1/terminals) define the client-managed
operations used at the Agent process boundary. A future measured need for an in-process pure Rust
library may be evaluated separately without changing these independent-process links.

## Consequences

1. A protocol capability flag is not production evidence. Deterministic tests must exercise the
   actual ACP request, authorization, buffer/service dispatch, result, and Workbench projection
   paths, including stale revisions, rejected permissions, cancellation, and unsupported targets.
2. Agent session events and workspace state have distinct authorities. A frontend projection does
   not become the Agent journal; an Agent proposal does not become an IDE commit before the
   workspace transaction reports success.
3. The current ACP host and low-level daemon services remain incomplete until standard filesystem/
   terminal requests traverse the dispatcher and reach their real owner services.
4. The current Rust executable scaffold does not establish a production provider/tool loop. A
   compile or `--version` check cannot substitute for deterministic ReAct, policy, transaction,
   recovery, and protocol tests.
5. First-party and compatible Agents share the same externally advertised operations. A provider
   conversation or real development task is separate live acceptance by the user's designated
   Agent.
6. This process boundary does not select a canvas library or claim source/graph feature parity.
   Full Flow Hero semantic editing remains a separately deferred feature milestone.

## Alternatives considered

1. **Link the Agent or daemon into Flutter through FRB:** rejected for independently supervised
   processes because FFI library calls do not provide the selected process, session, reconnect, or
   authorization boundary.
2. **Expose one-off Flutter widget commands to the first-party Agent:** rejected because it would
   create Agent-specific authority and bypass the common advertised-operation contract.
3. **Invent a competing private filesystem/terminal protocol:** rejected where standard ACP
   operations cover the semantics. The existing Vityo extension is retained only for
   revision-bound workspace proposals and related source-aware behavior.
4. **Treat the Flow Hero graph as semantic authority:** rejected because only Styio can establish
   supported syntax, graph facts, and valid rewrites.

## Related records

- [Vityo System Architecture](../design/Vityo-System-Architecture.md)
- [Vityo Agent-Native IDE Architecture](../design/Vityo-Agent-Native-IDE-Architecture.md)
- [Vityo Product Spec](../design/Vityo-Product-Spec.md)
- [Vityo Implementation Gaps](../design/Vityo-Implementation-Gaps.md)
- [Vityo ACP v1 schema](../../packages/vityo_agent_protocol/schema/acp-v1.schema.json)
- [ADR-0020: Source-Authoritative Flow Hero](./ADR-0020-source-authoritative-flow-hero.md)
- [ADR-0021: ReAct Agent Runtime Loop](./ADR-0021-react-agent-runtime-loop.md)
