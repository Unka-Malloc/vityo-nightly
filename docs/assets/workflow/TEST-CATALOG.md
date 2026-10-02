# Vityo Test Catalog

**Purpose:** Map current deterministic test ownership and CI reach, and define the future Flow Hero acceptance evidence without treating plans as results.

**Last updated:** 2026-10-02

## Test To CI Contract

Tests are executable parts of a feature change. A passing catalog entry, gate declaration, test plan, or capability flag does not prove behavior. Product tests exercise the real parser, transaction, scheduling, state, persistence, protocol, and recovery implementation; mocks stay at external boundaries.

Ordinary test files placed under an established test root are included by that root's normal discovery. A standalone integration suite or new package root must have a concrete command in the canonical runner and be called from the applicable local health or native CI lane in the same change. Keep one executable registry as the suite map; update this catalog to describe owners and evidence, not copy the registry's command list.

The current contributor entrypoints are [Checkpoint Health](./CHECKPOINT-HEALTH.md) and [Delivery Gate](./DELIVERY-GATE.md). They are also used by the configured repository CI jobs. The exact CI status and platform observations are separate from this source map.

## Current Deterministic Test Owners

| Owner and test root | Current CI connection | Evidence boundary |
|---|---|---|
| Vityo IDE unit, widget, contract, model, and performance-budget tests: `products/vityo_app/test/**/*_test.dart` | Flutter test discovery with coverage from `scripts/checkpoint-health.sh` through `scripts/project-coverage-gate.py` | Portable tests against the Flutter implementation; does not establish provider or real-user behavior. Current Flow Hero model/layout tests cover their fixtures only. |
| Repository and development-tool tests: `tests/test_*.py` | Python `unittest` discovery and coverage from `scripts/checkpoint-health.sh` through `scripts/python-coverage-gate.py` | Newly named tests under `tests/` are discovered. Prototype's server-security module remains an explicit additional test target. |
| Coding Agent runtime: `products/vityo_coding_agent/test/` and its protocol integration fixtures | `scripts/vityo_quality.py --product coding-agent --suite full`, invoked by Checkpoint Health with a validation receipt under `build/evidence/` | The full registry executes nine deterministic runtime/protocol suites with local fixtures; it does not call a real model provider or prove a user-assigned Agent task. |
| Portable IDE integration: workspace transactions, developer loop, Agent client protocol, MCP host, IDE security, Agent Workbench, quality runtime, and recovery isolation | Eight `ide/<suite>` entries in `scripts/vityo_quality.py`, invoked individually by Checkpoint Health | Exercises the selected local IDE and protocol integration seams with deterministic fixtures. It does not prove an external Agent conversation. |
| Native desktop reconnection: `products/vityo_app/integration_test/vityod_reconnect_test.dart` | `scripts/vityo_quality.py --product ide --suite native-desktop` in the Linux and macOS jobs | Runs the supported real desktop reconnect integration. This host suite is not run on Windows. |
| macOS native UI and credential tests: all 11 `integration_test/*_native_ui_test.dart` files plus `editor_native_input_test.dart`, `platform_secure_credential_storage_test.dart`, and `workbench_visual_capture_test.dart` (14 tests) | `scripts/vityo_quality.py --product ide --suite macos-native-ui` in the macOS job | Discovers the 11-file native UI glob and explicitly registers the three remaining macOS-specific integration tests. |
| Windows platform integration | No Windows-target native app integration test exists in the current app integration root. Standard Flutter unit/widget coverage and Windows build evidence remain separate. | Treat this as absent coverage, not a passing native integration suite. Do not run the Linux/macOS reconnect test on Windows. |
| Retained hand-written prototype governance and editor smoke tests: `prototype/` | `npm run governance` and `npm run selftest:editor`, called from Checkpoint Health | Regression evidence for the permanent independent source asset; does not replace Flutter behavior or release evidence. |
| Styio parser-backed language fixtures | `scripts/language-fixture-gate.sh`, called from Checkpoint Health | Tests only the declared fixture roots and executable contract. It is not evidence that every source language feature or upstream matrix is connected. |

The quality-runner test compares every file under the app's standalone integration root with its explicit file literals and registered glob patterns. An added file fails that check until it is mapped to a runnable suite; moving a test requires preserving equivalent CI coverage. Deleting or renaming a test cannot turn its requirement into a pass.

## Flow Hero Future Acceptance

These are target requirements for the later production wiring milestone. The current Flow Hero preview/model and styled upstream component spike do not satisfy them. Add each applicable test with the implementation that first provides its behavior.

| Scenario | Deterministic acceptance evidence |
|---|---|
| Styio-backed graph and edge direction | Parse valid current Styio syntax and derive a directed source-to-target graph from language-service facts. Reject fabricated keywords and metadata-only project graph facts as program semantics. |
| Source-to-graph updates | Edit the actual source document, re-analyze its revision, and assert that node/edge content follows only the latest accepted revision. Cover invalid syntax, asynchronous stale results, and Unicode source ranges. |
| Graph-to-source edits | Move a node without changing program semantics; apply a supported rewire through a source transaction; verify cancel, rejected validation, undo, and invalid rewrites preserve the original source and graph. |
| Agent proposal and application | Drive the shared Agent protocol fixture through proposal, permission, transaction result, applied revision, ordered observations, verification, and recovery. Assert pending or rejected changes never appear as applied graph state. |
| Visual parity and motion | Compare representative light and dark graph frames against the tagged current visual baseline. Add deterministic drag, rewire, and Agent-change animation checks without making layout jitter or animation timing a semantic result. |
| Performance and revision churn | Exercise realistic node/edge counts and rapid source/Agent updates through the real projection path; assert stale work is discarded and measure the agreed rendering budget. |

Unit, contract, widget, and deterministic integration evidence belongs in auto-discovered roots or a registered suite used by Checkpoint Health/native CI. Real provider conversations, installed-client inspection, or live UI acceptance remain a separate workflow for the user's designated Agent and an explicit task.
