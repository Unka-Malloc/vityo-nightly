# Contributing To Vityo Nightly

**Purpose:** Give contributors a direct path from the owned requirement to implementation, tests, CI, source review, and delivery evidence.

**Last updated:** 2026-10-02

## Start Here

Vityo nightly is the downstream integration repository. Before editing, inspect `git status --short`, read the owning product and team documents, and preserve unrelated work in the shared checkout. Keep each change scoped to one independently reviewable behavior and update affected producers, consumers, and tests together.

Start with the [contributor and Agent workflow](docs/specs/CONTRIBUTOR-AND-AGENT-SPEC.md) and [team coordination runbook](docs/teams/COORDINATION-RUNBOOK.md).

## Ownership And Architecture

1. System boundaries: [Vityo System Architecture](docs/design/Vityo-System-Architecture.md) and [Repository Map](docs/specs/REPOSITORY-MAP.md).
2. Product behavior and accepted gaps: [Product Spec](docs/design/Vityo-Product-Spec.md) and [Implementation Gaps](docs/design/Vityo-Implementation-Gaps.md).
3. Runtime and Agent client: [Runtime / Agent runbook](docs/teams/RUNTIME-AGENT-RUNBOOK.md) and [Agent runtime runbook](docs/teams/AGENT-RUNTIME-RUNBOOK.md).
4. Contracts and upstream handoff: [Adapter / Contracts runbook](docs/teams/ADAPTER-CONTRACTS-RUNBOOK.md).
5. Module and platform: [Module / Platform runbook](docs/teams/MODULE-PLATFORM-RUNBOOK.md).
6. Docs, tests, and delivery: [Docs / Delivery runbook](docs/teams/DOCS-DELIVERY-RUNBOOK.md) and [Test Catalog](docs/assets/workflow/TEST-CATALOG.md).
7. Governance and release: [Governance entrypoint](docs/governance/README.md) and [Release Checklist](docs/governance/RELEASE-CHECKLIST.md).

The architecture gate protects these directions: `lib/src/view_ide/` owns presentation-independent IDE services and contracts; `lib/src/ide/` owns editor, document/workspace, Agent Client, and collaboration state; `lib/src/app/` composes shared services; and `lib/src/view_render/` owns Flutter presentation. Presentation may import only narrow registered public model, adapter, or projection files from their actual owners, not arbitrary implementation files. Removed top-level roots are not compatibility surfaces. See the release checklist and `scripts/check_architecture_boundaries.py` for current registrations.

The shared product boundaries remain: `products/vityo_app/` is the IDE, `products/vityo_coding_agent/` is the companion runtime, and `packages/vityo_agent_protocol/` is the runtime-neutral shared protocol and Dart client binding. The Coding Agent's Rust migration is in progress; the Dart implementation remains current until the Rust runtime and IDE consumer path have complete deterministic coverage. The IDE does not import Agent runtime implementation or connect directly to a model provider.

## Implementation And Test Workflow

1. Trace the requirement through actual source, current owner contracts, affected callers, state changes, persistence, and recovery. Resolve source and contract discrepancies in the same change.
2. Add deterministic unit, contract, or integration coverage for changed behavior. Test production parsers, transactions, scheduling, protocol adapters, persistence, and recovery; mock only external service boundaries.
3. Place ordinary tests under an established auto-discovered root. A new standalone test suite must add a runnable command to the canonical CI suite registry in the same change. Do not leave an executable test as an unregistered script or duplicate its suite mapping in another document.
4. Run focused checks for the changed owner while implementing. Then review the source and test diffs and repair ordinary in-scope issues.
5. After all writers stop, source review and focused repairs finish, run `python3 scripts/vityo.py deliver` once. If it finds an ordinary scoped defect, repair it and rerun the affected stage, then complete the reviewed delivery on the repaired candidate. See [Verification And CI](docs/specs/POST-COMMIT-CI-CHECKS.md) for the stage boundaries and CI evidence limits.
6. Report the exact local checks and test suites run. Report configured but unobserved Actions or host lanes as unverified.

