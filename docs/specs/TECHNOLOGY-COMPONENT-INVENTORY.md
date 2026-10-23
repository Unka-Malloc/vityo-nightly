# Technology And Component Inventory

**Purpose:** Define the required technology-stack, internal-component, open-source-component, and dependency-manifest inventory for `Vityo`.

**Last updated:** 2026-10-03

This document is the repository-local maintenance rule for the manifest inventory audited by `styio-audit`. The canonical audit module must list the same surfaces in `for-vityo/module.json`; if this document and the audit manifest diverge, the change is not closed.

## Required Inventory Fields

Every audit manifest for this repository must maintain these non-empty lists:

1. `technology_stack`
2. `internal_components`
3. `open_source_components`
4. `dependency_manifests`

Missing or stale lists are audit failures. They block license, commercial-risk, ownership, and usage-boundary review because auditors cannot prove what stack and components are in scope.

## Current Inventory

### Technology Stack

- Flutter and Dart frontend workspace.
- Rust/Cargo workspaces for the current independent Coding Agent runtime and the separately owned `vityod` daemon.
- Android, iOS, macOS, Linux, Windows, and web platform runners.
- CMake native runner integration for desktop platforms.
- JavaScript, HTML, and CSS prototype with Playwright screenshot tooling.
- Python and Bash repository, docs, and device/profile scripts.
- A source-owned architecture model and generator for checked Markdown and HTML diagram views.
- GitHub Actions workflow automation.

### Internal Components

#### Editors, Runtimes, And IDE Surfaces

- Workspace document store, editor controller, selection, persistence, and shell state.
- Backend toolchain and integration adapters for local, hosted, and web execution routes.
- Module host, module manifests, capability matrices, staged updates, and platform visibility.
- Runtime replay surfaces, hosted payload codecs, debug console summaries, and graph/lane models.
- Prototype UI and development server security harness.

#### Security, Permission, And Audit Components

- **Agent Client registry** (`ide/agent_client/agent_client_registry.dart`): thin typed gateway for
  daemon-owned sessions, supplied ACP permission-option presentation and exact-ID response,
  reconnect, and failure projection.
- **Daemon ACP host** (`native/vityod/crates/vityod-agent-host/src/acp.rs`): argv-based stdio
  launch, bounded frames, correlation, cancellation, capability enforcement, and orphan cleanup.
- **Daemon MCP gateway** (`ide/agent_client/mcp/vityod_mcp_gateway.dart` plus native `vityod`
  handlers): declared tools, capability grants, workspace-root authorization, payload bounds,
  sanitization, revision binding, and receipts.
- **Collaboration projection** (`ide/workbench/agent_collaboration/`): immutable task/session,
  permission, change-review, error, and verification state.
- **Workspace transaction authority** (`ide/workspace/workspace_transaction_service.dart`):
  revision-bound preview, commit, reject, and rollback.
- **Execution sandbox** (`execution_sandbox.dart`): Local execution policy with workspace containment, path traversal/symlink detection, environment allowlisting, network policy, timeout, and output bounds.
- **Log redactor** (`log_redactor.dart`): Pattern-based and field-based credential redaction for all log, diagnostic, runtime, and agent-context output.
- **Secret store** (`secret_store.dart`): Credential reference lookup and local secret resolution.
- **Rust Coding Agent** (`products/vityo_coding_agent/src/`): current independent ACP-stdio runtime with ReAct execution, provider, tool catalog/executor, policy, durable sessions, and the correlated host-operation adapter. The old Dart Agent runtime has been removed; the Dart shared-protocol client binding remains.
- **Production MCP attachment boundary**: the Rust MCP client library/tool adapters are maintained, but ACP session creation/loading returns `-32003` for non-empty `mcpServers`; no first-party production attachment lifecycle is available.
- **Rust dependency notices** (`scripts/vityo_rust_notices.py`, `toolchain/licenses/`): License evaluation and third-party notice generation for both Rust workspaces across the supported native desktop-target union.
- **Rust coverage** (`scripts/rust-coverage-gate.py`): Locked workspace coverage collection for the Coding Agent and `vityod`, with separate report-only evaluation, current-platform source labels, and Coding Agent module-coverage evidence.
- **Module manifest security** (`module_manifest_security.dart`): Module manifest trust validation — schema, signature, checksum, permission allowlist, engine compatibility, quarantine, and rollback.

