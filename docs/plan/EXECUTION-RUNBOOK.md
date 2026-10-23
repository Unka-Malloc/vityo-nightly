# Vityo Execution Runbook

**Purpose:** Route authorized Vityo work through current product contracts, executable tests, source review, and truthful delivery evidence.

**Last updated:** 2026-10-02

## Authority And Scope

The current user request and its existing approvals define the scope and authority for a task. A request to review or edit a plan authorizes only that planning work. A pending item, historical delivery, or the existence of `docs/plan/` does not authorize implementation, regression, or publication.

Use ordinary repository workflow for routine investigation, documentation, and bounded fixes. A planning tool is not a prerequisite for implementation. When a task explicitly uses a planning workflow, follow its currently installed instructions and configured workspace; this runbook does not copy tool lifecycle commands or state formats.

Resolve discoverable facts and ordinary in-scope defects directly. Report material findings without treating every report as an approval request. If work needs a new product decision, published-contract change, risk allowance, or explicitly required approval, first prepare the concrete proposal from available evidence. Pause only dependent work and continue independent authorized work.

## Implementation And Focused Verification

1. Identify the smallest independently acceptable behavior, current owner, affected callers, producers, consumers, contracts, state transitions, and recovery behavior. Inspect actual source and contracts; a missing planned path does not by itself block unrelated work or justify a parallel implementation.
2. Implement the complete behavior for the authorized scope. Keep producers and consumers in step, retain the established IDE/runtime and public protocol boundaries, and correct unpublished internal mistakes without adding compatibility layers solely for those mistakes.
3. Add deterministic unit, contract, or integration coverage against the implementation. Keep mocks at external boundaries. DSL parsing, state transitions, scheduling, persistence, permission handling, and recovery are engineering tests; a conversation with a real Agent is not a substitute.
4. Put ordinary tests under established auto-discovered roots. If a test requires a standalone runner, add its executable suite entry and CI connection in the same change. Consult [the test catalog](../assets/workflow/TEST-CATALOG.md) for current suite ownership and future Flow Hero requirements.
5. Run focused tests and checks for changed owners during implementation. Review the source and test diffs, repair ordinary in-scope defects, and update the owner docs, catalogs, and generated indexes affected by the change.
6. Preserve concurrent changes. Before editing, inspect `git status --short`; do not revert, overwrite, stage, or reorder unrelated work.
7. Keep evidence privacy-safe and repository-relative. Do not record workstation identity, personal paths, credentials, backend runtime payloads, or raw private logs in source or reports.

## Final Regression And Handoff

After all writers have stopped, source review and in-scope repairs are complete, and focused verification passes, run the applicable integrated local regression once. Use [the verification and CI spec](../specs/POST-COMMIT-CI-CHECKS.md) for the current canonical entrypoints and the limits of each check.

If regression finds an ordinary in-scope defect, repair it directly, run the affected focused checks, and repeat the final checks needed to establish the repaired revision. A regression failure alone does not require a new user decision. Escalate only a requirement that changes scope, a published contract, a risk boundary, or required authority; pause only the work that depends on that decision.

Report the delivered behavior, commands actually run, test roots and suites covered, and any unresolved checks. Keep local results distinct from configured but unobserved GitHub Actions or platform lanes. A queued, unavailable, or unobserved check is unresolved, not passing.

Platform package/build evidence does not establish live product behavior. Installation or client launch does not authorize Computer Use, reading the live interface, or testing a real user scenario. Real Agent conversations and development tasks belong to the user's designated Agent on an explicit task. Do not start that workflow to complete repository engineering work.

## Planning And Observation

`docs/plan/` is a repository entrypoint and document location, not a mandatory or authoritative in-repository planning state. Active state for an installed planning tool follows its configured workspace. No planning state or evidence grants implementation, publication, installation, launch, or live-acceptance authority beyond the current user request.

For delegated work, do not use fast mode. Treat at least a 10-minute window for ordinary work and 30 minutes for large work as progress checkpoints, never cancellation deadlines. Use the host's own completion notification: start the work and let its completion arrive instead of splitting the window into repeated waits; only a host that cannot notify needs bounded waits, and each expiry must carry a progress update. Continue observing or report the exact unresolved state and recovery path. Do not add arbitrary timeouts to product behavior. See the [contributor workflow](../specs/CONTRIBUTOR-AND-AGENT-SPEC.md) for the full delivery boundary.
