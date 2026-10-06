# Vityo Release Checklist

**Purpose:** Define release and checkpoint evidence for Vityo's product boundary, deterministic CI, platform builds, security, performance, and later live acceptance.

**Owner:** Governance owner (`CODEOWNERS` -> governance domain)
**Last updated:** 2026-10-02

## Release Rule

A release candidate must prove the product and boundary claims below. A checkpoint candidate records evidence for every claim in its authorized scope and marks unrelated release criteria out of scope:

1. Vityo remains the sole product identity and is described as the agent-native IDE for Styio.
2. IDE ownership follows [the system architecture](../design/Vityo-System-Architecture.md):
   `view_ide/` owns presentation-independent IDE services and contracts; `ide/` owns editor,
   document/workspace, Agent Client, and collaboration application state; `app/` composes shared
   services; and `view_render/` owns Flutter presentation. Presentation imports only narrow public
   model, adapter, or projection paths registered from their actual owner. The allowlist is enforced
   by `scripts/check_architecture_boundaries.py`; registration does not claim that a consumer or
   feature is wired into production.
3. IDE, companion Agent runtime, and shared protocol code live only at their final owner paths;
   removed package identities and forwarding roots are not recreated.
4. Sandbox, Agent permission, module manifest security, redaction, and secret handling have explicit
   tests or gate coverage.
5. Performance-sensitive editor, language, workspace, runtime, Agent context, watcher, and UI
   virtualization paths have benchmark files and a regression gate path.
6. The IDE can complete `edit -> analyze -> test -> run -> observe` without an Agent, and an
   attached Agent task exposes plan, permission, change preview, and verification receipt.

A formal product release candidate must additionally prove that the launch artifact is the production deliverable, not a debug, prototype, lab, or experimental build. Release closure requires platform release builds, packaging/signing or distribution evidence, release notes, install/update/uninstall behavior, rollback or recovery evidence, and no skipped build evidence for the claimed launch platform.

## CI Gate Classification

The workflow files define configured lanes and triggers. They are configuration evidence only; a result must be observed for the exact candidate revision. The canonical Python pipeline requires pinned Styio language fixtures in every `test` stage; CI and an explicit local `VITYO_PRODUCT_GATE=1` request also require the real Styio/Pafio product matrix.

### Configured CI Workflows

| Workflow / Gate | What It Proves | Evidence Claim |
|-----------------|----------------|----------------|
| `repo-hygiene.yml` | Tracked-tree governance, dependency policy, supply chain, GitHub Actions pin, architecture and product-line boundaries, security baseline, performance budget, license policy, import boundary, ecosystem CLI doc, incoming history range | Repository hygiene and policy compliance is maintained |
| `audit.yml` | Supply chain governance, dependency policy, GitHub Actions pin audit, security baseline, license policy, architecture and product-line boundaries | Security, supply-chain, and architecture policy gates pass |
| `styio-audit.yml` | External styio-audit gate against released policy | Cross-repository audit policy is satisfied |
| `project-coverage-gate.yml` | Discovered Python tooling tests (95% floor), Flutter app tests (85% floor), and separate instrumented Rust Coding Agent and daemon reports | Configured Python/Flutter floors and Rust report/module requirements pass; Rust has no default percentage floor |
| `local-ci-gate.yml` (Linux, Windows, macOS jobs) | The Python delivery stages, deterministic portable suites, required pinned Styio/Pafio product matrix, and host-specific native suites: desktop reconnect on Linux/macOS and the 14-file native UI/credential suite on macOS | The configured platform delivery and package/startup evidence passes for the host; the current app integration root has no Windows-target native integration suite |
| `windows-native.yml` | Windows delivery stages, Flutter analysis/build and its configured coverage/artifact lane | Windows build and package/startup evidence only; this is not Windows app integration evidence |

### Real Product Matrix

