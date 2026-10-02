# Dependency Usage Boundary

**Purpose:** Record dependency authorization boundaries for `Vityo`.

**Last updated:** 2026-10-03

`Vityo` is an Apache-2.0 Flutter/Dart application with independent Rust Coding Agent and daemon
workspaces and a permanent JavaScript prototype source asset. Product dependencies and direct
build/CI tool dependencies are inventoried separately below.

## Runtime Dependencies

| Dependency | Version | License | Source Boundary | Usage Boundary | Classification |
|---|---|---|---|---|---|
| `flutter` (SDK) | Flutter SDK | BSD-3-Clause | Flutter framework SDK | UI framework, rendering, widgets, platform channels | Runtime |
| `crypto` | ^3.0.7 | BSD-3-Clause | `package:crypto` from Dart SDK ecosystem | Cryptographic hash functions (SHA-256, SHA-512, HMAC) for content hashing, toolchain artifact verification, cache key derivation | Runtime |
| `ffi` | ^2.2.0 | BSD-3-Clause | `package:ffi` from pub.dev | Native allocation and UTF-16 conversion for the Windows named-pipe transport boundary | Runtime (Windows desktop only) |
| `flutter_secure_storage` | ^11.0.0 | BSD-3-Clause | `package:flutter_secure_storage` from the Flutter ecosystem | OS-backed credential persistence through Apple Keychain, Android encrypted storage, Windows secure storage, and Linux libsecret; browser storage is excluded from the production credential route | Runtime |
| `cryptography` | ^2.9.0 | Apache-2.0 | `package:cryptography` from pub.dev | Cryptographic primitives for signature verification, key derivation, secure random generation used in toolchain provenance and secret handling | Runtime |
| `web` | ^1.1.1 | BSD-3-Clause | `package:web` from Dart SDK ecosystem | Web platform interop types for browser-virtual file system provider and web-hosted workspace route | Runtime (Web target only) |
| `cupertino_icons` | ^1.0.8 | MIT | `package:cupertino_icons` from pub.dev | iOS-style icon set for Cupertino-themed UI surfaces on iOS and macOS targets | Runtime (iOS/macOS) |
| `shared_preferences` | ^2.5.5 | BSD-3-Clause | `package:shared_preferences` from Flutter ecosystem | Platform-appropriate persistent key-value store for user settings, theme profile, session preferences | Runtime |
| `path_provider` | ^2.1.5 | BSD-3-Clause | `package:path_provider` from Flutter ecosystem | Platform-appropriate directory path resolution for local file system operations, cache directories, document directories | Runtime |
| `vityo_agent_protocol` | Workspace path package | Apache-2.0 | `packages/vityo_agent_protocol` in this repository | Pure versioned JSON-RPC/ACP wire types shared by the Vityo IDE and compatible Agent runtimes; contains no product orchestration or runtime implementation | Runtime (internal shared protocol) |

## Dev Dependencies

| Dependency | Version | License | Source Boundary | Usage Boundary | Classification |
|---|---|---|---|---|---|
| `flutter_test` (SDK) | Flutter SDK | BSD-3-Clause | Flutter test framework SDK | Widget tests, unit tests, integration tests | Dev |
| `flutter_lints` | ^5.0.0 | BSD-3-Clause | `package:flutter_lints` from Flutter ecosystem | Static analysis lint rules for Dart/Flutter code quality | Dev |
| `test` | ^1.26.0 | BSD-3-Clause | `package:test` from pub.dev | Non-Flutter Dart unit tests for workspace transaction and standalone service contracts | Dev |
| `vm_service` | ^15.2.0 | BSD-3-Clause | `package:vm_service` from the Dart ecosystem | VM service protocol access used by Flutter Inspector and desktop integration diagnostics | Dev |

## Rust Dependencies

