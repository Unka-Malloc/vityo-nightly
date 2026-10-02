# ADR-0021: ReAct Is the Default Coding Agent Loop

**Purpose:** Select the default interaction pattern for the Vityo Coding Agent runtime.

**Last updated:** 2026-10-02

**Status:** Accepted

**Date:** 2026-10-02

**Deciders:** Architecture owner

## Context

The IDE and its companion Agent have separate owners. The IDE owns source/workspace state, policy enforcement, permission presentation, proposal review, and transaction commits. The Agent runtime owns model/provider calls, context selection, tool orchestration, and durable task state.

ReAct is an established Agent pattern that interleaves actions with observations from tools or the environment, allowing the next action to respond to current evidence. Plan-and-Execute makes a complete plan first, delegates steps to an executor, and replans when needed. The latter can reduce large-model calls for suitable multi-step work; the former is a simpler default when edits, diagnostics, permissions, and test results can change the next action.

Current code is scaffolding, not a complete model-driven coding Agent:

1. `AgentRuntime` delegates to `AgentSessionService`; that service asks `HostWorkspace.inspect` once and completes or rejects the host request.
2. The CLI and stdio endpoint compose an `InMemoryHostWorkspace`. The configured session transport can therefore prove protocol connectivity without proving provider inference or real workspace tools.
3. `CodingLoop` is a separate plan-first implementation. It requires `CodingPlanner.createPlan`, walks ready plan steps, proposes changes, and records validation/transaction facts. The repository contains no production `CodingPlanner` implementation connecting it to `AgentRuntime` or the stdio endpoint.
4. The IDE can provide supervised sessions and revision-bound proposal/transaction surfaces, but the current Flow Hero route does not compose them.

These are independent observations of current wiring. Selecting a target architecture does not make any of the missing runtime stages implemented.

The current Rust Coding Agent package is a separate executable scaffold, not a composed provider/tool
runtime. The selected implementation migrates the complete Coding Agent capability surface to Rust.
It includes a real OpenAI-compatible streaming adapter configured by a nonsecret `--provider-config`
file and native secret references. Deterministic verification uses the production adapter against a
local HTTP/SSE fixture and exercises the actual executable; remote provider conversations remain
separate live acceptance. The process and IDE operation boundary is recorded in
[ADR-0022](./ADR-0022-agent-neutral-operation-boundary.md).

## Decision

Use one ReAct-style action/observation loop as the default Rust Coding Agent runtime:

```text
observe current task and authorized workspace facts
  -> choose one permitted action
  -> request policy/permission where required
  -> execute through an authorized tool or IDE proposal boundary
  -> receive a typed result or rejection
  -> update task state and observe relevant changed facts
  -> continue, ask for input, or finish with evidence
```

The Agent may hold a concise, revisable user-facing plan as task state when a task benefits from one. Planning does not require a second mandatory Agent service or a separate plan-before-all-tools phase. Tool permissions, cancellation, workspace revisions, transaction commit/reject, test execution, and validation receipts remain explicit runtime/application contracts around the model loop.

Do not require or persist raw hidden chain-of-thought as a runtime protocol or user-facing trace. Expose concise action summaries, requested permissions, tool/result status, proposed and applied changes, and validation evidence. Observations must come from the authorized workspace/tool result, not from a model's unsupported claim.

This selects an interaction architecture, not a model, provider, framework, wire-schema version, prompt format, or token budget. It does not add an arbitrary fixed timeout; use the task's explicit cancellation and budget/deadline policy.

## Rationale

Coding tasks commonly reveal new facts after inspecting files, applying an approved edit, or running a deterministic check. Updating the next decision after each actual observation fits that changing environment and keeps authorization adjacent to each effect. Optional plans retain user steering and task visibility for longer work without requiring two orchestrators.

Plan-and-Execute remains a valid later optimization for tasks with stable, independent subtasks and measurable model-call/latency benefit. Its additional planner/executor boundary is not justified as a required architecture before such evidence exists. A plan is revisable state within the selected loop.

The original ReAct work describes interleaving reasoning and actions to gather environmental observations and update action plans. LangChain's published Plan-and-Execute comparison describes explicit planning as a way to execute multiple steps without consulting the larger planner after every action, with replanning for feedback. These sources describe patterns and tradeoffs, not a guarantee of coding quality:

- [ReAct: Synergizing Reasoning and Acting in Language Models](https://arxiv.org/abs/2210.03629)
- [Plan-and-Execute Agents](https://www.langchain.com/blog/planning-agents)

## Consequences

1. Future production work connects an actual provider/model turn, authorized tool action, typed observation, task-state update, and the existing IDE proposal/transaction boundary in one deterministic-testable loop.
2. Tests use fake model and tool ports, while exercising the real scheduler, permissions, cancellation, workspace revision handling, validation, and receipts. They do not call a real provider to claim deterministic engineering coverage.
3. Plans and tool events are projections of runtime-owned task facts. A plan alone does not authorize a tool or workspace effect.
4. The current plan-first `CodingLoop` may be changed when the approved runtime milestone implements this target. Its incomplete implementation does not create a compatibility obligation.
5. Provider credentials and prompts remain inside the Agent runtime boundary; the Vityo IDE continues to communicate through the versioned Agent Protocol.
6. A real provider conversation remains separate live acceptance by the user's designated Agent.
7. Rust owns the first-party executable and its provider/runtime implementation. The Flutter/Dart
   client and separate `vityod` daemon communicate through process protocols; this ADR does not
   select FRB or move Agent scheduling into the IDE.

## Alternatives considered

1. **Require Plan-and-Execute for every coding task:** rejected as the default because it adds a mandatory planning/execution split even for short interactive edits whose next step depends on new observations.
2. **Build a new orchestration paradigm:** rejected because it would add new concepts without solving a requirement that the established ReAct loop, authorization boundaries, and revisable plan state do not already cover.
3. **Treat current `CodingLoop` as completed Agent integration:** rejected because no production planner connects it to the runtime endpoint, and the endpoint's host inspection is not model-driven coding.
4. **Expose hidden reasoning as the user-visible trace:** rejected because workbench control needs actionable events, permissions, results, proposals, and validation evidence; it does not require raw private reasoning.

## Related records

- [Vityo System Architecture](../design/Vityo-System-Architecture.md)
- [Vityo Agent-Native IDE Architecture](../design/Vityo-Agent-Native-IDE-Architecture.md)
- [Vityo Implementation Gaps](../design/Vityo-Implementation-Gaps.md)
- [Vityo Agent Protocol schema](../../packages/vityo_agent_protocol/schema/acp-v1.schema.json)
- [ADR-0019: Vityo Is the Styio Agent-Native IDE](./ADR-0019-vityo-is-the-styio-agent-native-ide.md)
- [ADR-0022: Agent-Neutral Operations](./ADR-0022-agent-neutral-operation-boundary.md)