The real product matrix uses the exact Styio and Pafio revisions in `toolchain/product-matrix.json`. A local contributor opts in with `VITYO_PRODUCT_GATE=1`; GitHub Actions requires the matrix, and the shared resolver provisions pinned executables as needed. Independently, every `test` stage runs parser-backed Styio fixtures using the same pinned resolver.

| Gate Script | What It Proves | Trigger |
|-------------|----------------|---------|
| `ecosystem-product-gate.py` | Owner-adapter fixture through public `pafio new`, `pafio metadata --json`, `styio --machine-info=json`, and local project composition | Required in CI; `VITYO_PRODUCT_GATE=1` for an explicit local run |
| Platform product matrix and pinned desktop developer-loop evidence | The host-specific real Styio/Pafio matrix and its matching accepted report | Configured Linux, Windows, and macOS workflow jobs |

### What Passing Required Checks Establish

Green required checks for a specific CI revision mean the configured repository and security gates, deterministic health suites, required real product matrix, coverage floors, and host-specific operations passed.

Passing CI does **not** mean platform signing, distribution, installer/update/uninstall, or production release readiness has been verified. It also does not establish a live model-provider conversation or real user acceptance.

## Stage Evidence

The canonical delivery command does not expose skip flags. Stages can be invoked independently to
diagnose and repair a specific failure, but starting at a later stage does not establish that earlier
stages passed. Product closure requires positive evidence for every relevant stage and host lane.
`release-readiness-gate.py --skip-build` remains a separate static metadata check; it is not a
release build or package result.

This checklist defines release evidence; it does not create an active planning checkpoint or grant release authority. Record evidence against the current authorized delivery and the exact candidate revision.

## Required Commands

Run from the repository root unless a command states otherwise:

```bash
python3 scripts/docs-index.py --write
python3 -m pytest tests/test_docs_tooling_coverage.py
python3 scripts/check_architecture_boundaries.py
python3 scripts/check_product_line_boundaries.py
python3 scripts/check_security_baseline.py
python3 scripts/check_performance_budgets.py
python3 scripts/release-readiness-gate.py --skip-build
git diff --check
```

For a full release candidate, also run:

```bash
python3 scripts/vityo.py deliver
python3 scripts/release-readiness-gate.py
python3 scripts/performance-gate.py --threshold 1.10
flutter build linux --release
flutter build windows --release
flutter build macos --release
```

Use `--skip-build` only for metadata, docs, governance-only changes, or non-release checkpoints where a Flutter release build is not part of the evidence being claimed. A formal product release cannot use `--skip-build` as release evidence for any platform being launched.

## Formal Product Launch Gate

Before declaring product launch readiness, the release owner must verify:

1. The launch channel has a production release artifact, not a debug or prototype artifact.
2. Linux, Windows, and macOS launch claims each have native `--release` build evidence when that platform is included in the release.
3. Platform-specific packaging, signing/notarization, installer/update/uninstall, release notes, and rollback or recovery evidence are attached to the release record. The macOS Developer ID and notarization credential contract is defined in [macOS Release Signing](../release/macos-release-signing.md); nightly packages currently record an explicit signing gap because those credentials are not provisioned.
4. Prototype governance and selftest evidence is treated only as regression evidence; it cannot replace release build, packaging, signing, or launch evidence.
5. Any unsupported or upstream-blocked capability is exposed as a user-visible capability gap with owner, reason, recovery guidance, and release-note coverage.

## PR Evidence Checklist

Every PR should state:

1. Which owner surfaces changed: architecture, agent, module, adapter, editor, workspace, governance, docs, or CI.
2. Which compatibility or product-boundary surfaces changed, including schema versions, deprecations, protocol DTOs, and package dependencies.
3. Which security-sensitive files changed, especially sandbox, secret store, log redactor, module manifest security, and agent permission model.
4. Which performance-sensitive paths changed and whether `scripts/performance-gate.py` or `scripts/check_performance_budgets.py` was run.
5. Which docs and indexes were refreshed.

