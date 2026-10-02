# Vityo Agent-Native IDE Architecture

**Purpose:** Define the stable ownership, state, process, and protocol boundaries between the Vityo IDE, compatible Agents, and the first-party Vityo Coding Agent companion runtime.

**Last updated:** 2026-10-02

**Status:** Current

## 1. Product Boundary

Vityo is the user-facing Styio agent-native IDE. It remains a complete IDE when no Agent is present
and becomes agent-native by treating supervised Agent work as a first-class, reviewable workbench
workflow.

Vityo Coding Agent is the first-party companion runtime, with an independently executable Rust
implementation selected for delivery. Its current Rust scaffold is not yet production-composed.
Other compatible Agents use the same advertised operations and permission rules. The IDE never
imports an Agent runtime implementation and never becomes a model-provider client.

The source-driven process diagram is maintained in [Vityo System Architecture](./Vityo-System-Architecture.md).
This document owns the detailed Agent boundary and current implementation status.

## 2. Ownership

| Owner | Owns | Does not own |
|---|---|---|
| Vityo IDE | Source Buffers, document/workspace revisions, language/compiler/runtime facts, workbench projections, Agent operation routing, protocol client state, permission presentation, change review, and transaction commit/rollback | Model request shapes, provider credentials, prompt/tool orchestration, Agent tool execution, durable Agent truth, or multi-Agent scheduling |
| Compatible Agent runtime | Model/provider routing, context selection, coding plan and loop, tool/MCP consumption, effect policy, durable sessions, validation orchestration, and optional multi-Agent coordination | IDE buffers, Flutter widgets, implicit machine access, or direct mutation of IDE-owned files |
| Vityo Agent Protocol | Versioned session DTOs, capability negotiation, correlated requests/events, permission and elicitation messages, artifacts, change proposals, receipts, cancellation, and structured errors | Product orchestration, UI state, provider implementation, or shared mutable objects |
| Styio ecosystem | Language, compiler, language-service, project/toolchain, package, execution, and runtime truth | Vityo workbench behavior or Agent orchestration |
| `vityod` local daemon | Durable desktop workspace/process services and supervised ACP Agent processes | Flutter presentation, Agent model/provider loop, Styio semantics, or first-party Agent authority |

The physical owners are:

```text
products/vityo_app/                 # Vityo IDE
products/vityo_coding_agent/        # selected independent Rust companion Agent executable
packages/vityo_agent_protocol/      # pure shared wire contract
products/vityo_app/native/vityod/   # separate local daemon executable
```

## 3. IDE State Model

The IDE is authoritative for the state a user can edit, review, or commit.

| State owner | Canonical state | Required behavior |
|---|---|---|
| IDE document/workspace owners and vityod | Source text, resource identity, document and workspace revisions | Monotonic revisions, source-fidelity preservation, and durable transactions |
| Workspace transaction service | Proposed edits, base revisions, preview, conflicts, commit/rollback receipts | Serialized commit lane; stale or overlapping edits fail without partial mutation |
| Capability registry | Language, toolchain, execution, debug, SCM, terminal, MCP, and Agent capabilities | Immutable snapshots with explicit unavailable/degraded reasons |
| Agent Client registry | Agent descriptors, processes, negotiated versions/capabilities, session correlation | Supervised lifecycle, bounded state, reconnect/cancel/terminate |
| Collaboration projection | Tasks, turns, plans, steps, tool activity, permissions, artifacts, diffs, receipts | Bounded hot history backed by durable Agent/protocol facts |
| Context export | Roots, files, selections, diagnostics, symbols, project graph, runtime and validation facts | Revision, provenance, sensitivity, redaction, and truncation metadata |

Flutter widgets render projections of these states. Widget lifetime is never the source of session,
permission, change, or execution truth.

## 4. Agent Client Boundary

The IDE-owned Agent Client and local daemon:

