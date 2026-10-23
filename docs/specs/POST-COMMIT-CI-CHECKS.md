# Verification And CI

**Purpose:** Define the canonical local verification flow, test-suite-to-CI requirements, and evidence boundaries for GitHub Actions and later acceptance.

**Last updated:** 2026-10-03

## Test Connection Is Part Of The Change

Every new or changed behavior carries deterministic tests and a working CI route in the same change. Tests under established roots are discovered by their ordinary runner. A standalone suite or package outside those roots is added to the canonical runner and the applicable portable or native CI lane; do not keep a test that CI cannot run and report it as covered. The [test catalog](../assets/workflow/TEST-CATALOG.md) maps owners and future Flow Hero acceptance. The runner implementation remains the executable suite registry.

Tests exercise the implementation at the layer that owns the behavior. Unit and contract tests cover syntax, state transitions, workspace transactions, policy, protocol ordering, persistence, and recovery. Deterministic integration tests use real internal modules with fixtures at external boundaries. No passing declaration substitutes for command output.

## Canonical Local Entrypoints

Run focused stage commands while implementing. After all writers stop, source review and scoped repairs finish, the single full local delivery command is:

```bash
python3 scripts/vityo.py deliver
```

It runs privacy, architecture/documentation, test collection, coverage evaluation, host release build/package, per-user installation, and launch in order. For focused repair, the stages are independently callable as `privacy`, `architecture`, `test`, `coverage`, `build`, `install`, and `launch` subcommands of `scripts/vityo.py`. The first failed stage returns a nonzero result; there is no health-skip flag or alternate shell orchestration.

### Test And Coverage Scope

Before collecting tests, `test` prepares `llvm-tools-preview` and verifies or installs the pinned
`cargo-llvm-cov` `0.9.0`; setup failure fails the stage. It then runs Flutter analysis; discovers
Python tests under `tests/test_*.py`; runs Flutter tests under `products/vityo_app/test/`; executes
the Rust Coding Agent's nine-requirement suite with one instrumented locked workspace collection;
collects the instrumented `vityod` workspace once; invokes nine portable IDE selectors; runs
Prototype governance and editor checks; and validates the declared language fixtures with a pinned
Styio executable. `coverage` evaluates the Python, Flutter, Coding Agent, and daemon reports without
rerunning those suites. Rust reports remain separate by product and require executed first-party
source coverage; the Agent report also requires mapped coverage for all nine requirement areas.
Neither Rust report has a default percentage floor.

| Suite | Pipeline mapping | What a pass establishes |
|---|---|---|
| Python repository and tooling tests | `test` stage; `tests/test_*.py` discovery with coverage collection | Discovered repository-tool tests passed. |
| Flutter IDE unit/widget/contract tests | `test` stage; Flutter test discovery under `products/vityo_app/test/` with coverage collection | Discovered app tests passed; does not establish live provider or user behavior. |
| Rust daemon and daemon protocol | `test` stage; instrumented locked `vityod` workspace tests plus registered `ide/daemon-core` suite | Daemon Rust and shared protocol behavior is exercised without launching the desktop UI. |
| Coding Agent behavior and Rust coverage | `test` stage; registered `coding-agent/full` nine-requirement suite with instrumented locked Rust workspace collection | Exercises the current Rust ACP-stdio runtime and records each requirement outcome plus coverage. It does not call a live provider or prove a user-assigned task. |
| Portable IDE integration | `test` stage; nine registered `ide/<suite>` selectors | Deterministic local IDE and protocol seams passed. |
| Native desktop reconnect | `ide/native-desktop` on Linux and macOS CI | The supported `vityod_reconnect_test.dart` host integration passed. It is not run on Windows. |
| macOS native UI and credential integration | `ide/macos-native-ui` on macOS CI | Eleven `*_native_ui_test.dart` files plus three explicitly registered tests passed (14 files total). |
| Styio parser-backed language fixtures | `test` stage using the pinned Styio executable | The declared fixture roots passed. Missing tools trigger pinned provisioning; invalid explicit overrides or failed provisioning fail the stage. This does not prove every language feature or the real product matrix. |
| Permanent Prototype checks | `test` stage; `npm run governance` and `npm run selftest:editor` | The permanent independent Prototype asset's checks passed; they do not replace Flutter behavior or release evidence. |

The integration-runner tests inventory all 21 maintained app integration files against executable selectors and globs. Windows currently has no Windows-target app native integration suite; its portable test, package, install, startup, and build results are separate evidence. The real Pafio/Styio product matrix runs on every configured CI platform and on an explicit local `VITYO_PRODUCT_GATE=1` request; the shared resolver provisions Pafio only for this matrix and resolves Styio through the same pinned source workflow used by parser-backed fixtures.

The canonical CI workflow calls the same Python pipeline with its resolved event range, platform, and isolated installation root. The standalone coverage workflow may evaluate coverage directly; coverage percentages prove only their configured source scope.

## Final Regression And Repair

Run `python3 scripts/vityo.py deliver` once after all writing, source review, in-scope repairs, and focused verification are complete. It ends after launch; do not add a duplicate full-regression run before or after it. Reuse earlier focused passing evidence only when all inputs to that check remain unchanged.

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
