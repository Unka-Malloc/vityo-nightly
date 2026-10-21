# Vityo delivery programme

**Purpose:** Own current milestone sequencing and acceptance without duplicating product contracts.

**Last updated:** 2026-10-11

[Programme.json](Programme.json) is the current delivery index. [Requirements.json](Requirements.json) owns requirement identity. The sole elaborated milestone is [task-resource-delivery/Tree.json](task-resource-delivery/Tree.json); its split Task and Node files own pending execution state. Future deliveries are outlines, not authorization. No build, repair, engineering check or Agent run is claimed by this preparation.

## Current milestone

Build current working sources → reproduce/classify the finite issue list → repair supported behavior → review and exchange candidates → run the real ecosystem scenario → perform one final applicable regression → independent requirement closure. Research is attached to the relevant repair or cost node and must produce an implementable decision or explicitly reject an unhelpful optimization.

The historical task-history report is an unconfirmed lead for the new build. Styio owns creation-time capture, nested pending-write commit ownership and explicit task ordering. Pafio owns current identity/diagnostic/receipt and offline-workflow correctness. Vityo owns production service consumption and same-project result transitions. Ordinary scoped bugs are repaired; only a genuine unresolved contract decision pauses its dependent branch. An affected supported feature left broken prevents milestone completion.

## Cross-repository handoff

The integration coordinator selects source-built candidates from the three working trees, including local changes. Record source revision, changed paths, commands and executable locations privately; do not replace them with pinned upstream caches. Configure `STYIO_BIN`, `PAFIO_BIN`, `PAFIO_ROOT` and `VITYO_PRODUCT_PLATFORM` outside the repository. There is no cross-repository `after` edge: external handoffs are coordinator-enforced preconditions, not native scheduler guarantees.

Styio repair/source review → Pafio real workflow repair/source review → Vityo real production-path integration. Independent baseline work may proceed separately with one writer per repository. Candidate handoff may precede Task/Tree delivery. All three final-regression nodes wait for the common E2E pass; each closing Reviewer reconciles its own repository, and the coordinator alone joins their final results and closes source/hosted Tasks and Trees. Do not wait inside an Agent turn for sibling final nodes sharing the Agent lease. Never wait for an upstream whole Tree to finish before accepting its reviewed candidate: that would create a cycle with final integration.

## Checks and truthful completion

`bash docs/plans/task-resource-delivery/checks.sh baseline|focused|integration|final|review` is the executable check surface. Baseline builds; focused checks protect changed behavior; integration consumes real candidate binaries; final runs the existing complete engineering entrypoint; review checks patch hygiene only, not semantic correctness. Commands must run from this repository. The current desktop build baseline targets macOS; other claimed platforms need their owner build/test evidence.

Each Node explicitly names its registered check IDs. The automation service defaults an omitted selection to all project checks, so the Designer must retain the per-node selection. Do not run full regression at every Node. Existing gate coverage must be extended in the repair node where the acceptance table below identifies new assertions. A gate passing before those assertions exist does not satisfy the outcome. Framework projection and requirement references are navigation, not proof.

| Case | Owner and required assertion |
| --- | --- |
| Current source | All three: selected working tree, build configuration, actual executable and finite issue ledger |
| History isolation | Styio: commit 7, create task, parent commits 9, await → parent 9/task 7; add wraparound, alias, repeated-read and lifetime variants in permanent tests |
| Stage/order | Styio: nested pending writes commit at the contract-defined owner boundary; explicit order executes or reports the existing supported diagnostic; document any genuine contract conflict |
| Failure | Styio/Pafio/Vityo: task failure with and without fallback settles at the correct use site; do not claim external I/O rollback |
| Current results | Pafio/Vityo: successful build → compile error → repaired success; diagnostics and receipts belong to the current source/invocation; old success cannot mask failure |
| Product integration | Vityo: edit/save/diagnostics/check/build/test/run through actual product services and daemon, with real source-built CLIs and the shared task/resource project |
| Preservation | Existing language, package/offline and IDE behavior; observe-off works; Prototype source, entrypoints, governance and tests remain |
| Cost | Styio: correct baseline, capacity/reference/task scaling, time/memory/copy/allocation evidence; no promised speedup without evidence |

Future work remains outlined in Programme.json. Historical `docs/plan/` records retain their evidence; they do not compete with this current milestone. Product specifications, ADRs and the gap ledger remain authoritative for semantics. Real Agent tasks, installed-client/live acceptance, release and publication are separate assigned operations.

## Parallel execution and milestone integrity

Future outlines are not ready-to-run work. An empty requires list does not establish safe concurrency: elaborate actual dependencies and exclusive write ownership first. The current three repository baselines may run concurrently; upstream-dependent checks wait for reviewed handoffs. Keep one source writer per repository for this milestone. Different repositories may run final regressions concurrently only after the common E2E join and source review, without competing source edits.

Each delivered milestone leaves the integrated product buildable and usable, preserves every previously supported capability in the declared support scope, and delivers the selected new behavior end to end. Complete all affected producers, consumers, entrypoints, contracts and tests together. A partial migration, disabled existing feature, temporary broken interface or deferred required wiring is not a delivered milestone. Preserve independently retained assets and user data.

Baseline work records the existing supported-capability/platform inventory and its test coverage. Reviewer closure reconciles that inventory with actual results; a few passing focused tests do not establish complete product usability. The milestone covers existing supported behavior plus its selected change, not every future language or product aspiration. Unverified platforms and separately assigned live acceptance remain explicit. Intermediate Nodes and candidate handoffs may precede final completion, but they cannot be presented as usable milestone delivery.

The current [baseline inventory](task-resource-delivery/BASELINE.md) maps owner
contracts to existing tests and the finite repair ledger. Its
[handoff](task-resource-delivery/HANDOFF.md) separates input preparation from the
registered host build result. The baseline helper retains raw provenance and
per-command logs/exits only under ignored `build/task-resource-baseline/`;
`--prepare-only` never executes the build. The registered baseline remains the
single host build entrypoint.
