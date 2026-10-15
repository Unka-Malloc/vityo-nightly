# Current-source support and build baseline

**Purpose:** Bound preservation for TASK-001 by current owner contracts and executable test mappings, and hand observed preparation/build evidence to REPAIR.

**Last updated:** 2026-10-11

## Scope and authority

This is NODE-BASELINE in the same hosted E03 / source
`TREE-VITYO-TASK-RESOURCE` / `TASK-001`. It maps to
REQ-VITYO-BASELINE, REQ-VITYO-PRESERVE and REQ-VITYO-INTEGRITY.
The [Programme](../Programme.json), [Requirements](../Requirements.json),
[Tree](Tree.json), [task](tasks/TASK-001.json) and existing Node files retain
their authority. This inventory does not admit FINAL/CLOSE or future outlines.

Owner references, in precedence order for this inventory:

- [Product specification](../../design/Vityo-Product-Spec.md),
  [system architecture](../../design/Vityo-System-Architecture.md), and
  [current gap register](../../design/Vityo-Implementation-Gaps.md).
- [User-facing workflows](../../contracts/UserFacingWorkflows.md),
  [language](../../contracts/LanguageServiceAdapter.md),
  [execution](../../contracts/ExecutionAdapter.md),
  [runtime events](../../contracts/RuntimeEventAdapter.md), and
  [observable topology](../../contracts/ObservableTopologyAdapter.md).
- [Test catalog](../../assets/workflow/TEST-CATALOG.md),
  [build environment](../../BUILD-AND-DEV-ENV.md),
  [coordination ownership](../../teams/COORDINATION-RUNBOOK.md), root
  `CODEOWNERS`, and [documentation policy](../../specs/DOCUMENTATION-POLICY.md).
- Accepted sibling `docs/plans/task-resource-delivery/HANDOFF.md` files:
  Styio `d0177d43181b49023dbbe65455c9e369` and Pafio
  `798ff72acf150dcfa0891999c7a18e53`. These are coordinator handoff references,
  not source revisions or executable identities. Both handoffs record accepted
  host checks with unavailable full host console; their detailed local evidence
  has its own stated scope. No upstream suite was repeated here.

The older `docs/design/IMPLEMENTATION-GAPS.md`, prior test totals, capability
labels in `toolchain/vityo-ide-capability-baseline.json`, and launch promises
are not current-candidate passes. The active gap register includes newer LSP,
daemon and Flow Hero facts than some architecture prose. Current requirements
restrict this milestone to text authoring and read-only diagrams; future graph
rewiring language in owner documents does not authorize implementation here.

## Preservation inventory and existing test map

All test paths below are relative to `products/vityo_app/test/` unless otherwise
qualified. They are mapped source assets, **not tests executed by BASELINE**.
The catalog owns their canonical runner/CI routes. Preserve each implemented
subset and its existing cases; a model, test name, or capability flag does not
prove production wiring or platform acceptance.

