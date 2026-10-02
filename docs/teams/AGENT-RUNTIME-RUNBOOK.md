# Agent Runtime Runbook

**Purpose:** Define the Coding Agent runtime owner's responsibilities, owned paths, review checklist, and required gates. Enforce credential safety, permission audit, patch workflow, and journal/audit compliance.

**Last updated:** 2026-10-02

## Mission

Own the standalone Vityo Coding Agent runtime: model/provider routing, context selection, tools,
policy, coding loops, durable sessions, and multi-agent scheduling. The IDE owns only the protocol
client and collaboration workbench. The Agent never stores raw API keys, directly mutates IDE files,
or bypasses host transactions.

The target runtime is implemented in Rust as an independent executable. The migration is in
progress: Dart remains the current Agent behavior until provider, tool, policy, session, protocol,
and IDE-consumer behavior are covered through the Rust implementation. An executable identity
probe or wire-contract-only test does not establish that cutover.

## Owned Surface

Primary paths:
1. `products/vityo_coding_agent/src/` — Rust target runtime.
2. `products/vityo_coding_agent/lib/src/`, `products/vityo_coding_agent/bin/`, `products/vityo_coding_agent/test/`, and `products/vityo_coding_agent/integration_test/` — current Dart runtime and tests during migration; remove the replaced implementation and active checks when Rust cutover is complete.
3. `products/vityo_coding_agent/Cargo.toml` and `Cargo.lock` — Rust runtime dependency boundary.
4. `packages/vityo_agent_protocol/` — shared wire contract and Dart client binding, not Agent implementation.
5. `docs/teams/AGENT-RUNTIME-RUNBOOK.md`

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

Minimum (select the focused subset appropriate to the change):
```bash
cd products/vityo_coding_agent && dart analyze && dart test
cd packages/vityo_agent_protocol && dart analyze && dart test
python3 scripts/check_security_baseline.py
```

The Dart commands above still verify the current runtime behavior. Rust changes also require the
locked Cargo workspace tests and the Coding Agent suite registered through
`python3 scripts/vityo_quality.py --product coding-agent --suite full`. The canonical pipeline
collects instrumented Rust coverage for both Rust workspaces and runs the registered IDE consumer
suites. Its current Coding Agent behavior suite still exercises Dart, so Rust coverage and wire
contracts alone do not establish a production cutover. Do not claim cutover until the Rust behavior
suite and real IDE-consumer path are registered and pass.

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
