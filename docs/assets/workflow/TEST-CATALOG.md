# Vityo Test Catalog

**Purpose:** Map current deterministic test ownership and CI reach, and define the future Flow Hero acceptance evidence without treating plans as results.

**Last updated:** 2026-10-08

## Test To CI Contract

Tests are executable parts of a feature change. A passing catalog entry, gate declaration, test plan, or capability flag does not prove behavior. Product tests exercise the real parser, transaction, scheduling, state, persistence, protocol, and recovery implementation; mocks stay at external boundaries.

Ordinary test files placed under an established test root are included by that root's normal discovery. A standalone integration suite or new package root must have a concrete command in the canonical runner and be called from the applicable local health or native CI lane in the same change. Keep one executable registry as the suite map; update this catalog to describe owners and evidence, not copy the registry's command list.

The canonical contributor entrypoint is `python3 scripts/vityo.py deliver`; test collection and coverage evaluation are documented in [Test and Coverage](./CHECKPOINT-HEALTH.md), and the full stage graph in [Delivery Pipeline](./DELIVERY-GATE.md). CI uses the same stage implementation. The exact CI result and platform observations are separate from this source map.

## Current Deterministic Test Owners

| Owner and test root | Current CI connection | Evidence boundary |
|---|---|---|
| Vityo IDE unit, widget, contract, model, and performance-budget tests: `products/vityo_app/test/**/*_test.dart` | Flutter test discovery with coverage collection in `python3 scripts/vityo.py test`; evaluation is `python3 scripts/vityo.py coverage` | Portable tests against the Flutter implementation; does not establish provider or real-user behavior. Current Flow Hero model/layout tests cover their fixtures only. |
| Repository and development-tool tests: `tests/test_*.py` | Python test discovery and coverage collection in `python3 scripts/vityo.py test`; evaluation is `python3 scripts/vityo.py coverage` | Newly named tests under `tests/` are discovered. Prototype's server-security and editor self-test lifecycle modules are discovered under `prototype/test_*.py`; the lifecycle module invokes deterministic Node browser-boundary tests. |
| Coding Agent runtime: Rust implementation under `products/vityo_coding_agent/src/` | The `test` stage runs the `coding-agent/full` requirement suite with one instrumented locked Cargo workspace collection; `coverage` evaluates the separate Agent report | The suite maps all nine Agent requirements to executed runtime modules and reports current-platform source coverage without a default Rust percentage floor. Provider/tool/protocol fixtures are deterministic; no suite calls a real provider or proves a user-assigned task. |
| Local daemon client lifetime: `test/local_service/vityod_client_test.dart` and `vityod_client_lifecycle_test.dart` under `products/vityo_app/` | Existing Flutter unit-test discovery in the `test` stage | Covers the real Dart client's shared send/response deadline, pending-send disconnect, retired replies, reconnect, and full-resync lifetime with a controlled transport. Does not prove Windows native pipe cancellation or full startup. |
| Local daemon core: `products/vityo_app/native/vityod/` and `packages/vityo_daemon_protocol/` | Locked Cargo workspace tests plus `ide/daemon-core`, invoked by the `test` stage | Runs Rust daemon workspace tests and daemon-protocol analysis/tests. It does not launch the desktop UI. |
| Portable IDE integration: workspace transactions, developer loop, Agent client protocol, MCP host, IDE security, Agent Workbench, quality runtime, and recovery isolation | Nine `ide/<suite>` selectors in the registered quality runner, invoked by the `test` stage | Exercises selected local IDE and protocol integration seams with deterministic fixtures. It does not prove an external Agent conversation. |
| Flow Hero Agent-neutral operations and review: `flow_hero_workspace_operations_test.dart`, `flow_hero_agent_review_test.dart`, plus workspace replace/search and vityod file-system integration tests | Flutter test discovery in the `test` stage; focused command: `cd products/vityo_app && flutter test test/flow_hero_workspace_operations_test.dart test/flow_hero_agent_review_test.dart test/workspace_replace_controller_test.dart test/workspace_search_service_test.dart test/local_service/vityod_file_system_integration_test.dart` | Exercises the selected client operation port, exact supplied permission choices, source reads/writes, correlated proposal review, and real daemon transaction outcomes. It does not establish Styio-derived graph semantics or graph rewiring. |
| Native desktop reconnection: `products/vityo_app/integration_test/vityod_reconnect_test.dart` | `ide/native-desktop` through the `test` stage on Linux and macOS CI | Runs the supported desktop reconnect integration. This host suite is not run on Windows. |
| macOS native UI and credential tests: all 11 `integration_test/*_native_ui_test.dart` files plus `editor_native_input_test.dart`, `platform_secure_credential_storage_test.dart`, and `workbench_visual_capture_test.dart` (14 files) | `ide/macos-native-ui` through the `test` stage on macOS CI | Discovers the 11-file native UI glob and explicitly registers the three remaining macOS-specific integration tests. |
| Windows pipe diagnostic supervisor: `tests/test_windows_pipe_diagnostics.py` | Python test discovery; raw Win32 collection runs early in the existing Windows delivery job | Portable tests verify bounded process supervision and report semantics only. The native report distinguishes API completion, cancellation and watchdog outcomes; it is not product acceptance evidence. |
| Windows atomic pipe boundary: `products/vityo_app/native/windows_pipe/`, `tests/test_windows_pipe_native_boundary.py`, `tests/test_windows_pipe_library.py`, and `test/local_service/windows_pipe_{library,startup}_test.dart` under the app | Existing Python/Flutter discovery; standalone MSVC build precedes the Windows pipe watchdog and supplies the same DLL source to native test runners | Portable tests compile the actual wrapper against fake Win32 APIs and check loader paths/build wiring. The owner is the local-service transport; Docs / Delivery owns build/install wiring. The existing Windows startup probe requires real bundled loader/ABI success before emitting `windows_pipe_abi: 1`; negative portable tests reject missing or mismatched prerequisites. Native execution still must prove real Windows exports, kernel I/O, cancellation, and installed loading. |
| Windows production pipe transport: `tool/windows_named_pipe_regression.dart` under `products/vityo_app/`, supervised by `scripts/test-windows-dart-pipe.py` | Bounded real-Dart worker in the existing Windows delivery job after dependency restore and app-owned DLL build | Uses the candidate's actual transport with a synthetic Win32 server. Native results are required separately from portable supervisor and control-frame fixture tests (`test/local_service/windows_pipe_fixture_test.dart`) and raw ctypes probes. The framed socket fixture obeys the existing 1 MiB control-payload limit while raw pipe fixtures use 8 MiB; no full-product pass is implied. |
| Windows platform integration | No Windows-target native app integration test exists in the current app integration root. Standard Flutter unit/widget coverage and Windows build evidence remain separate. | Treat this as absent coverage, not a passing native integration suite. Do not run the Linux/macOS reconnect test on Windows. |
| Retained hand-written Prototype governance and editor smoke tests: `prototype/` | `npm run governance` and `npm run selftest:editor`, called from the `test` stage | Regression evidence for the permanent independent source asset; does not replace Flutter behavior or release evidence. |
| Styio parser-backed language fixtures | `dart run tool/language_fixture_gate.dart` through the `test` stage, using the exact product-matrix revision | The stage reuses a matching executable or prepares the pinned checkout; an invalid explicit override or failed preparation fails `test`. Passing fixtures establish only the declared fixture roots and executable contract, not every language feature or the real product matrix. |