## IDE Architecture Gate

Architecture changes must pass:

```bash
python3 scripts/check_architecture_boundaries.py
```

The gate enforces:

1. `view_ide/` importing or exporting `view_render/`.
2. `view_ide/` importing Flutter presentation APIs.
3. `view_render/` importing unregistered `ide/` or `view_ide/` implementation files.
4. IDE/Agent package dependency direction is enforced separately by `scripts/check_product_line_boundaries.py`.

New presentation dependencies on IDE code require review and a narrow registration in
`VIEW_RENDER_ALLOWED_VIEW_IDE_IMPORTS` in `scripts/check_architecture_boundaries.py`. The registry
contains only the public model, provider, and projection contracts named by the current gate; it
does not authorize imports of private implementation files.

## IDE/Agent Package Boundary Gate

Product package, shared protocol, or dependency-direction changes must pass:

```bash
python3 scripts/check_product_line_boundaries.py
```

The gate requires `products/vityo_app`, `products/vityo_coding_agent`, and
`packages/vityo_agent_protocol` to keep distinct package identities within one Vityo product. It
rejects IDE-to-Agent implementation imports, Agent-to-IDE imports, Flutter dependencies in the
Agent or protocol package, and recreation of removed implementation roots. Architecture review must
also reject new model/provider dependencies in the IDE.

## Sandbox And Security Gate

Security-sensitive changes must pass:

```bash
python3 scripts/check_security_baseline.py
```

The baseline currently requires these files to exist and stay free of known-dangerous patterns:

1. `products/vityo_app/lib/src/view_ide/environment/execution/execution_sandbox.dart`
2. `products/vityo_app/lib/src/view_ide/environment/configuration/log_redactor.dart`
3. `products/vityo_app/lib/src/view_ide/environment/configuration/secret_store.dart`
4. `products/vityo_app/lib/src/view_ide/module_host/module_manifest_security.dart`
5. `products/vityo_app/lib/src/ide/agent_client/agent_client_registry.dart`
6. `products/vityo_app/lib/src/ide/agent_client/mcp/vityod_mcp_gateway.dart`
7. `products/vityo_app/native/vityod/crates/vityod-agent-host/src/acp.rs`
8. `products/vityo_app/lib/src/ide/workspace/workspace_transaction_service.dart`
9. `packages/vityo_agent_protocol/lib/src/protocol.dart`

Security review is required when a change alters permission elevation, subprocess execution, secret storage, log redaction, manifest trust, or network access.

## Performance Gate

Performance-sensitive changes must first pass the static budget coverage check:

```bash
python3 scripts/check_performance_budgets.py
```

When Dart or Flutter is available locally, run the benchmark regression gate:

```bash
python3 scripts/performance-gate.py --threshold 1.10
```

Use a custom baseline when reviewing a focused performance branch:

```bash
python3 scripts/performance-gate.py --baseline docs/review/performance-baseline.json --threshold 1.10
```

Do not save a new baseline with `--save-baseline` unless the PR explicitly explains why the new measurements are the accepted release floor.

## Deprecation And Migration

Breaking changes must not be hidden inside a release checklist. They require:

1. An ADR or governance note explaining the compatibility break.
2. A migration section in [API-COMPATIBILITY.md](./API-COMPATIBILITY.md).
3. A release note entry and affected owner review.
4. Gate updates proving removed paths fail intentionally and the replacement path works.

## Residual Risk Log

If a release candidate ships with known gaps, record them in:

1. [../design/Vityo-Implementation-Gaps.md](../design/Vityo-Implementation-Gaps.md) for active
   product and architecture gaps.
2. [../review/Logic-Conflicts.md](../review/Logic-Conflicts.md) for unresolved conflicts.
3. [../history/](../history/) for recovery notes after an interrupted checkpoint.
