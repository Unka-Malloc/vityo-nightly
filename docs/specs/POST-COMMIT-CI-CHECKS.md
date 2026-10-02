# Verification And CI

**Purpose:** Define the canonical local verification flow, test-suite-to-CI requirements, and evidence boundaries for GitHub Actions and later acceptance.

**Last updated:** 2026-10-02

## Test Connection Is Part Of The Change

Every new or changed behavior carries deterministic tests and a working CI route in the same change. Tests under established roots are discovered by their ordinary runner. A standalone suite or package outside those roots is added to the canonical runner and the applicable portable or native CI lane; do not keep a test that CI cannot run and report it as covered. The [test catalog](../assets/workflow/TEST-CATALOG.md) maps owners and future Flow Hero acceptance. The runner implementation remains the executable suite registry.

Tests exercise the implementation at the layer that owns the behavior. Unit and contract tests cover syntax, state transitions, workspace transactions, policy, protocol ordering, persistence, and recovery. Deterministic integration tests use real internal modules with fixtures at external boundaries. No passing declaration substitutes for command output.

## Canonical Local Entrypoints

Run focused commands while implementing. After all source review, in-scope repairs, and focused checks are complete, run the applicable integrated local health regression:

```bash
./scripts/checkpoint-health.sh
```

The repository delivery wrapper adds staged-tree hygiene, documentation validation, the configured audit/fallback, delivery policy, and checkpoint health:

```bash
./scripts/delivery-gate.sh --mode checkpoint
```

For a docs/process-only change where product tests and health checks are out of scope, the delivery wrapper supports:

```bash
./scripts/delivery-gate.sh --mode checkpoint --skip-health
```

That skip does not establish Flutter, Agent, IDE integration, coverage, fixture, or prototype test success. Record those checks separately if the change claims their behavior.

### Checkpoint Health Scope

The health entrypoint calls the following owners using their existing test roots and runner:

| Suite | Runner and owner | What a pass establishes |
|---|---|---|
| Flutter IDE tests and line coverage | `flutter analyze`; `flutter test --coverage` under `products/vityo_app/` via `scripts/project-coverage-gate.py` | The discovered app unit/widget/contract tests passed and the configured Flutter line-coverage floor was met. |
| Python repository tests and line coverage | `unittest discover` under `tests/` plus the explicit Prototype security test via `scripts/python-coverage-gate.py` | Discovered repository-tool tests and the retained Prototype security test passed; the configured tooling coverage floor was met. |
| Coding Agent runtime | `scripts/vityo_quality.py --product coding-agent --suite full --receipt build/evidence/vityo-coding-agent-full.json` | The nine registered deterministic Agent runtime and protocol fixture suites passed. It does not call an external model provider. |
| Daemon core and daemon protocol | `scripts/vityo_quality.py --product ide --suite daemon-core` | Locked Rust workspace tests and daemon-protocol analysis/tests passed; no desktop UI is launched. |
| Portable IDE integration | Registered `ide/workspace-transactions`, `ide/developer-loop`, `ide/agent-client-protocol`, `ide/mcp-host`, `ide/ide-security`, `ide/agent-workbench`, `ide/quality-runtime`, and `ide/recovery-isolation` suites | These local IDE integration contracts passed with the runner's configured fixtures. They do not prove a real Agent conversation. |
| Native desktop reconnect | `scripts/vityo_quality.py --product ide --suite native-desktop` in the configured Linux and macOS jobs | Runs the supported `vityod_reconnect_test.dart` host integration on those platforms. It is not run on Windows. |
| macOS native UI and credential integration | `scripts/vityo_quality.py --product ide --suite macos-native-ui` in the macOS job | Discovers 11 `*_native_ui_test.dart` files and explicitly includes `editor_native_input_test.dart`, `platform_secure_credential_storage_test.dart`, and `workbench_visual_capture_test.dart` (14 tests total). |
| Release-readiness static checks | `scripts/release-readiness-gate.py --skip-build` | The static release metadata and evidence rules passed; no release build or package result is established. |
| Styio parser-backed fixtures | `scripts/language-fixture-gate.sh` | The declared language fixture gate passed for its configured roots and available contract. It does not prove all upstream or product-matrix behavior. |
| Permanent Prototype checks | `npm run governance` and `npm run selftest:editor` under `prototype/` | The preserved Prototype governance and editor smoke checks passed; they do not replace Vityo Flutter or release tests. |