#### Governance And Security Scripts

- `check_security_baseline.py`: Required file existence and forbidden-pattern scan.
- `supply-chain-governance-gate.py`: CI/CD workflow permissions, Dependabot coverage, SBOM evidence, secret ignore baseline, high-signal secret scan.
- `dependency-policy-gate.py`: Dependency registration enforcement in `DEPENDENCY-USAGE.md`.
- `vityo_rust_notices.py`: Supported native-target locked Cargo graph license evaluation and third-party notice generation.
- `github-actions-pin-gate.py`: GitHub Actions SHA-pinning audit and enforcement.
- `check_license_policy.py`: Package license allowlist and forbidden license marker checks.
- `release-readiness-gate.py`: End-to-end release readiness validation.
- `repo-hygiene-gate.py`: Local development hygiene gate (credential scanning, secrets check).

#### Docs, Product, Device, And Delivery Gate Scripts

- Docs, product, device, and delivery gate scripts.

### Open-Source And External Components

- Flutter SDK and Dart SDK.
- Rust Agent and daemon direct dependencies, registered with exact manifest constraints, resolved
  versions, SPDX expressions, and usage boundaries in [Dependency Usage](../../DEPENDENCY-USAGE.md):
  ACP Rust SDK, RMCP, OpenAI-compatible chat SDK, `reqwest` with native TLS, native `keyring`,
  `secrecy`, Tokio, Serde, SQLite (`rusqlite`), and `portable-pty`.
- Rust/Cargo `1.88.0` in CI. The `vityo.py test` stage provisions matching `llvm-tools-preview` and `cargo-llvm-cov` `0.9.0` before coverage collection.
- `cargo-about` `0.9.2` for locked dependency notice generation.
- `cupertino_icons`.
- `shared_preferences`.
- `path_provider`.
- `portable-pty` 0.9.0 in `vityod` (desktop ConPTY/forkpty transport with daemon-owned bounded streams and process cleanup).
- `flutter_test`.
- `flutter_lints`.
- `crypto` (SHA-256/512 for module manifest checksums and signature verification).
- `playwright-core`.
- `PkgConfig`.
- Android Gradle and platform runner toolchains.
- Apple platform runner toolchains.
- GitHub Actions.

### Dependency Manifest Surfaces

- `products/vityo_app/pubspec.yaml`.
- `products/vityo_coding_agent/Cargo.toml` and `Cargo.lock`.
- `products/vityo_app/native/vityod/Cargo.toml` and `Cargo.lock`.
- `toolchain/licenses/about.toml` and `toolchain/licenses/third-party-notices.txt.hbs`.
- `prototype/package.json`.
- `products/vityo_app/linux/CMakeLists.txt`.
- `products/vityo_app/linux/flutter/CMakeLists.txt`.
- `products/vityo_app/windows/CMakeLists.txt`.
- `products/vityo_app/windows/flutter/CMakeLists.txt`.
- Android Gradle files.
- `.github/workflows/*.yml`.

## Maintenance Rule

Update this document and the matching `styio-audit` project module in the same change whenever any of these occur:

1. A language, SDK, runtime, build system, CI system, package manager, platform runner, or generated-code tool is added or removed.
2. A first-party editor, adapter, module-host, runtime, prototype, gate, or workflow boundary is added, renamed, or retired.
3. An open-source or external component is introduced, removed, vendored, promoted from prototype-only to product use, or given a new usage boundary.
4. A dependency manifest is added, removed, renamed, or moved.
5. License, Apache-2.0, commercial-authorization, subscription, membership, trial-only, proprietary-use, or UI asset-source evidence changes.

For new external dependencies, update [THIRD-PARTY.md](./THIRD-PARTY.md), [OPEN-SOURCE-UI-ASSET-POLICY.md](./OPEN-SOURCE-UI-ASSET-POLICY.md) when UI assets are involved, and this inventory together before the change can pass audit.
