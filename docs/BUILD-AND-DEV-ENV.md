# Vityo Build And Dev Environment

**Purpose:** Provide the repository-level entry point for bootstrapping a fresh machine, installing shared GUI toolchains, and routing contributors to the correct implementation surface.

**Last updated:** 2026-10-08

## Who This Is For

1. Contributors bringing up `Vityo` on a fresh Debian/Ubuntu VM or container.
2. Contributors working on the Flutter shell in `products/vityo_app/`.
3. Contributors working on the handwritten web prototype in `prototype/`.
4. Contributors bringing up the native Windows desktop target without WSL or Docker.

## Fresh Machine Bootstrap

`Vityo` now ships both containerized and host-native environment entrypoints.

Flutter source lives under `products/vityo_app/`, and the Dart package is
`vityo_app`.

### Container / VM

Build and launch the standardized Linux developer container:

```bash
./scripts/bootstrap-dev-container.sh
```

Build the Linux + Android combo image:

```bash
./scripts/bootstrap-dev-container.sh --with-android
```

The underlying Dockerfile supports two verified local tags:

```bash
docker build --build-arg INCLUDE_ANDROID=0 -f docker/dev-env.Dockerfile -t vityo-nightly/dev-env:linux-base .
docker build --build-arg INCLUDE_ANDROID=1 -f docker/dev-env.Dockerfile -t vityo-nightly/dev-env:linux-android .
```

`linux-base` is configured for Flutter Linux desktop and web development with Android disabled. `linux-android` adds OpenJDK 21, Android SDK platforms 35 and 36, build-tools 35 and 36, platform-tools, and NDK 28.2.13676358.

For editor-integrated devcontainers, open [../.devcontainer/devcontainer.json](../.devcontainer/devcontainer.json).

### Host Install Matrix

| Host | Base profile | Optional combos | Entry script |
|------|--------------|-----------------|--------------|
| Linux | `linux` desktop + `web` | `linux+android` | `./scripts/bootstrap-dev-env.sh [--with-android]` |
| macOS | `macos` desktop + `web` | `macos+ios`, `macos+android`, `macos+ios+android` | `./scripts/bootstrap-dev-env-macos.sh [--with-ios] [--with-android]` |
| Windows | `windows` desktop + `web` | `windows+android` | `powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap-dev-env-windows.ps1 [-WithAndroid]` |

All host scripts install the standardized toolchain, then call the shared workspace bootstrap entrypoint to restore `npm` / `flutter pub` dependencies and generate the selected Flutter runners. On Windows, `bootstrap-workspace.ps1` resolves `flutter.bat` / `npm.cmd` from `VITYO_FLUTTER_BIN`, `VITYO_FLUTTER_HOME`, `VITYO_NPM_BIN`, or `PATH`. It also preserves tracked Flutter metadata around runner generation and creates plugin junctions for the Windows runner when the host cannot create Flutter's default plugin symlinks.

Device verification stays host-driven:

1. Linux / Android verification uses the shell profile tools plus `verify-android-device.sh`.
2. Windows / Android verification uses the PowerShell profile tools plus `verify-android-device.ps1`.
3. macOS / iOS / macOS verification uses `apple-platform-profile.sh` plus `verify-apple-device.sh`.
4. The Linux container image is for shared desktop/Web/Android development and smoke builds; real mobile device verification still requires the corresponding host OS.

## Standardized Baseline

`Vityo` now follows the same shared project-level version discipline used by `styio-nightly` and `pafio-nightly` where the tool overlaps:

1. Development host standard: Debian `13` (`trixie`).
2. Compiler helper toolchain standard: LLVM / Clang `18.1.x` and CMake / CTest `3.31.6`.
3. Validation Python standard: `3.13.5`.
4. Node.js standard for prototype tooling: `v24.15.0` LTS.
5. Flutter / Dart standard: `3.41.7` / `3.11.5`.
6. Local distribution Chromium standard for web verification: `147.0.7727.116`. CI uses the separate Chrome for Testing build described below.
7. Android combo add-on standard is profile-driven on Linux, macOS, and Windows: command-line tools `14742923`, shared `platform-tools`, and the standardized profile set `android-35`, `android-36`, each with its own pinned platform/build-tools/NDK tuple from [../toolchain/android-sdk-profiles.csv](../toolchain/android-sdk-profiles.csv).
8. Apple build profiles on macOS are standardized in [../toolchain/apple-platform-profiles.csv](../toolchain/apple-platform-profiles.csv). These profiles pin iOS/macOS deployment targets and optionally select a specific `DEVELOPER_DIR` / Xcode installation.
9. Rust/Cargo `1.88.0` is the pinned CI toolchain for the independent Coding Agent and `vityod` daemon. The Coding Agent manifest declares Rust `1.88` as its minimum; local builds need Rust/Cargo `1.88` or newer.
10. CI mirror: GitHub Actions on `ubuntu-latest`, `windows-latest`, and `macos-latest` run the shared Python delivery stages with pinned Python, Node.js, Flutter, Chrome for Testing, and Rust versions, then collect host-specific package, install, startup, and native integration evidence.