The app's standalone integration-test root is inventoried against executable file literals and glob selectors by the quality-runner tests. The Linux and macOS jobs run the supported desktop reconnect test; the macOS job additionally runs the 14 native UI and credential tests. No Windows-target native app integration test exists in the current root, so Windows has no native app integration coverage; its portable suites and platform delivery/build checks are separate evidence. Portable IDE suites do not imply that every file in the integration root ran. Test-runner failures, missing files, unresolved commands, unregistered integration files, or nonzero suite results must fail their owning gate.

The standalone `project-coverage-gate` workflow runs the Python and Flutter project coverage gate directly. Coverage percentages show only the configured source scope; they do not prove behavior outside executed tests.

## Final Regression And Repair

Run the applicable full local regression after all writing, source review, in-scope repairs, and focused verification. Reuse earlier passing evidence only when all inputs to that check remain unchanged.

If final regression finds an ordinary defect within the approved scope, diagnose it, fix it, run focused verification, and repeat the final checks needed for the repaired revision. A failed complete regression does not by itself require a user decision. Ask for a decision only when correction would change scope, a genuinely published contract, a risk boundary, or required authority; pause only work depending on that decision.

Do not weaken coverage, security, architecture, product-boundary, or platform gates to get a pass. Do not call a configured-but-unobserved lane a pass. Keep any local workaround out of the supported implementation unless the product requirements select it.

## Authorized GitHub Actions Observation

Pushing, opening a pull request, merging, and changing remote Rulesets require the relevant explicit authorization. This section applies only when a push is authorized and has been performed.

For the exact pushed commit:

1. Identify the branch and candidate commit.
2. Inspect the configured GitHub Actions runs and required checks for that commit.
3. Observe each applicable run until it finishes or report its status as unresolved, with a recovery path.
4. If a check fails, diagnose the stage and repair ordinary in-scope defects. Re-run focused and applicable final checks for the new revision. An out-of-scope requirement or authority change goes to the user with the evidence and choices needed.
5. If a required run cannot be observed, report the exact commit, status, and next observation command. An expired observation window is not cancellation or success.

Preferred commands after an authorized push:

```bash
gh run list --branch "$(git branch --show-current)" --limit 10
gh run view <run-id> --json headSha,status,conclusion,url
gh run view <run-id> --log-failed
```

If GitHub is unavailable or unauthenticated, state that remote Actions could not be checked and list the local gates actually run. A local-only delivery is assessed against its local acceptance conditions and does not require an unsolicited push.

For a delivery authorized across multiple repositories, check every pushed repository's corresponding run. A dependency or CI gate does not grant permission to publish that dependency.

## Platform Evidence And Live Acceptance

Repository CI performs only the configured deterministic and host-specific engineering checks. A platform build or packaging test proves only that operation on that runner. Installation or client launch does not authorize Computer Use, live interface inspection, or real user-scenario testing.

Real provider conversations and real development tasks belong to the user's designated Agent on an explicit task. Do not start or delegate that workflow to close implementation. Before handoff, report the deterministic suites that passed, the configured host lanes actually observed, and the external behavior still reserved for live acceptance.

## Release Ruleset Evidence

GitHub merge-gate configuration is external governance. This repository's workflow files and documentation do not prove the currently effective Rulesets. When an authorized task changes required-check governance, inspect the effective Ruleset state and document the exact observed status. Do not use the classic branch-protection endpoint as the authority for a repository whose required checks are configured through Rulesets.