| Capability and owner | Existing surface to preserve | Current test anchors | Explicit evidence limit or gap |
| --- | --- | --- | --- |
| Shell/workbench; editor/workbench owners | Commands, palette, quick-open, surface routing, keyboard/capability gating | `command_palette_test.dart`, `command_palette_surface_test.dart`, `flow_hero_quick_open_test.dart`, `app_bootstrap_test.dart` | Reusable shell composition is distinct from the normal `main.dart` Flow Hero entry; prove the selected production composition in REPAIR. |
| Source editor; editor owner | Canonical text, selections, undo/redo, encoding, display-only substitutions, input and tabs | `editor_document_encoding_test.dart`, `editor_session_data_store_test.dart`, `editor_rendered_input_profile_widget_test.dart`, `acceptance/rendered_editor_input_acceptance_test.dart` | Native input/live UI is not exercised in this slice; broader automatic session recovery remains incomplete. |
| Documents/save/transactions; workspace owner | Revisioned buffers, file binding, save, conflict/deleted/readonly states, watch/reconnect, atomic apply/rollback | `workspace_document_controller_test.dart`, `workspace_document_store_io_test.dart`, `shell_runtime_file_binding_test.dart`, `editor_file_binding_reconnect_test.dart`, `workspace/workspace_transaction_service_test.dart`, `local_service/vityod_file_system_integration_test.dart` | Existing production daemon route must replace the product test's manual filesystem save. Memory implementations are not defects merely for being in memory. |
| Workspace/navigation; workspace + adapter owners | Explorer/search, symbols, definitions/references and supported revision-bound edits | `workspace_definition_test.dart`, `workspace_reference_search_test.dart`, `workspace_rename_test.dart`, `workspace_edit_applier_test.dart`, `workspace_search_service_test.dart`, `workspace_file_explorer_desktop_matrix_test.dart` | Cross-file and position-scoped upstream fact integration is partial; no complete rename/refactor promise. |
| Language/diagnostics; adapter owner | Routed/cached document analysis, capability gaps, revision rejection, LSP diagnostics/tokens/symbols/inlay data | `language_result_cache_context_binding_test.dart`, `lsp_styio_service_connector_test.dart`, `lsp_styio_service_connector_lifecycle_test.dart`, `local_service/vityod_lsp_gateway_test.dart`, `acceptance/styio_lspd_acceptance_test.dart` | Existing acceptance can skip absent LSP and discover installed alternatives. Mandatory same-candidate document open/change/save/diagnostics must fail on missing input. Formatting is unavailable; position-scoped routing and inlay presentation remain partial. |
| Components/project facts; foundation + adapter owners | Explicit compiler/Pafio selection, machine contract, package/target metadata, blocked missing/incompatible routes | `app_bootstrap_toolchain_test.dart`, `styio_toolchain_discovery_lspd_test.dart`, `pafio_cli_discovery_test.dart`, `flow_hero_toolchain_store_test.dart`, `flow_hero_toolchain_install_test.dart` | Selected dirty candidates override old product-matrix revisions. No install/download or component replacement in this slice. |
| Check/build/test/run; adapter + runtime owners | Typed workflow/session results, current diagnostics/receipts, target selection, process identity and explicit cancellation | `execution_adapter_test.dart`, `backend_route_product_gate_test.dart`, `flow_hero_execution_test.dart`, `local_product_workflow_test.dart` | Current real test omits build and vityod, lacks real document/LSP transitions, and requires a success-only report. Existing missing/incompatible/failure/containment cases remain required. |
| Testing/debug/history; runtime owner | Testing projections and stored task history, runtime task lifecycle, declared debug subset | `testing_controller_test.dart`, `testing_surface_test.dart`, `testing_runtime_task_history_test.dart`, `debug_runtime_task_history_test.dart`, `runtime_task_history_store_test.dart`, `runtime_task_lifecycle_test.dart` | IDE history is distinct from Styio resource creation-time history. Breakpoints/run configurations do not imply a published debugger backend. |
| Static read-only observation; adapter + runtime owners | Snapshot publication, cache, lineage window, retained-parent delta, explicit fresh/stale/missing states and source navigation | `observable_snapshot_publisher_io_test.dart`, `observable_snapshot_decoder_test.dart`, `observable_delta_apply_test.dart`, `observable_graph_controller_test.dart`, `observable_graph_surface_test.dart` | Fixture tests do not establish same-candidate producer consumption. Use returned invocation paths and exact retained parent; no source generation or drag editing. |
| Runtime observation; runtime owner | Ordered event intake, snapshot/execution correlation, explicit unavailable/disabled states | `runtime_event_contract_test.dart`, `typed_runtime_event_stream_test.dart`, `observable_runtime_decoder_test.dart`, `observable_runtime_correlation_test.dart`, `observable_runtime_intake_io_test.dart` | Require real runtime-only and observed good/error/repaired runs. Observe-off must retain edit/save/execute after observed runs. |
| Flow Hero; editor/workspace owners | Real active-buffer projection, source badges/dock, quick-open, execution, path-bound operations and proposal review | `flow_hero_source_authority_test.dart`, `flow_hero_execution_test.dart`, `flow_hero_workspace_operations_test.dart`, `flow_hero_agent_review_test.dart`, `flow_hero_route_lifecycle_test.dart` | Source projection does not establish complete Styio semantic flow. Full-editor/source-dock convergence and semantic rewiring are future work, not this milestone. |
| Desktop services; foundation/workspace owners | vityod filesystem, durable revisions/transactions, process/shell/PTY/resource gateways, recovery and isolation | `platform_manager_bundle_contract_test.dart`, `local_service/vityod_client_test.dart`, `local_service/vityod_idempotency_integration_test.dart`; Rust workspace `products/vityo_app/native/vityod/` | Existing `test/support/vityod_test_harness.dart` and transports are reusable. No second harness/daemon authority is needed. Native reconnect suite is Linux/macOS only. |
| Source control; workspace owner | Current source-control projections/actions and daemon git route | `source_control_adapter_test.dart`, `source_control_hunk_action_test.dart`, `source_control_merge_editor_test.dart`, `local_service/vityod_git_integration_test.dart` | Some older capability labels describe models only; retain actual current test roots without inferring live repository-operation approval. |
| Agent client/companion; Agent owner | Protocol negotiation, permission/review/transactions, process isolation; independent no-Agent IDE | `agent_client/agent_client_contract_test.dart`, `agent_client/vityod_agent_process_test.dart`, `flow_hero_agent_review_test.dart`; `packages/vityo_agent_protocol/`; `products/vityo_coding_agent/src/` | Deterministic protocol coverage does not prove provider conversation. Nonempty production MCP attachment remains unavailable. No Agent task is launched here. |
| Settings/themes/security/persistence; foundation/theme/governance owners | Configuration and credential stores, redacted projections, local themes, keymaps, scoped datastore, sandbox boundaries | `foundation_test.dart`, `credential_data_store_test.dart`, `settings_profile_theme_personalization_test.dart`, `flow_hero_theme_store_test.dart`, `execution_sandbox_test.dart` | Broader owner adoption, theme authoring/profile sync and some secret-injection routes remain partial. No current performance/billing claim. |
| Modules/hosted/mobile; module/platform owners | Manifest trust, lifecycle/registry models, capability gating, hosted document/execution contracts | `module_manifest_security_test.dart`, `module_lifecycle_test.dart`, `module_registry_manifest_test.dart`, `hosted_workspace_document_store_test.dart`, `hosted_runtime_execution_adapter_test.dart`, `desktop_platform_matrix_test.dart` | Real module distribution/staging and provider/device parity are not established by these models. Preserve explicit unsupported/blocked routes. |
| Accessibility/layout/performance; editor/theme owners | Viewport adaptation, source-position fidelity, quality/performance budgets | `viewport_profile_test.dart`, `flow_hero_layout_test.dart`, `editor_input_visual_evidence_test.dart`; `scripts/check_performance_budgets.py` | Static budgets and saved visuals are not fresh measurements or live accessibility acceptance. |
| Permanent Prototype; editor owner + root AGENTS.md | Complete `prototype/` source, entrypoints, dependency governance and tests | `prototype/`: `npm run governance`, `npm run selftest:editor`; explicit server-security test in canonical runner | Independent retained asset, never migration debris. No changes or execution here. |

