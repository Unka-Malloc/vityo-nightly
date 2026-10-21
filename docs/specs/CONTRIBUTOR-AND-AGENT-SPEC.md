# Contributor And Agent Workflow

**Purpose:** Define how repository changes map requirements to owned code, deterministic tests, CI, review, and separately authorized acceptance.

**Last updated:** 2026-10-02

## Authority And Repository Boundaries

The current user request and applicable project requirements define scope and authorization. This document describes the normal repository workflow; it does not authorize publication, installation, application launch, or a live Agent task.

Vityo is the only product in this repository. `products/vityo_app/` owns the IDE and its shared source/workspace state, IDE-side transactions, language adapters, and visual projections. `products/vityo_coding_agent/` owns the companion Agent runtime and its tool policy, interaction loop, and durable sessions. `packages/vityo_agent_protocol/` owns the shared wire contract and contains no runtime implementation. Styio owns language syntax and semantics; Pafio owns project and target metadata. See [the system architecture](../design/Vityo-System-Architecture.md) and [the repository map](./REPOSITORY-MAP.md).

For Flow Hero, Styio source and its revision remain authoritative. The graph is an editable projection whose semantic edits become source transactions; layout positions are presentation state. The chosen Agent target is ReAct with an optional revisable task plan inside the same loop. The current production wiring and deferred product behavior are recorded in [ADR-0020](../adr/ADR-0020-source-authoritative-flow-hero.md), [ADR-0021](../adr/ADR-0021-react-agent-runtime-loop.md), and [the implementation gaps](../design/Vityo-Implementation-Gaps.md). These decisions do not establish that the feature or a model-driven coding Agent is implemented.

`prototype/` is a permanent independent source asset. Its source, entrypoints, dependency governance, and tests must be preserved through product consolidation or cleanup. Its current implementation and release status remain separate product facts.

Compatibility obligations attach to genuinely published interfaces, data, and documented external dependencies. A commit, schema number, local build, or installation does not by itself create a release obligation. Correct unpublished code, tests, schemas, or documents directly with their producers and consumers; do not keep adapters or migration steps solely to preserve an unpublished mistake. Preserve user data independently from code correction.

## Change Workflow

1. Check `git status --short`, identify the smallest independently reviewable user behavior, and read the current owner documents and source implementation. Treat unrelated dirty files as concurrent work.
2. Trace the actual producer, consumers, state transitions, public or internal contracts, and recovery behavior affected by the change. Update those producers and consumers together; do not implement against a stale plan or an assumed source path.
3. Add deterministic unit, contract, or integration coverage against the real implementation. Keep mocks at external boundaries. Tests for parsing, transactions, scheduling, persistence, state transitions, and recovery must exercise those implementations directly.
4. Put ordinary tests in an established auto-discovered test root. If a new package or standalone suite is outside those roots, connect its executable command to the canonical functional-test runner in the same change. The test and its CI wiring are one deliverable. Do not duplicate the runner's suite registry in this document; [the test catalog](../assets/workflow/TEST-CATALOG.md) describes current ownership and future requirements.
5. Run the focused tests and checks for the touched owners while implementing. Review the resulting source and test diffs, repair ordinary in-scope defects, and refresh affected owner documents and generated indexes.
6. After all writers have stopped, source review is complete, and in-scope repairs and focused verification are done, run the applicable full local regression once. A failure is evidence to diagnose: fix ordinary defects within scope, verify the repair, then rerun the affected final checks. Pause only work requiring a new product, published-contract, risk, or authorization decision; continue independent work.
7. Report what was tested and where. Label local results, configured but unobserved Actions or platform lanes, and live acceptance separately. A plan, test declaration, CI configuration, or capability flag is not evidence that its behavior passed.

## Test And Acceptance Rules

- Every changed user-facing behavior has a deterministic test in the same change, unless it depends on an external provider or real environment that cannot be represented locally. In that case, test the local contracts, state transitions, and failure handling deterministically, and state which remaining claim needs the separately assigned acceptance run.
- A new test under an established root is included through that root's normal discovery. A standalone integration or platform test must have a runnable suite entry and a CI lane appropriate to its prerequisites. Missing commands, skipped suites, ignored nonzero exits, and missing files must fail the registered check rather than be recorded as successful coverage.
- Test the actual parser, transaction coordinator, protocol adapter, scheduler, persistence, and recovery implementation. Mock provider/network/filesystem boundaries where needed; do not replace the behavior under test with a demonstration conversation.
- Do not start a real Agent conversation, provider task, or user development task as a substitute for engineering tests. Real Agent acceptance is performed later by the user's designated Agent on an explicit task.
- Platform build/package evidence proves only the configured platform operation. Permission to install or open a client does not authorize Computer Use, reading the live interface, or testing user scenarios.
- Preserve deterministic test fixtures and generated evidence privacy. Do not write workstation identity, private paths, credentials, or backend runtime payloads into source, reports, screenshots, or logs.

## Documentation And Review

| Change | Update with the implementation |
|---|---|
| User behavior or interaction | Product specification, current owner design, implementation-gap status when applicable, and test catalog |
| Architecture boundary or source of truth | System architecture and an ADR when a durable boundary or decision changes |
| Agent protocol or workspace contract | Its owner contract and every in-scope producer and consumer |
| Dependency | `docs/specs/THIRD-PARTY.md` and any affected decision or setup instructions |
| Team ownership, review route, or recovery procedure | The affected `docs/teams/` runbooks and coordination runbook |
| Test runner, suite root, or CI gate | The runner, focused runner tests, catalog, CI workflow, and contributor commands |

New technical documentation is written in English. Add `Purpose` and `Last updated` metadata to new owner documents, update affected `README.md` files, and regenerate generated `INDEX.md` files during integrated delivery.

Human review follows the owning contracts. For changes to source projection or graph transactions, review Styio syntax and semantics, source revision handling, transaction rejection/undo, and the IDE/runtime boundary. For Agent changes, review permission, proposed-versus-applied state, protocol ordering, persistence, and verification receipts. Future Flow Hero acceptance cases are enumerated in the test catalog.

## Planning, Observation, And Delivery

Use ordinary repository workflow for routine investigation, documentation, and bounded fixes. Use the installed planning workflow only when the task calls for it; `docs/plan/` is an entrypoint and history location, not a mandatory or authoritative in-repository planning state. Follow [the execution runbook](../plan/EXECUTION-RUNBOOK.md) for task boundaries and [the verification and CI spec](./POST-COMMIT-CI-CHECKS.md) for local and remote evidence.

When delegating, do not use fast mode. Treat at least a 10-minute window for ordinary work and 30 minutes for large work as progress checkpoints, not cancellation deadlines. Use the host's own completion notification: start the work and let its completion arrive instead of splitting the window into repeated waits; only a host that cannot notify needs bounded waits, and each expiry must carry a progress update. An elapsed window or completed wait does not prove cancellation, failure, or completion. Continue observing or report the unresolved status and recovery path. Do not add arbitrary timeouts to long-running product behavior.

Commits, pushes, pull requests, merges, and releases follow the task's explicit authority and the repository's [branch and pull request rules](../../AGENTS.md). Local CI success alone does not authorize publication. For an authorized push, observe required CI for the exact pushed commit and report pending or unobservable checks as incomplete verification.
