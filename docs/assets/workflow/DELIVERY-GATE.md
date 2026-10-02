# Delivery Pipeline

**Purpose:** Describe the shared local and CI stage pipeline for privacy, architecture, deterministic verification, native package delivery, installation, and launch.

**Last updated:** 2026-10-02

## Entrypoints

The canonical full local delivery is:

```bash
python3 scripts/vityo.py deliver
```

The same Python implementation exposes each stage for focused diagnosis and repair:

```bash
python3 scripts/vityo.py privacy
python3 scripts/vityo.py architecture
python3 scripts/vityo.py test
python3 scripts/vityo.py coverage
python3 scripts/vityo.py build
python3 scripts/vityo.py install
python3 scripts/vityo.py launch
```

CI calls the same stage implementation with its resolved event range, platform, package artifact, and isolated install destination. It does not use a separate shell orchestration path.

## Stage Order

| Stage | Owner and result |
|---|---|
| `privacy` | Runs the privacy scan and repository hygiene check. |
| `architecture` | Checks the architecture model and generated views, documentation and contributor contracts, security/license policy, architecture and product boundaries, import boundaries, dependency/supply-chain policy, and static release readiness. |
| `test` | Runs Flutter analysis, Python and Flutter coverage collection, instrumented locked Cargo tests for the Coding Agent and daemon, registered Coding Agent and nine portable IDE selectors, Prototype checks, required pinned Styio language fixtures, and the CI-only native and product-matrix suites. |
| `coverage` | Evaluates the Python, Flutter, Coding Agent, and daemon reports produced by `test`; it does not collect or rerun the suites. Rust reports remain separate by product and require executed first-party source coverage; the Agent report also requires mapped module coverage. Neither Rust report has a default percentage floor. |
| `build` | Builds the host's Flutter release target and creates/verifies its nightly package candidate, including required companion executables. |
| `install` | Installs the verified candidate to a per-user local location or CI's isolated `--install-root`, then checks the installed client and Agent executable. |
| `launch` | Locally opens the installed client. In CI, runs the candidate-bound startup probe and validates its launch/first-frame evidence. |

The stage runner stops with a nonzero result at the first failed stage and identifies that stage. Repair the failing tool or client behavior, run its focused checks, then rerun the same public stage. Do not treat missing tools, unresolved language fixtures, or an absent test mapping as a skip or pass.

## Toolchain And Product Matrix

The required Styio language-fixture stage accepts an explicit `--styio-bin` or
`VITYO_STYIO_BIN`/`STYIO` override only when it resolves to the exact
`toolchain/product-matrix.json` revision. Otherwise, it reuses a built pinned sibling executable or
fetches/builds the exact revision under ignored `build/toolchains/styio-nightly/<sha>`; an invalid
explicit override or failed provision fails `test`, and unpinned `PATH` binaries are not used. CI
and local runs with `VITYO_PRODUCT_GATE=1` also require the real Pafio/Styio matrix. Pafio is
resolved or provisioned for that matrix only; the matrix creates its project through public `pafio
new` without importing sibling repository scripts.

The Rust Coding Agent and `vityod` daemon require Cargo/Rust `1.88` or newer; hosted jobs pin `1.88.0`. Existing developer bootstrap scripts do not install Rust. The Linux host-readiness script does not detect Cargo, so verify this prerequisite separately before running Rust suites or builds.

## CI Platform Lanes

Configured Linux, Windows, and macOS jobs reuse the same Python pipeline. Linux and macOS run the desktop reconnect integration; macOS also runs the 14-file native UI and credential integration selector. The current app integration root has no Windows-target native integration test. Windows package, install, startup, and portable-test evidence must not be described as a Windows native UI integration pass.

Workflow files and registered suite commands are configuration evidence only. Record only a result observed for the exact candidate revision; an unobserved or queued job remains unresolved.

## Delivery Boundary

Local `install` and `launch` prove package installation and application startup only. The CI startup probe checks the installed candidate identity, runtime platform, successful launch, and first frame; it does not inspect the UI or prove Agent behavior. This pipeline does not conduct a real model-provider conversation or user-assigned development task. The engineering handoff stops after launch; live acceptance belongs to the user's designated Agent on an explicit task.