## Platform boundary

| Platform | Declared route / current assets | Mapped engineering evidence | This slice |
| --- | --- | --- | --- |
| macOS | Launch desktop, local-first Flutter + vityod; existing Xcode runner | Registered baseline: locked Cargo debug daemon, `flutter pub get`, `flutter build macos --debug`; portable tests and catalog's native suites | Build is delegated to HOST `vityo-task-resource-baseline`. HOST evidence subsequently consumed by REPAIR: all seven commands exited 0; no skips. No install, launch, native UI or live acceptance. |
| Linux | Launch desktop, local-first; Linux runner and owner bootstrap/packaging | Portable tests; `integration_test/vityod_reconnect_test.dart`; native PTY/desktop matrix gates | No Linux host execution in this lane; unavailable platform evidence is not a skip or pass. |
| Windows | Launch desktop, local-first; Windows runner and owner packaging | Portable tests, Windows build and daemon/PTY matrix owners | No Windows host execution. Test catalog explicitly has no Windows-target native app integration suite. |
| Android | Post-launch mobile, local-first only where available, declared hosted route otherwise | Platform/backend/viewport tests; owner Android device tools | No device/emulator evidence; no parity claim. |
| iOS | Last mobile release, hosted-only execution | Hosted route/capability tests; owner Apple simulator/device tools | No simulator/device evidence; no unrestricted local JIT/compiler claim. |
| Web | Post-launch hosted workspace/execution client | Hosted document/execution and Web provider tests | No browser/provider execution; no local daemon/compiler parity claim. |

Build tool availability and actual host architecture are recorded privately by
the preparation command. Other platforms are not invoked as deliberately
skipped baseline steps: they require their own assigned owner evidence.

## Selected inputs and prepared command

Consume, without sibling writes/builds:

- `../styio-nightly/build/default/bin/styio`
- `../styio-nightly/build/default/bin/styio_lspd`
- `../pafio-nightly/build-codex/bin/pafio`

The sole registered baseline command remains
`bash docs/plans/task-resource-delivery/checks.sh baseline`.
Its helper [baseline.py](baseline.py) retains logs before executing the existing
daemon/app build steps. `CARGO_TARGET_DIR` is explicitly the daemon's existing
`native/vityod/target` so Cargo and Xcode's existing staging phase share outputs.
The Xcode stage's incremental Cargo invocation remains owner build behavior;
no separate pre-pass build is performed. Build failures and missing executables
return nonzero; unexecuted later commands are recorded as such, never as skips.
No process time, silence, retry or output-volume cutoff is added.

Private evidence resides only in ignored `build/task-resource-baseline/`:

- `latest-preparation.json` points to the input-only record. Its helper exit
  reports input capture/preparation, **not a build pass**.
- `latest-host.json` is written only when the registered build helper executes.
  Consume its referenced `evidence.json`, per-step stdout/stderr logs, exact argv,
  launch outcome and actual exit code. A prior record is not the current host run.
