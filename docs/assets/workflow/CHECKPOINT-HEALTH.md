# Test and Coverage Stages

**Purpose:** Describe deterministic test collection, native integration reach, and coverage evaluation in the canonical Vityo delivery pipeline.

**Last updated:** 2026-10-03

## Commands

From the repository root, collect tests and coverage inputs with:

```bash
python3 scripts/vityo.py test
```

After the test stage succeeds, evaluate the saved reports with:

```bash
python3 scripts/vityo.py coverage
```

The `test` stage collects Python and Flutter coverage and runs the Rust Coding Agent requirement
suite and instrumented locked workspace tests for the Coding Agent and `vityod` once. Before test
collection it prepares `llvm-tools-preview` and verifies or installs the pinned
`cargo-llvm-cov` `0.9.0`; failed Rust toolchain installation fails the stage. The separate
`coverage` stage evaluates the Python, Flutter, Coding Agent, and daemon reports without rerunning
the suites. Rust reports are kept separate by product; both require valid executed first-party
source coverage, the Agent report additionally requires mapped coverage for all nine requirements,
and neither has a default percentage floor.
A full local delivery runs both stages in order through `python3 scripts/vityo.py deliver`.
The Rust LCOV reports are `build/evidence/rust-coverage/coding-agent.lcov` and
`build/evidence/rust-coverage/vityod.lcov`.

## Test Stage Scope

The current `test` implementation runs Flutter analysis; discovers Python tests under `tests/test_*.py`; runs Flutter tests under `products/vityo_app/test/`; runs the Rust `coding-agent/full` requirement suite with one locked coverage collection plus the instrumented `vityod` workspace; invokes nine portable IDE selectors; runs retained Prototype governance and editor checks; and validates the declared language fixtures with the pinned Styio executable.

The test stage resolves Styio from an explicit `--styio-bin`, `VITYO_STYIO_BIN`/`STYIO`, or a
built sibling executable at the exact product-matrix revision. If none is available, it fetches and
builds that pinned revision under ignored `build/toolchains/`; it does not accept an unpinned PATH
binary. An invalid explicit override or failed pinned build fails the stage. CI and a local run with
`VITYO_PRODUCT_GATE=1` additionally require the real Styio/Pafio product matrix.

The current Coding Agent is an independent Rust ACP-stdio runtime. Its `coding-agent/full` suite
executes the maintained nine-requirement behavior plan and collects the Rust report once; the IDE
client integration tests separately exercise host operation and permission/proposal consumers.
The production ACP host rejects non-empty `mcpServers` with `-32003`; MCP library tests do not imply
server attachment support. Deterministic tests do not call a live provider or complete a user task.

## Integration Test Mapping

The app's standalone integration-test root has 21 maintained files. A quality-runner test checks each source file against its executable literals and globs so a new file cannot silently miss the runner. The nine portable IDE selectors cover the current portable fixtures; the native selectors remain host-specific:

| Host lane | Selector | Coverage |
|---|---|---|
| Linux and macOS CI | `ide/native-desktop` | The supported desktop reconnect integration. |
| macOS CI | `ide/macos-native-ui` | Eleven `*_native_ui_test.dart` files plus `editor_native_input_test.dart`, `platform_secure_credential_storage_test.dart`, and `workbench_visual_capture_test.dart` (14 files). |
| Windows CI | No native app integration selector | Windows currently has no Windows-target app integration test. Portable suites and Windows build/package/startup evidence are separate. |

The test root and executable suite registry are authoritative. This document records their current reach; it does not replace the registration. A configured but unobserved CI job is not test evidence.

## Evidence Boundary

These suites exercise deterministic implementation and protocol fixtures. They do not call a real model provider or complete a user-assigned Agent task. Package installation and the CI startup probe belong to later delivery stages; startup evidence establishes only that the selected installed client launched and rendered its first frame. Live interface inspection and real provider/task acceptance remain separate user-authorized work.

Future Flow Hero graph/source semantics, edge direction, transactional rewiring, revision handling, animation parity, and performance acceptance remain listed in the [test catalog](./TEST-CATALOG.md) as unimplemented requirements.