1. resolves a configured Agent command or remote transport while the daemon supervises local ACP processes;
2. launches or connects to an Agent without exposing unrelated environment or credentials;
3. negotiates protocol version and capabilities;
4. creates, loads, streams, cancels, reconnects to, and terminates sessions;
5. correlates concurrent sessions, requests, permissions, artifacts, and change proposals;
6. projects durable protocol events into bounded workbench state;
7. rejects malformed, oversized, unsupported, or stale messages with structured diagnostics.

The local Agent transport is a daemon-supervised ACP stdio process. Flutter communicates with
vityod through its typed local service protocol and does not embed or directly supervise the Rust
Agent. Standard ACP filesystem and terminal operations route through one Agent-neutral dispatcher
to the real path-bound buffer, workspace document/transaction, or PTY owner. The existing
revision-bound Vityo proposal extension remains for source-aware atomic changes. Capability
advertisement follows implemented owner routes. Styio-specific additions are namespaced and
negotiated; they do not reinterpret standard ACP methods.

The IDE does not:

1. send prompts directly to OpenAI-compatible or other model endpoints;
2. select model-provider fallback routes;
3. execute an Agent's tool loop;
4. persist the Agent's authoritative reasoning/session journal;
5. schedule subagents or worktrees; the connected Agent runtime owns multi-Agent scheduling.

Those responsibilities belong to the connected Agent runtime.

## 5. Context and Tool Flow

The IDE exposes bounded context and capabilities through narrow protocol messages and an
MCP-compatible host:

1. Workspace roots are explicit, canonicalized, user-consented capabilities.
2. Context items carry resource identity, revision, provenance, sensitivity, and truncation facts.
3. Secrets and unrelated environment values are excluded before serialization.
4. Root removal or permission revocation invalidates cached access before the next effect.
5. Tools use versioned schemas, bounded inputs/outputs, structured errors, cancellation, and
   capability discovery.
6. Tool declarations and model text are requests to policy, never enforcement authority.

An Agent runtime may decide which context and tools are relevant, but it cannot widen the IDE's
exported roots, schemas, permissions, or capability set.

## 6. Change and Effect Flow

```text
Observe task and authorized facts
  -> optional revisable task plan
  -> tool/effect request
  -> runtime and host policy
  -> user permission when required
  -> effect receipt
  -> revision-bound change proposal
  -> IDE diff/conflict preview
  -> user accept or reject
  -> IDE workspace transaction
  -> diagnostics/tests/validation facts
  -> durable receipt
```

Required invariants:

1. Agent-originated edits never bypass the workspace transaction owner.
2. A proposal is bound to the revisions from which it was derived.
3. Stale, conflicting, malformed, or unauthorized proposals fail closed.
4. Apply/reject/revert actions remain explicit and receipted.
5. Validation facts are re-read after accepted changes; model claims are not validation.
6. Mutating effects use explicit commit and idempotency boundaries in the Agent runtime.

## 7. Agent Workbench

Agent-native is an interaction and control property, not a synonym for chat.

The workbench provides:

1. a task center for active, waiting, blocked, completed, failed, and cancelled work;
2. session/thread views with user and Agent turns, optional revisable plans, steps, usage, and context summaries;
3. an activity timeline for tools, permissions, terminal activity, diagnostics, and validations;
4. change views with file/hunk diffs, base revisions, conflicts, apply/reject/revert controls;
5. steer, cancel, retry, reconnect, and Agent-switch controls;
6. persistent notifications for unresolved permission and review requests;
7. independent state for concurrent sessions.

An `Agent Panel` may remain one concrete presentation surface. It is a view into the Agent
Workbench, not the product category and not the runtime owner.

## 8. Security and Failure Isolation

1. The IDE sends an Agent process only the environment values intended for that process.
2. Provider credentials are resolved and consumed inside the Agent runtime's intended provider
   boundary; the IDE does not relay raw model credentials.