The quality-runner test compares every file under the app's standalone integration root with its explicit file literals and registered glob patterns. An added file fails that check until it is mapped to a runnable suite; moving a test requires preserving equivalent CI coverage. Deleting or renaming a test cannot turn its requirement into a pass.

## Local Toolchain Slice

The auto-discovered Flutter tests `flow_hero_execution_test.dart`,
`flow_hero_local_services_test.dart`, `flow_hero_toolchain_install_test.dart`,
`pafio_cli_discovery_test.dart`, and `styio_toolchain_discovery_lspd_test.dart`
cover explicit-path failure without fallback, both selection controls, the real
Pafio doctor-check parser, advisory product lanes, and executed-receipt validation.
Failure, missing/malformed evidence, wrong intent, and old successful receipts must
not produce a new success result. The separate `flow_hero_compile_acceptance_test.dart`
covers isolated bootstrap and disabled Agent access using the production services.
These tests establish deterministic contracts, not installed macOS UI acceptance.

## Flow Hero Future Acceptance

These remaining requirements concern source-authoritative graph behavior. The current Flow Hero preview/model and connected Agent operation/review path do not establish Styio graph semantics. Add each applicable test with the implementation that first provides its behavior.

| Scenario | Deterministic acceptance evidence |
|---|---|
| Styio-backed graph and edge direction | Parse valid current Styio syntax and derive a directed source-to-target graph from language-service facts. Reject fabricated keywords and metadata-only project graph facts as program semantics. |
| Source-to-graph updates | Edit the actual source document, re-analyze its revision, and assert that node/edge content follows only the latest accepted revision. Cover invalid syntax, asynchronous stale results, and Unicode source ranges. |
| Graph-to-source edits | Move a node without changing program semantics; apply a supported rewire through a source transaction; verify cancel, rejected validation, undo, and invalid rewrites preserve the original source and graph. |
| Applied source revision reaches the graph | After an accepted Agent proposal returns a committed revision, analyze that exact source revision and assert the semantic graph follows it. Rejected, conflicted, or unavailable proposals must leave the prior graph state intact. |
| Visual parity and motion | Compare representative light and dark graph frames against the tagged current visual baseline. Add deterministic drag, rewire, and Agent-change animation checks without making layout jitter or animation timing a semantic result. |
| Performance and revision churn | Exercise realistic node/edge counts and rapid source/Agent updates through the real projection path; assert stale work is discarded and measure the agreed rendering budget. |

Unit, contract, widget, and deterministic integration evidence belongs in auto-discovered roots or a registered suite used by Checkpoint Health/native CI. Real provider conversations, installed-client inspection, or live UI acceptance remain a separate workflow for the user's designated Agent and an explicit task.

## Windows Pafio Launch Diagnostic

`tests/test_windows_pafio_launch_diagnostic.py` validates the opt-in supervisor's
Win32 bindings with mocks, assignment-before-release ordering, owned-tree cleanup,
deadlines, explicit observations, partial evidence persistence and redaction.
`products/vityo_app/tool/windows_pafio_launch_diagnostic.dart` exercises the real
process manager and daemon through `scripts/diagnose-windows-pafio-launch.py` on
Windows only. Its six cells compare direct/native, direct/batch and daemon routes
with bare versus absolute Python. Collection success is not launch success and
never replaces native delivery, adapter tests or the 95% coverage floor.

## Pafio Discovery Environment Boundary

`products/vityo_app/test/pafio_discovery_environment_test.dart` covers the shared
non-secret allowlist, new Windows launch keys, case-insensitive deduplication,
conflict/value rejection, and authoritative Pafio selection with safe child PATH.
Its real-daemon group probes the installed native Dart executable with `--version`
and verifies that an explicitly credential-shaped environment still cannot start.
No fake batch launcher is involved in that integration regression.

The vityod binary's Rust tests cover nested sensitive key/value rejection, empty
credential-key values, array/depth handling, safe Windows launch keys and rejection
before task registration. These preserve the production guard. Portable mocks and
scripted protocol tests do not establish native Windows launch or wrapper behavior.
