# ADR-0022: Agent-Neutral Operations Across Independent Processes

**Purpose:** Define how the Flutter IDE, first-party Coding Agent, compatible Agents, and local daemon share authorized IDE operations and state.

**Last updated:** 2026-10-03

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

The normal Flutter entry still launches `FlowHeroApp` directly. For an explicit, nonempty
`VITYO_WORKSPACE`, `AgentBridge.attach` resolves the independently installed Rust Agent descriptor,
connects the selected workspace to vityod, and composes `FlowHeroAgentOperationPort`. The operation
port reads the active path-bound `WorkbenchController` buffer, carries its source and persisted
workspace/document observations, and persists through the existing atomic workspace transaction
store. Built-in pathless demonstration buffers are unavailable as workspace resources. Full Flow
Hero source/graph editing remains a separate deferred feature: the restricted graph parser does not
replace Styio syntax, semantic facts, or legal rewrites.

The standard ACP filesystem and terminal route is implemented through the client, vityod session
poll and correlated response, neutral operation dispatcher, live buffer/workspace owners, and PTY
registry. Deterministic operation and proposal tests cover the actual path. A fresh Rust executable
process has negotiated ACP, initialized a session, and created a session through the client without
issuing a provider prompt. Exact permission option IDs and proposal outcomes are correlated through
the protocol. These checks establish the local process/operation join, not a live model conversation,
a real development task, or production MCP server attachment.

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
4. **Keep source-aware edits revision-bound.** The negotiated
   `_vityo.dev/workspace-change-proposal` extension carries a workspace revision and per-document
   base revisions to the host review surface. Flow Hero operations resolve to the active path-bound
   `WorkbenchController` buffer; durable reads and commits go through the existing workspace
   document and atomic transaction owners, and terminal work goes through vityod PTY services.
   Pathless demonstration buffers cannot be addressed as workspace resources. A missing-file read
   returns known absence and its observed workspace revision, not a fabricated document revision.
5. **Keep path and permission authority in their owners.** Standard ACP filesystem requests use the
   host-established session/root scope. Vityod and the IDE validate the actual filesystem target,
   workspace binding, symlink/root constraints, and caller-observed revisions at the effect
   boundary. Standard authorized file writes use the Agent runtime's normal grants and atomic CAS.
   A source-aware proposal has one explicit host-reviewed Apply/Reject decision for that pending
   transaction; do not add a duplicate generic permission prompt. The exact supplied permission
   option is returned to the correlated ACP request. Persistent `AllowAlways` is Agent journal
   state; `AllowOnce` is not persisted.
6. **Project authoritative state and events.** The IDE owns canonical document/workspace
   revisions, unsaved buffer identity, transaction outcomes, permission decisions, and presentation
   state. The connected Agent owns model/provider activity and durable Agent task state. The
   frontend projects actual ordered operation, status, terminal-output, proposal, commit/reject,
   and validation facts with their session/execution identity and relevant revision. It does not
   expose raw hidden reasoning or timer-generated success.
7. **Keep Flow Hero language semantics upstream-owned.** A node drag or source edit is not proof of
   a valid Styio graph change. Full semantic graph display, legal edge rewiring, source rewrites,
   and compile/runtime correspondence remain blocked until Styio exposes revision-bound typed facts
   and supported edits. Pafio metadata is not a substitute.
8. **Use ReAct as the default Coding Agent loop.** The Agent observes current authorized facts,
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

The Rust executable accepts an empty ACP `mcpServers` configuration but rejects a non-empty value
on session creation/loading with `-32003 MCP capability unavailable`. The migrated RMCP library
and tool-source modules do not provide a production MCP server attachment lifecycle; the client
does not silently ignore the requested servers.

## Consequences

1. A protocol capability flag is not production evidence. Deterministic tests exercise the actual
   ACP request, authorization, buffer/service dispatch, result, and Workbench projection paths,
   including stale revisions, rejected permissions, cancellation, and unsupported targets. The
   process test verifies the selected installed Rust executable through initialize and session/new
   without depending on a live provider.
2. Agent session events and workspace state have distinct authorities. A frontend projection does
   not become the Agent journal; an Agent proposal does not become an IDE commit before the
   workspace transaction reports success.
3. The selected Rust executable and production client descriptor are joined through the independent
   process boundary. The fresh-binary process test covers protocol and session startup without
   claiming provider completion. Session/event/journal behavior is tested by the Rust runtime suites.
4. Production MCP server attachment remains unavailable: non-empty `mcpServers` is rejected rather
   than accepted and ignored.
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
