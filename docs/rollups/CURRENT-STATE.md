# Current State

**Purpose:** Provide the compact entry point for Vityo's product identity,
governance, and ecosystem-owner boundaries.

**Last updated:** 2026-10-03

## Summary

1. **Vityo is the agent-native IDE for Styio.** It is the sole user-facing
   product; compatible Agents connect through the versioned Vityo Agent
   Protocol.
2. Vityo owns source and workspace revisions, IDE presentation, adapter
   composition, permission presentation, change preview, and workspace
   transactions. Agent runtimes own provider access, context selection, tool
   loops, Agent policy, durable sessions, and multi-Agent orchestration.
3. Vityo does not own package, compiler, registry, or hosted-workspace truth.
   Editing, language service, build, test, run, and observation remain fully
   available without an Agent.
4. Local project facts come only from `pafio metadata --json` (`metadata v1`).
   Missing or invalid metadata produces a blocked project snapshot rather than
   local manifest or cache inference.
5. Local project workflows use Pafio's stable workflow JSON. Pafio owns project
   sync, build orchestration, vendor, pack, and publish clients.
6. Compiler identity and capability come directly from
   `styio --machine-info=json`. Styio owns diagnostics, receipts, runtime
   events, and language-service contracts.
7. Hosted workspace lifecycle, registry control, cloud jobs, and workers come
   only from `Platform hosted-workspace v1`.
8. Vityo does not read Pafio private storage and does not install, select, pin,
   or cache Styio through Pafio.
9. The opt-in desktop product gate composes real Pafio metadata with a real
   system Styio machine contract. The coordinated ecosystem matrix additionally
   verifies Platform hosted and registry ownership at fixed revisions.
10. The direct IDE-side provider/controller implementation has been removed.
    Agent collaboration uses only the versioned Agent Client, collaboration
    projection, presentation Workbench, bounded MCP/context export, and
    workspace transactions.
11. Documentation indexes, lifecycle checks, repository hygiene, security, and
    release evidence remain mandatory governance surfaces.
12. Packaged desktop builds run one isolated per-user `vityod` service process as
    the durable owner of local workspace, process, tool, and Agent-host activity;
    it is a Rust workspace under `products/vityo_app/native/vityod/`, and the
    canvas surface reaches it through the versioned `vityo_daemon_protocol`.
13. The first-party Coding Agent is a Rust ACP stdio runtime in
    `products/vityo_coding_agent/`. It is launched through the same
    `--stdio-agent` entry regardless of host, and there is no second headless
    product CLI.
14. The Flow Hero workbench is the production boot target
    (`products/vityo_app/lib/main.dart` boots `FlowHeroApp`). The hand-written
    `prototype/` remains a separately maintained, permanently preserved source
    asset with its own entrypoints, dependency governance, and tests.

## Read Order

1. `../design/Vityo-Product-Spec.md`
2. `../design/Vityo-Agent-Native-IDE-Architecture.md`
3. `../design/Vityo-System-Architecture.md`
4. `../design/Vityo-Implementation-Gaps.md`
5. `../contracts/ProjectGraphAdapter.md`
6. `../contracts/HostedWorkspaceCloudRoutes.md`
7. `../external/for-pafio/Pafio-Metadata-Contract.md`
8. `../external/for-styio/Styio-Compile-Run-Contract.md`
9. `../external/for-platform/Platform-Hosted-Workspace-Contract.md`
10. `../teams/ADAPTER-CONTRACTS-RUNBOOK.md`

## Recovery Baseline

```bash
python3 scripts/docs-lifecycle.py refresh
python3 scripts/docs-index.py --write
python3 scripts/docs-audit.py
python3 scripts/repo-hygiene-gate.py --mode tracked
```