### macOS CocoaPods metadata

The macOS CI lane requires CocoaPods `1.17.0` and checks the installed version
exactly before dependency restoration. The committed macOS `Podfile.lock` and
Runner project are generated metadata for the existing Flutter plugin graph
under Flutter `3.41.7` and CocoaPods `1.17.0`. Keep both files current when that
graph changes. A different installed CocoaPods version fails toolchain
verification instead of silently rewriting the lockfile producer version.
The product-matrix clean-checkout gate remains required; do not restore or
ignore generated changes to make it pass.

### CI browser pairing

`VITYO_CI_CHROME_VERSION` in `.github/workflows/local-ci-gate.yml` is the single
CI browser pin for Linux, Windows, and macOS. It selects Chrome for Testing
`147.0.7727.15`, the Chromium version recorded in
[Playwright 1.59.1's browser manifest](https://github.com/microsoft/playwright/blob/v1.59.1/packages/playwright-core/browsers.json).
The editor self-test checks the launched browser's version against this pin.
Update this pairing deliberately when updating Playwright; do not use a moving
`stable` channel in these delivery lanes.

The local distribution Chromium pin remains `.chromium-version`. Its
`147.0.7727.116` build is absent from the official
[Chrome for Testing download index](https://googlechromelabs.github.io/chrome-for-testing/known-good-versions-with-downloads.json),
so it cannot be reused as a CfT download version. The selected CI build has
published Linux x64, Windows x64, macOS x64, and macOS arm64 downloads. This
version pairing does not by itself establish passing host delivery or UI tests.

## Required Toolchains

1. Flutter `3.41.7` with Dart `3.11.5` and the host desktop, Web, and optional Android targets enabled.
2. Android SDK command-line tools, platform tools, build tools, and NDK.
3. Chromium `147.0.7727.116` for local web verification.
4. Node.js `v24.15.0` LTS and npm for the handwritten prototype.
5. Python `3.13.5` for docs and repository hygiene scripts.
6. On macOS, full iOS add-on support also requires Xcode. The script can validate and wire it, but Apple-controlled Xcode installation may still require App Store or Apple developer authentication.
7. Rust/Cargo `1.88` or newer is required to build and test the Coding Agent and local daemon. The existing bootstrap scripts do not install Rust; install the toolchain separately before running those stages. CI pins `1.88.0`.
8. `python3 scripts/vityo.py test` prepares the selected Rust toolchain's `llvm-tools-preview` component and verifies `cargo-llvm-cov` `0.9.0`, installing the locked version when it is missing or different. Direct calls to `scripts/rust-coverage-gate.py` require those tools to be present already. If the selected toolchain or pinned tool cannot be installed or verified, the test stage fails; it does not skip Rust coverage.
9. On Windows, native desktop builds require Visual Studio 2022 Build Tools with the C++ desktop workload. `bootstrap-dev-env-windows.ps1` installs this through `winget`; hosted `windows-latest` CI already includes the required build environment.

Python test collection also requires `coverage.py`. Prepare a repository-local virtual
environment once; use its activated `python3` for the delivery command. Do not install
the coverage dependency into the host's global Python environment.

```bash
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install coverage
python3 scripts/vityo.py deliver
```

On Windows, activate the same environment with `.venv\Scripts\Activate.ps1` and use
`python` where the host does not provide `python3`. The ignored `.venv/` contains only
developer dependencies; it is not packaged with the client.

## Typical Build And Test Commands

Shared workspace bootstrap after the toolchain is present:

```bash
./scripts/bootstrap-workspace.sh --platforms web,linux
```

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap-workspace.ps1 -Platforms web,windows
```

Example combinations:

```bash
./scripts/bootstrap-workspace.sh --platforms web,linux,android
./scripts/bootstrap-workspace.sh --platforms web,macos,ios
./scripts/bootstrap-workspace.sh --platforms web,macos,android
```

Windows native desktop validation:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap-dev-env-windows.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap-workspace.ps1 -Platforms web,windows
Set-Location frontend\vityo_app
flutter pub get
flutter analyze
flutter test
flutter build windows --debug
```

Run the Windows validation commands from a regular PowerShell session. The bootstrap script restores the tracked `.metadata` and `pubspec.lock` files after Flutter writes generated state, and the plugin junction fallback avoids requiring Developer Mode or elevated symlink privileges for `flutter build windows --debug`.

Linux Android SDK profile management:

```bash
./scripts/android-sdk-profile.sh list
eval "$(./scripts/android-sdk-profile.sh env android-35)"
./scripts/android-sdk-profile.sh run android-36 -- bash -lc 'cd products/vityo_app && flutter build apk --debug'
./scripts/android-sdk-profile.sh build --profiles android-35,android-36 --parallel --artifact apk --mode debug
```

Linux host bootstrap can install multiple Android SDK profiles into the same SDK root:

```bash
./scripts/bootstrap-dev-env.sh --with-android --android-profiles android-35,android-36 --android-default-profile android-36
```

The Linux container path supports the same profile set:

```bash
./scripts/bootstrap-dev-container.sh --with-android --android-profiles android-35,android-36 --android-default-profile android-36
```

macOS profile management:

```bash
./scripts/bootstrap-dev-env-macos.sh --with-ios --with-android --android-profiles android-35,android-36 --android-default-profile android-36
./scripts/android-sdk-profile.sh list
./scripts/apple-platform-profile.sh list
eval "$(./scripts/android-sdk-profile.sh env android-35)"
eval "$(./scripts/apple-platform-profile.sh env ios-15)"
./scripts/apple-platform-profile.sh build --profiles ios-13,ios-15 --parallel --mode debug --simulator --no-codesign
./scripts/apple-platform-profile.sh build --profiles macos-10.15,macos-12 --parallel --mode debug
```

Windows Android SDK profile management:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap-dev-env-windows.ps1 -WithAndroid -AndroidProfiles android-35,android-36 -AndroidDefaultProfile android-36
powershell -ExecutionPolicy Bypass -File .\scripts\android-sdk-profile.ps1 list
powershell -ExecutionPolicy Bypass -File .\scripts\android-sdk-profile.ps1 env android-35
powershell -ExecutionPolicy Bypass -File .\scripts\android-sdk-profile.ps1 build --profiles android-35,android-36 --parallel --artifact apk --mode debug
```

Real-device verification entrypoints:

```bash
./scripts/verify-android-device.sh --profile android-36 --device-id <adb-device-id> --mode debug
./scripts/verify-apple-device.sh --profile ios-15 --device-id <flutter-ios-device-id> --mode debug
./scripts/verify-apple-device.sh --profile macos-12 --mode debug
```

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify-android-device.ps1 -Profile android-36 -DeviceId <adb-device-id> -Mode debug
```

Use the same profile family for bootstrap, build, and device verification. Do not mix `android-35` bootstrap with `android-36` device verification unless you are explicitly testing a cross-profile mismatch.

Flutter shell:

```bash
cd products/vityo_app
flutter analyze
flutter test
flutter build web
```

Windows Flutter shell:

```powershell
Set-Location frontend\vityo_app
flutter pub get
flutter analyze
flutter test
flutter build windows --debug
```

Focused editor local preview:

```bash
./scripts/serve-flutter-web-preview.sh
```

This is the preferred one-command browser startup path for local editor review. It starts `prototype/dev_server.py` on port `8080`, redirects `/` to `/editor`, and serves the canonical focused editor from `prototype/editor.html`. The legacy script name is kept for compatibility, but this path no longer builds or serves the Flutter integration shell as the default visible page.

Handwritten prototype:

```bash
cd prototype
npm ci
npm run selftest:editor
```

If you use the bundled `dev_server.py` directly, set the focused editor URL explicitly because the default server port is `4180`:

```bash
cd prototype
VITYO_EDITOR_URL=http://127.0.0.1:4180/editor npm run selftest:editor
```

Repository privacy and architecture/documentation checks:

```bash
python3 scripts/vityo.py privacy
python3 scripts/vityo.py architecture
python3 scripts/docs-index.py --write
```

IDE architecture, import boundary, sandbox/security, and performance budget checks:

```bash
python3 scripts/check_architecture_boundaries.py
python3 scripts/import-boundary-gate.py
python3 scripts/check_security_baseline.py
python3 scripts/check_performance_budgets.py
git diff --check
```

`check_architecture_boundaries.py` enforces `view_ide/` and `ide/` as Flutter-free
domain/application layers and `view_render/` as the presentation layer.
`import-boundary-gate.py` enforces the remaining product import rules.
`check_security_baseline.py` protects sandbox execution, log redaction, secret storage, module
manifest security, and Agent permission presentation. `check_performance_budgets.py` verifies
benchmark coverage for the performance-sensitive IDE paths.

Linux host readiness gate (run inside WSL or a Linux container before full builds):

```
python3 scripts/check-linux-host-readiness-gate.py
python3 scripts/check-linux-host-readiness-gate.py --json
python3 scripts/check-linux-host-readiness-gate.py --check flutter
```

This gate detects and reports blocked states for Python, Dart/Flutter, npm,
Chrome/Chromium, Docker image Flutter availability, and CRLF shell-script
line-ending blockers. It does not detect Rust/Cargo or Rust coverage prerequisites; run
`python3 scripts/vityo.py test` to verify Rust `1.88` or newer and prepare the selected toolchain's
coverage component and pinned collector. Direct lower-level Rust build or coverage helpers still
require their documented Rust/Cargo tools on `PATH`. The readiness gate never attempts to
repair external SDKs or install packages. Exit codes: 0 all clear, 1 blocked
items found, 2 warnings only.
Unit tests:

```
python3 -m unittest tests.test_linux_host_readiness_gate -v
```

When Dart or Flutter is available and the change touches editor data structures, language cache,
workspace graph, runtime events, Agent context packing, watchers, or UI virtualization, run the
benchmark regression gate:

```bash
python3 scripts/performance-gate.py --threshold 1.10
```

Static release readiness without a release build:

```bash
python3 scripts/release-readiness-gate.py --skip-build
```

Full local delivery, including tests, coverage, release package, per-user installation, and launch:

```bash
python3 scripts/vityo.py deliver
```

In macOS CI, the launch stage supervises the installed bundle executable directly
with the existing first-frame probe arguments. A 120-second startup deadline and
five-second termination grace apply only to this CI probe, not ordinary app use.
A timeout or nonzero exit fails delivery even if an evidence file exists; success
also requires fresh, candidate-bound rasterized-first-frame evidence. The supervisor
terminates only its owned app PID and reaps it, escalating to kill after the grace.
`build/evidence/startup-macos-diagnostics.json` records the command, owned PID, exit
status, timeout, and credential-redacted output. Capture retains at most 64 KiB per
stream, discards a truncated last line, and never dumps environment variables or
writes unbounded raw logs. After app exit, inherited pipes have a separate 0.2-second
drain limit; they cannot consume the startup deadline or cause descendant termination.
CI uploads these diagnostics even on failure. Ordinary
local macOS launch still uses LaunchServices to open a new installed app instance.
Startup evidence does not establish live UI or real Agent-task acceptance.

### Ecosystem product-gate environment

The required language-fixture stage resolves Styio in this order: explicit
`--styio-bin`; `VITYO_STYIO_BIN` or `STYIO`; a built executable in the sibling checkout at the
exact product-matrix revision; then a managed checkout under ignored
`build/toolchains/styio-nightly/<sha>`. The managed resolver fetches and builds the exact public
upstream commit without changing a sibling worktree. An explicitly selected executable that is
missing or not from the pinned checkout fails `python3 scripts/vityo.py test`; the stage does not
fall back to an unpinned `PATH` binary. Building the managed Styio tool requires CMake and LLVM 18
CMake development files. CI uses the same resolver. Pafio is resolved or provisioned only when the
real product matrix is enabled in CI or with `VITYO_PRODUCT_GATE=1`; that matrix creates its project
through public `pafio new` and does not import a Pafio repository script or fixture factory.

The scheduled Linux, Windows, and macOS jobs run independently and publish a
platform-specific matrix evidence JSON containing the exact Vityo, Styio, and
Pafio commits. That evidence proves the Vityo adapter matrix only; it keeps
`productCapabilityComplete=false` until the separately versioned real product
matrix satisfies the product capability claim.

## Repository-Local Developer Cache

Use the repository-root `.cache/` directory for project-specific development
materials that are useful locally but must not be committed. Suitable contents
include downloaded source archives or checkouts, reusable installers, portable
developer tools, and expensive download caches.

The cache is optional and reconstructible. Do not place canonical source,
configuration, credentials, release evidence, or the only copy of an artifact
under `.cache/`. Scripts that consume cached material must resolve the directory
relative to the repository root, create missing subdirectories, and either
re-download missing inputs or report a clear recovery action.

Normal build and package-manager working directories keep their established
locations: Flutter `.dart_tool/` and build output, Node `node_modules/`, and
platform-generated state remain in their conventional project directories. The
root `.gitignore` excludes `.cache/` from commits.

## Subsystem-Specific Follow-Ups

1. Flutter shell details: [../products/vityo_app/README.md](../products/vityo_app/README.md)
2. Handwritten prototype details: [../prototype/README.md](../prototype/README.md)
3. Product and system design: [design/Vityo-System-Architecture.md](./design/Vityo-System-Architecture.md)
4. Team and review routing: [teams/COORDINATION-RUNBOOK.md](./teams/COORDINATION-RUNBOOK.md)
5. Host-local Windows workspace bootstrap: [../scripts/bootstrap-workspace.ps1](../scripts/bootstrap-workspace.ps1)
6. Contribution workflow: [../CONTRIBUTING.md](../CONTRIBUTING.md)
7. Release checklist: [governance/RELEASE-CHECKLIST.md](./governance/RELEASE-CHECKLIST.md)

## Related Docs

1. Docs tree guide: [README.md](./README.md)
2. Product spec: [design/Vityo-Product-Spec.md](./design/Vityo-Product-Spec.md)
3. Handwritten Web IDE handbook: [specs/HANDWRITTEN-WEB-IDE-ENGINEERING-HANDBOOK.md](./specs/HANDWRITTEN-WEB-IDE-ENGINEERING-HANDBOOK.md)

## Isolated Local Toolchain Acceptance

Use `products/vityo_app/lib/main_compile_acceptance.dart` for the bounded
no-Agent local toolchain check. It composes the same `FlowHeroApp`, controller,
selection UI, and production Pafio execution service as `lib/main.dart`.
Only bootstrap ownership changes: a fresh temporary workspace copy, stores,
daemon endpoint/state and child-process home/cache roots. Agent restoration,
provider configuration and keychain access are disabled before they are reached.
Each launch starts fresh; it does not restore selections from a prior launch or
replace the installed application. Temporary evidence remains under that launch's
root. The ordinary production entrypoint is unchanged.

On a supported macOS development host, build the candidate daemon and launch the
candidate client from `products/vityo_app/`:

```bash
cargo build --locked --manifest-path native/vityod/Cargo.toml -p vityod
flutter run -d macos --target lib/main_compile_acceptance.dart \
  --dart-define=VITYO_COMPILE_ACCEPTANCE_WORKSPACE=/absolute/path/to/small-fixture \
  --dart-define=VITYO_COMPILE_ACCEPTANCE_DAEMON=/absolute/path/to/candidate/vityod
```

The explicitly supplied fixture is copied before use; symbolic links and oversized
fixtures are rejected. Use a small Pafio project, not a live project or a directory
containing credentials. The daemon override must identify this candidate's built
executable. Without an override, the entry requires the normal packaged daemon
location beside the client and still starts it with private state. Do not use the
normal install stage for this isolated check.

Open Settings → execution service and select the candidate Pafio and full Styio
binaries. The Pafio candidate owns contract-first admission and prior-receipt
invalidation; Styio remains the compiler and receipt producer. No Coding Agent
component or provider account is needed. Test invalid explicit paths, both valid
selections, real Run, compiler failure after success, and an unlisted local
version/channel that still satisfies the required contracts. A failed run must
not display a previous receipt as the new result. Record actual executable/source
revisions and distinguish these observations from deterministic tests.

The focused engineering command is:

```bash
flutter test --no-pub test/flow_hero_execution_test.dart \
  test/flow_hero_local_services_test.dart test/flow_hero_toolchain_install_test.dart \
  test/pafio_cli_discovery_test.dart test/styio_toolchain_discovery_lspd_test.dart \
  test/flow_hero_compile_acceptance_test.dart
```

Run package resolution first with the repository's pinned Flutter/Dart SDK. Keep
unrelated lockfile changes out of this feature and record any SDK-dependent
resolution difference in delivery evidence. The daemon-backed discovery groups
and the isolation socket test require a host that permits Unix-domain sockets;
a blocked host is incomplete evidence, not a passing test. This bootstrap and
its deterministic tests do not establish real macOS UI acceptance.