- Per-repository revision and dirty status distinguish the candidate from base
  commits. Selected binary paths, size and modification time record the observed
  files. Accepted sibling handoffs own upstream provenance; no hashes or source
  archives are captured. Historical ignored evidence remains intact.
- Expected outputs are `products/vityo_app/native/vityod/target/debug/vityod`
  and the debug `Vityo.app` executable/helper under the app's ignored build tree.
  Output identities are recorded only after successful build commands.

The BASELINE Worker only runs `baseline.py --prepare-only` for input capture;
it does not run the registered baseline, focused/integration or full test suites.
REPAIR reads the subsequent actual host result and carries any failure into the
existing repair node. It must not infer console details from host validation alone.

## Finite scoped issue ledger

| ID | Established evidence / uncertainty | Disposition and owner | Required closure |
| --- | --- | --- | --- |
| B0 | Original `checks.sh baseline` retained neither raw logs nor selected dirty-input provenance. | Preparation repaired in BASELINE by the single registered helper; no build result inferred. | Input-only capture and focused helper checks; then real host logs/exits. |
| B1 | HOST current-source daemon/app build observed: seven commands exited 0, no skips. | Not reproduced: no missing input or failed build in the actual host record. Later changed targets require rebuild. | Actual registered result and existing outputs, or concrete repaired stage evidence. |
| B2 | `local_product_workflow_test.dart:463–501` uses a revision service but manually saves bytes; `:292` starts Pafio directly; `:505` omits build. | Confirmed coverage gap; REPAIR owns production document/save/daemon wiring and app composition proof. | Component selection, revisioned edit/save/diagnostics and check/build/test/run through vityod → Pafio → Styio. Preserve existing boundary cases. |
| B3 | `scripts/ecosystem-product-gate.py:293–312` requires exactly five successful steps; no mandatory task-resource/failure/repair matrix. | Confirmed assertion gap; REPAIR replaces the deficient route and its report/tests together. | Copy Pafio's five authoritative `.styio`/`.expected` pairs and manifest. Assert history, f64, handled/unhandled failure, good/error/repaired, stale/delayed/concurrent ownership, dry-run preservation. Missing cases fail. |
| B4 | Gate `:27` imposes 600 seconds; product test `:29` imposes 120 seconds and has output-triggered process settlement. | Confirmed healthy-work cutoff; REPAIR traces the inherited production route and fixes scoped equivalents. | Actual completion/failure or explicit cancellation; retained full logs; no arbitrary time/silence/output kill. |
| B5 | Integration entrypoint selects CLI/Pafio but no LSP; separate LSP acceptance permits installed discovery/skips. | Confirmed candidate-evidence gap; REPAIR owns explicit selection using existing daemon/LSP assets. | Exact accepted `styio_lspd` open/change/save with current diagnostics and stale rejection; no installed/pinned substitution. |
| B6 | Accepted Pafio now returns per-invocation outputs under stable cache identity. Existing fixture/static tests do not prove this candidate through production consumers. | Required integration coverage, not an assertion that every consumer is defective. REPAIR inspects execution/snapshot/runtime callers; Reviewer verifies. | Follow returned `plan.path`, `build_root`, `artifact_dir`, `diag_dir` and receipt artifacts; retain old files while invalidating current success on failure. Static/retained-parent delta, unreadable parent, runtime-only, observed good/error/repaired and observe-off continuation through production. |
| B7 | Existing Pafio success-payload document lists flattened/parsed receipt fields; current accepted handoff specifies nested plan paths and compiler-owned receipt opacity. Capability/architecture labels also predate some current implementations. | Evidence/contract alignment within the affected route belongs to REPAIR; unrelated roadmap text remains outside this ledger. | Update affected consumers/tests/docs together against actual owner payload; no redundant parser/schema, alias, fallback layout or sibling edit. |

No outside-scope contract decision is established by this baseline. Future
formatting, complete navigation/refactors, graph authoring, module delivery,
hosted parity and live Agent acceptance are not added to this repair ledger.
Report a demonstrated upstream defect to the coordinator without mutating
sibling sources. Coordinator alone admits final regression after source review
and the same-candidate E2E join.

## Observed preparation and privacy

The registered host build result was read by REPAIR from `latest-host.json`: all seven commands exited 0 and no skips were reported. Preparation, host build and subsequent targeted repair evidence are distinguished in [HANDOFF.md](HANDOFF.md). Neither the source Task/Tree delivery nor hosted E03 delivery
is advanced by these artifacts.

Raw input snapshots, absolute executable/tool paths, build output and any runtime
payload belong only under ignored `build/`. Shared records use relative paths
and safe summaries. The per-item scoped privacy disposition is in HANDOFF; it
does not claim universal secret detection.