This table registers direct external dependencies declared by the Cargo workspaces. The lock
column records the resolved version; `Source boundary` identifies the workspace manifest. License
policy also evaluates transitive dependencies in the supported desktop-target graphs defined by
the [Security and Supply Chain policy](docs/governance/SECURITY-AND-SUPPLY-CHAIN.md#42-license-policy).

| Dependency | Version (manifest constraint and resolved lock) | License expression | Source boundary | Usage boundary | Classification |
|---|---|---|---|---|---|
| `agent-client-protocol` | =2.2.0 → 2.2.0 | Apache-2.0 | `products/vityo_coding_agent/Cargo.toml` | ACP v1 protocol types and stdio session boundary for the independent Coding Agent process | Runtime |
| `async-openai` | =0.42.1 → 0.42.1 | MIT | `products/vityo_coding_agent/Cargo.toml` | OpenAI-compatible chat request/response and streaming adapter types used by the Agent provider | Runtime |
| `async-trait` | ^0.1.89 → 0.1.92 | MIT OR Apache-2.0 | `products/vityo_coding_agent/Cargo.toml` | Async trait boundaries for provider, host, policy, session, and tool components | Runtime |
| `fs2` | =0.4.3 → 0.4.3 | MIT OR Apache-2.0 | `products/vityo_coding_agent/Cargo.toml` | Cross-process file locking for durable Agent session state | Runtime |
| `futures` | ^0.3.32 → 0.3.34 | MIT OR Apache-2.0 | `products/vityo_coding_agent/Cargo.toml` | Stream composition for provider events and asynchronous Agent operations | Runtime |
| `keyring` | =4.2.0 → 4.2.0 | MIT OR Apache-2.0 | `products/vityo_coding_agent/Cargo.toml` | Resolve bearer credentials by native credential-service/account reference; no raw credential is stored in provider configuration | Runtime |
| `reqwest` | =0.13.5 → 0.13.5 | MIT OR Apache-2.0 | `products/vityo_coding_agent/Cargo.toml` | TLS-enabled HTTP transport used by the configured OpenAI-compatible provider adapter | Runtime |
| `rmcp` | =3.5.0 → 3.5.0 | Apache-2.0 | `products/vityo_coding_agent/Cargo.toml` | MCP client types, adapters, and child-process transport; deterministic peer tests cover the library, while production ACP rejects non-empty `mcpServers` with `-32003` | Runtime |
| `secrecy` | =0.10.3 → 0.10.3 | Apache-2.0 OR MIT | `products/vityo_coding_agent/Cargo.toml` | Keep resolved secret values in secret-marked runtime types and prevent accidental display | Runtime |
| `serde` | ^1.0 → 1.0.229 | MIT OR Apache-2.0 | `products/vityo_coding_agent/Cargo.toml` | Typed protocol, provider, session, policy, and tool serialization | Runtime |
| `serde_json` | ^1.0 → 1.0.151 | MIT OR Apache-2.0 | `products/vityo_coding_agent/Cargo.toml` | JSON serialization for ACP messages and Agent-owned persisted state | Runtime |
| `sha2` | ^0.10 → 0.10.9 | MIT OR Apache-2.0 | `products/vityo_coding_agent/Cargo.toml` | SHA-256 content digests for stable Agent state and tool/effect evidence | Runtime |
| `tempfile` | ^3 → 3.27.0 | MIT OR Apache-2.0 | `products/vityo_coding_agent/Cargo.toml` | Isolated temporary directories and files in deterministic tests | Dev |
| `thiserror` | ^2.0 → 2.0.21 | MIT OR Apache-2.0 | `products/vityo_coding_agent/Cargo.toml` | Typed errors at provider, protocol, policy, session, and tool boundaries | Runtime |
| `tokio` | ^1.52 → 1.53.1 | MIT | `products/vityo_coding_agent/Cargo.toml` | Async process, stream, task, signal, synchronization, and runtime execution | Runtime |
| `tokio-util` | ^0.7 → 0.7.19 | MIT | `products/vityo_coding_agent/Cargo.toml` | Structured cancellation tokens for Agent requests and operations | Runtime |
| `tracing` | ^0.1 → 0.1.44 | MIT | `products/vityo_coding_agent/Cargo.toml` | Structured Agent diagnostics with credential-safe fields | Runtime |
| `uuid` | ^1.18 → 1.26.1 | Apache-2.0 OR MIT | `products/vityo_coding_agent/Cargo.toml` | Opaque Agent session, request, and effect identifiers | Runtime |
| `libc` | ^0.2 → 0.2.189 | MIT OR Apache-2.0 | `products/vityo_app/native/vityod/Cargo.toml` | Native daemon process and platform integration on Unix targets | Runtime |
| `portable-pty` | ^0.9 → 0.9.0 | MIT | `products/vityo_app/native/vityod/Cargo.toml` | Daemon-owned Linux/macOS PTY and Windows ConPTY process transport | Runtime |
| `rusqlite` | ^0.37 → 0.37.0 | MIT | `products/vityo_app/native/vityod/Cargo.toml` | Durable local daemon workspace and session storage | Runtime |
| `serde` | ^1.0 → 1.0.229 | MIT OR Apache-2.0 | `products/vityo_app/native/vityod/Cargo.toml` | Typed daemon IPC and persisted workspace models | Runtime |
| `serde_json` | ^1.0 → 1.0.151 | MIT OR Apache-2.0 | `products/vityo_app/native/vityod/Cargo.toml` | JSON-RPC and persisted daemon state serialization | Runtime |
| `windows-sys` | ^0.61 → 0.61.2 | MIT OR Apache-2.0 | `products/vityo_app/native/vityod/Cargo.toml` | Windows native process, pipe, filesystem, and console APIs used by the daemon | Runtime (Windows desktop only) |

## Prototype Dependencies

| Dependency | Version | License | Source Boundary | Usage Boundary | Classification |
|---|---|---|---|---|---|
| `playwright-core` | prototype/package.json | Apache-2.0 | npm `playwright-core` | Prototype screenshot and browser automation tooling | Dev (prototype only) |

## Build / CI / Platform Toolchain Dependencies

| Dependency | Version | Source / Installation | Classification |
|---|---|---|---|
| Rust / Cargo | CI pin 1.88.0; local 1.88 or newer | System toolchain; bootstrap scripts do not install Rust | Build / Test |
| `llvm-tools-preview` | Matching selected Rust toolchain | Prepared by `python3 scripts/vityo.py test`; direct coverage-helper callers must provide the component | Coverage |
| `cargo-llvm-cov` | 0.9.0 | `vityo.py test` verifies the exact version and installs it with Cargo when needed; direct coverage-helper callers must provide version 0.9.0 on `PATH` | Coverage |
| `cargo-about` | 0.9.2 | `cargo install --locked --version 0.9.2 --features cli --root build/tools/cargo-about-0.9.2 cargo-about`; notice generation installs it project-locally | License / Notices |
| CMake | System / CI image | Platform toolchain | Build |
| PkgConfig | System / CI image | Platform toolchain | Build |
| Android Gradle | Android SDK / CI image | Platform toolchain | Build |
| Apple platform runner toolchains | macOS / Xcode | Platform toolchain | Build |
| GitHub Actions | GitHub-hosted runners | CI | CI |
| Python standard library (3.13.x) | System / CI image | CI / Scripts | CI / Scripts |
| Bash | System | CI / Scripts | CI / Scripts |
| Node.js (24.x) | System / CI image | Prototype tooling | CI (prototype) |
| Flutter SDK (3.41.x) | System / CI image | Flutter toolchain | Build |

### Rust Tool License Evidence

| Tool | Version | License expression | Usage boundary |
|---|---|---|---|
| `cargo-llvm-cov` | 0.9.0 | Apache-2.0 OR MIT | Instrumented Rust workspace coverage collection; requires the matching `llvm-tools-preview` Rust component |
| `cargo-about` | 0.9.2 | MIT OR Apache-2.0 | Checks supported-target locked Cargo dependency graphs and emits complete third-party notices through the project-local `scripts/vityo_rust_notices.py` wrapper |

## UI Assets

UI assets must remain covered by documented open-source asset evidence before promotion into product surfaces. Asset sources and licenses are tracked in `docs/assets/INDEX.md`.

Bundled product fonts (declared in `products/vityo_app/pubspec.yaml`, stored in `products/vityo_app/assets/fonts/` with their license texts):

| Asset | Version | License | Source Boundary | Usage Boundary | Classification |
|---|---|---|---|---|---|
| Plus Jakarta Sans (TTF 400/500/600/700/800) | google/fonts `ofl/plusjakartasans` | OFL-1.1 (`assets/fonts/OFL-PlusJakartaSans.txt`) | Google Fonts distribution of the Tokotype release | Product UI text family across desktop, web, and mobile surfaces | Runtime asset |
| Azeret Mono (TTF 400/500/600) | google/fonts `ofl/azeretmono` | OFL-1.1 (`assets/fonts/OFL-AzeretMono.txt`) | Google Fonts distribution | Code, terminal, status-bar, and keycap text | Runtime asset |

## Policy Rules

1. **No commercial/paid/proprietary dependencies.** No dependency may require commercial authorization, paid licensing, subscription access, membership access, trial-only terms, proprietary-use approval, or private registry access.
2. **Pre-registration required.** Any future dependency must be listed here with its license evidence, source boundary, and usage boundary before it can pass audit.
3. **Prototype isolation.** Prototype-only dependencies must stay prototype-scoped and must not become product runtime requirements without this file being updated.
4. **SDK exceptions.** Flutter SDK and Dart SDK dependencies are granted blanket authorization as platform-provided SDK components.
5. **Gate enforcement.** `scripts/dependency-policy-gate.py` requires every direct dependency in the maintained Flutter/Dart, Cargo, and prototype npm manifests to have a corresponding backtick-quoted package entry in this file.
6. **License evidence required.** Each non-SDK dependency must carry a recognized SPDX license identifier or explicit license evidence.
7. **Generated reports.** Generated reports and gate summaries must summarize dependency, UI asset, and license evidence without copying target repository source.