Use the pinned toolchain from [Build And Development Environment](docs/BUILD-AND-DEV-ENV.md).
The canonical local delivery path runs privacy, architecture and documentation checks, deterministic
tests, coverage evaluation, release build/package, per-user installation, and client launch in order:

```bash
python3 scripts/vityo.py deliver
```

The stages can be run independently for focused repair:

```bash
python3 scripts/vityo.py privacy
python3 scripts/vityo.py architecture
python3 scripts/vityo.py test
python3 scripts/vityo.py coverage
python3 scripts/vityo.py build
python3 scripts/vityo.py install
python3 scripts/vityo.py launch
```

`test` collects Python and Flutter coverage and runs instrumented locked Cargo tests for the Coding
Agent and `vityod`, along with the registered Agent/IDE fixture suites, retained Prototype checks,
and pinned Styio language fixtures. The current Agent behavior suite still exercises the Dart
runtime; Rust test coverage does not by itself establish production cutover or IDE consumer wiring.
The test stage prepares the exact pinned Styio toolchain when no matching executable is available;
an invalid explicit override or failed build fails the stage. It never uses an unpinned fallback.
The optional real Pafio/Styio product matrix runs in CI and when `VITYO_PRODUCT_GATE=1` is set.

`coverage` evaluates the Python, Flutter, Coding Agent, and daemon reports collected by `test`;
it does not rerun tests. Rust reports remain separate by product and have no default percentage
floor. For a documentation-only change, run `privacy` and `architecture`, then let the final repository delivery perform the full
reviewed regression. Do not claim test or coverage evidence from those focused stages.

Local `install` uses the platform's per-user destination and verifies that the package contains both
the client and companion executable. `launch` opens the installed candidate and ends the engineering
workflow. It does not authorize UI inspection, a real Agent/provider task, or live user acceptance.
Consult the [test catalog](docs/assets/workflow/TEST-CATALOG.md) and
[Verification And CI](docs/specs/POST-COMMIT-CI-CHECKS.md) for suite reach and evidence limits.

For focused checks, use the relevant package-native test runner and applicable checks below. These focused commands complement the canonical integrated entrypoints; they do not replace final regression for a code change.

```bash
python3 scripts/check_architecture_boundaries.py
python3 scripts/check_product_line_boundaries.py
python3 scripts/check_security_baseline.py
python3 scripts/check_performance_budgets.py
git diff --check
```

## Compatibility And Dependencies

Compatibility promises apply to published interfaces, user data, and external dependencies according to their documented support requirements. A commit, schema number, local build, or local install does not by itself establish a release. Correct unpublished internal contracts directly with their producers and consumers; do not retain a compatibility adapter or migration only to preserve an unpublished mistake. Preserve user data independently from code changes.

For a genuinely published public surface, follow [API Compatibility](docs/governance/API-COMPATIBILITY.md). Update `docs/specs/THIRD-PARTY.md` with a dependency change and record any durable architecture decision in the owner document and ADR.

## Security, Privacy, And Performance

Security changes follow [Security And Supply Chain](docs/governance/SECURITY-AND-SUPPLY-CHAIN.md). Test authorization and rejection behavior through the real policy and transaction implementation. Editor, language, workspace, runtime, Agent context, watcher, and virtualization changes must review the applicable static budget and, where required, benchmark evidence.

Never put workstation identifiers or paths, credentials, private backend runtime payloads, or raw private logs in repository documents, CI artifacts, screenshots, or handoffs. Keep test fixtures synthetic and reports redacted.

## Documentation And Pull Requests

Update the owner documents with changes to behavior, architecture, ownership, security, compatibility, release gates, or local test/CI commands. New technical documentation is English by default. After a docs-tree change, refresh generated indexes as part of integrated delivery and validate them with the docs gate.

Use the [pull request template](.github/pull_request_template.md) when an authorized PR is created. Record the behavior, owner surfaces, implementation and contract updates, actual tests and CI registration, and any unresolved platform or external acceptance. A CI configuration or a plan alone is not proof that its tests passed.

Branch, commit, push, pull request, and release operations must follow the task's explicit authority and the [repository branch rules](AGENTS.md).
