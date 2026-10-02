# Checkpoint Health

**Purpose:** Document the canonical portable deterministic test and static-health entrypoint used by contributors and repository CI.

**Last updated:** 2026-10-02

## Command

Run from the repository root:

```bash
./scripts/checkpoint-health.sh
```

This is the integrated portable health entrypoint. Use a focused package command during implementation; run checkpoint health after source review, focused repairs, and ordinary test work are complete.

## Suites And Gates

1. `flutter analyze` in `products/vityo_app/`.
2. Python tooling coverage. `scripts/python-coverage-gate.py` discovers `tests/test_*.py` under `tests/`, then runs the retained Prototype server-security test. The configured Python tooling coverage floor is 95%.
3. Flutter app coverage. `scripts/project-coverage-gate.py` builds the local daemon prerequisite, runs `flutter test --coverage` under `products/vityo_app/`, and enforces the configured 85% Flutter line-coverage floor.
4. Eight deterministic IDE suites through `scripts/vityo_quality.py`: `ide/workspace-transactions`, `ide/developer-loop`, `ide/agent-client-protocol`, `ide/mcp-host`, `ide/ide-security`, `ide/agent-workbench`, `ide/quality-runtime`, and `ide/recovery-isolation`.
5. Deterministic Coding Agent suites through `scripts/vityo_quality.py --product coding-agent --suite full`. The health script writes its validation receipt under `build/evidence/`; receipt generation does not make a failed suite pass.
6. `scripts/release-readiness-gate.py --skip-build` for static release rules. This proves no platform build.
7. `scripts/language-fixture-gate.sh --flutter-dir products/vityo_app` for its declared parser-backed fixture roots. Optional `--fixture-root` arguments intentionally select additional roots.
8. `npm run governance` and `npm run selftest:editor` under `prototype/`.

The daemon-core suite runs the Rust daemon workspace tests with the lockfile enforced, then analyzes and tests `packages/vityo_daemon_protocol/`. This is separate from native desktop UI integration.

The test and suite registry implementation is `scripts/python-coverage-gate.py` plus `scripts/vityo_quality.py`. New ordinary Python tests in `tests/test_*.py` and Flutter tests under `products/vityo_app/test/` are discovered through their normal roots. A standalone suite must be added to the appropriate `vityo_quality.py` registry and invoked by this script or a documented native lane in the same change. The [test catalog](./TEST-CATALOG.md) records owners and future feature acceptance without duplicating suite commands.

This portable command does not run native desktop integration or require a host UI. The configured Linux and macOS jobs run `scripts/vityo_quality.py --product ide --suite native-desktop` for `vityod_reconnect_test.dart`; macOS additionally runs `scripts/vityo_quality.py --product ide --suite macos-native-ui`, covering 11 `*_native_ui_test.dart` files and explicitly registering `editor_native_input_test.dart`, `platform_secure_credential_storage_test.dart`, and `workbench_visual_capture_test.dart` (14 total). The current app integration root has no Windows-target native integration test, so Windows native app integration coverage is absent; Windows still runs its configured portable suites and platform delivery/build checks. The quality-runner tests compare every app integration file with the executable selector literals and globs, rejecting new unregistered tests until they are mapped. Configured but unobserved Actions runs are not test results.

## Tool And Artifact Notes

`PYTHON_BIN` selects the Python executable and defaults to `python3`. `STYIO` may select the fixture parser executable. `--skip-language-fixtures` is a targeted investigation option; it does not establish that language fixtures passed.

GitHub Actions is configured to upload Python and Flutter coverage reports for the platform jobs. The generated root `.coverage` database and app `coverage/` directory remain ignored local artifacts. A report exists only for a run that completed its coverage gate; uploads do not establish coverage for source outside the measured scope.