3. Protocol, MCP, terminal, tool, context, artifact, and diff payloads are bounded and redacted.
4. Permission grants are scoped by session, action/tool, root/resource, risk, expiry, and policy.
5. Revocation is enforced before the next effect.
6. One failed Agent process or session cannot corrupt editor state or terminate sibling sessions.
7. Process shutdown uses graceful termination, bounded escalation, and orphan verification.
8. Unsupported protocol versions, capabilities, or transports fail closed with actionable
   diagnostics.

## 9. Platform Routes

| Platform | Agent route |
|---|---|
| Windows / macOS / Linux | Supervised local companion process or compatible remote Agent |
| Android | Compatible local or remote Agent when allowed by platform capabilities |
| iOS | Remote compatible Agent through an iOS-safe transport |
| Web | Remote compatible Agent associated with the hosted workspace |

Platform transport differences do not move model/provider or Agent execution ownership into the IDE.

## 10. Current Implementation Status

The ownership boundary is established in reusable components: Vityo has an Agent Client gateway
(`products/vityo_app/lib/src/ide/agent_client`), daemon-owned ACP process supervision
(`products/vityo_app/native/vityod/crates/vityod-agent-host`), collaboration projection
(`products/vityo_app/lib/src/ide/workbench/agent_collaboration`), presentation Workbench
(`products/vityo_app/lib/src/presentation/agent_workbench`), MCP/context export, and IDE-owned
workspace transactions. Direct model-provider transport and Agent tool-loop ownership do not
belong in the IDE. This component boundary does not prove every application route composes those
services. In particular, `products/vityo_app/lib/main.dart` wraps the direct Flow Hero route in a
first-frame delivery probe and still does not load `AppBootstrap` or `VityoApp`. Flow Hero's
`WorkbenchController` has both pathless demo buffers and path-bound files; its local `File` open/save
path does not equal the shared daemon document and transaction authority. ACP operations must
resolve a real active workspace path and then use the matching buffer and owner services.

The current Dart companion still has an inspect-once `AgentRuntime` and an uncomposed separate
plan-first `CodingLoop`. The selected Rust executable scaffold is also not production-composed.
The delivery target requires the complete ReAct/tool/policy/session path and a real
OpenAI-compatible streaming adapter using nonsecret provider configuration and native secret
references. Deterministic integration uses a local HTTP/SSE fixture; remote provider calls remain
separate live acceptance. The interaction pattern is in
[ADR-0021](../adr/ADR-0021-react-agent-runtime-loop.md), while the process and operation decision is
in [ADR-0022](../adr/ADR-0022-agent-neutral-operation-boundary.md).

The standard ACP filesystem/terminal owner path is incomplete until negotiated requests pass from
the daemon poll through the neutral dispatcher to the actual buffer, transaction, and PTY owners and
their results return to the Workbench. Full Styio graph semantics and source rewiring remain deferred
because current language-service facts do not establish them.

The remaining product-closure work is tracked in
[Vityo-Implementation-Gaps.md](./Vityo-Implementation-Gaps.md): prove richer end-to-end Agent
Workbench workflows and first-party proposal/receipt behavior without moving Agent-runtime
ownership back into the IDE.

## 11. Related Owners

1. [Vityo Product Spec](./Vityo-Product-Spec.md)
2. [Vityo System Architecture](./Vityo-System-Architecture.md)
3. [Vityo Protocol and Capability Negotiation](./Vityo-Protocol-And-Capability-Negotiation.md)
4. [Repository execution workflow](../plan/EXECUTION-RUNBOOK.md)
5. [ADR-0019](../adr/ADR-0019-vityo-is-the-styio-agent-native-ide.md)
6. [ADR-0021: ReAct Agent Runtime Loop](../adr/ADR-0021-react-agent-runtime-loop.md)
7. [ADR-0022: Agent-Neutral Operations](../adr/ADR-0022-agent-neutral-operation-boundary.md)
