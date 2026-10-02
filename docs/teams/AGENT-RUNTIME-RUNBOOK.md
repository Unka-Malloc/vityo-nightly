# Agent Runtime Runbook

**Purpose:** Define the Coding Agent runtime owner's responsibilities, owned paths, review checklist, and required gates. Enforce credential safety, permission audit, patch workflow, and journal/audit compliance.

**Last updated:** 2026-10-03

## Mission

Own the standalone Vityo Coding Agent runtime: model/provider routing, context selection, tools,
policy, coding loops, durable sessions, and multi-agent scheduling. The IDE owns only the protocol
client and collaboration workbench. The Agent never stores raw API keys, directly mutates IDE files,
or bypasses host transactions.

The current runtime is the independent Rust executable `vityo-coding-agent`. Its single product
control surface is ACP stdio, invoked with explicit `--provider-config ABSOLUTE_PATH` and
`--session-dir ABSOLUTE_PATH`; standard graphical and non-graphical hosts use this same process
protocol. There is no separate inspect-only/headless CLI. The default runtime loop is ReAct, with an
optional revisable plan. Provider calls use the configured OpenAI-compatible adapter; live provider
acceptance remains separate from deterministic engineering tests.

The selected Flow Hero route launches the packaged executable only when a non-empty
`VITYO_WORKSPACE` is explicitly supplied. Without that workspace scope, it stays in demo mode and
does not launch the first-party process; the client must not infer a workspace root.

## Owned Surface

Primary paths:
1. `products/vityo_coding_agent/src/` — Rust runtime, ACP host, tool/policy implementations, and application composition.
2. `products/vityo_coding_agent/Cargo.toml` and `Cargo.lock` — Rust runtime and dependency boundary.
3. `packages/vityo_agent_protocol/` — shared wire contract and Dart client binding, not Agent implementation.
4. `docs/teams/AGENT-RUNTIME-RUNBOOK.md`

The production ACP host supports standard file and terminal operations and the correlated
`_vityo.dev/workspace-change-proposal` review extension. It rejects non-empty `mcpServers` on
`session/new` and `session/load` with JSON-RPC error `-32003`; the RMCP library and deterministic MCP
peer tests do not establish a production MCP attachment lifecycle.

Architecture decisions remain owned by [the Agent architecture SSOT](../design/Vityo-Agent-Native-IDE-Architecture.md).

IDE Agent Client and Workbench paths are review dependencies, not Agent-runtime-owned surfaces:

1. `products/vityo_app/lib/src/ide/agent_client/`
2. `products/vityo_app/lib/src/ide/workbench/agent_collaboration/`
3. `products/vityo_app/lib/src/presentation/agent_workbench/`

Key SSOTs:
1. `Agent architecture -> ../design/Vityo-Agent-Native-IDE-Architecture.md`
2. `安全与供应链 -> ../governance/SECURITY-AND-SUPPLY-CHAIN.md`
3. `API 兼容性 -> ../governance/API-COMPATIBILITY.md`

## Daily Workflow

1. Review PRs touching agent-owned paths against the review checklist.
2. Verify no raw API keys in any serialized output or settings file.
3. Verify display projections redact secrets.
4. Verify new agent tools declare appropriate permission levels.
5. Verify patch workflow goes through workspace edit transaction (not direct file writes).
6. Verify tool calls create journal entries with permission level, timestamp, and outcome.
7. Verify permission model changes fail closed for unknown values and remain compatible with module-contributed tools.
8. Verify security-sensitive changes pass the sandbox/security baseline gate.

## Change Classes

1. Small: New Agent-runtime tool or minor context-selection update. Run focused Coding Agent tests.
2. Medium: New provider kind, runtime policy change, or provider-routing change. Run the focused Coding Agent suite and protocol tests.
3. High: Credential model, context-export contract, or Agent architecture change. Requires security review and an ADR or owning-SSOT update.

## Required Gates

Focused Rust changes should run their relevant crate tests and the Agent quality requirement that
owns the behavior. The canonical suite is:
```bash
python3 scripts/vityo_quality.py --product coding-agent --suite full
python3 scripts/check_security_baseline.py
```

`python3 scripts/vityo.py test` is the canonical contributor path. It collects instrumented locked
workspace coverage for the Coding Agent and daemon, runs the Rust Agent requirement suite, all
registered portable IDE suites, Flutter tests, and required pinned Styio fixtures. The `coverage`
stage evaluates those saved reports without rerunning suites. IDE consumer changes also require
focused Flutter/client and daemon-protocol tests; a Rust-only test does not prove host wiring.

## Cross-Team Dependencies

1. Architecture team must review agent architecture changes.
2. Security/governance team must review credential safety and permission model changes.
3. Editor/shell team must review Agent Client, permission presentation, change application, or Workbench rendering changes.
4. Architecture team must reject any new model/provider, tool-loop, durable-session, or multi-Agent ownership in the IDE.

## Handoff / Recovery

Record:
1. Which agent models were changed.
2. Which permission levels were added or modified.
3. Which credential safety rules were enforced.
4. Which provider configurations were updated.
5. Next recovery point and pending agent features.
