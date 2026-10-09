# Docs / Delivery Runbook

**Purpose:** Define the daily maintenance workflow for Vityo documentation, repository hygiene, test ownership, and delivery records.

**Last updated:** 2026-10-09

## Mission

负责 docs 树结构、README/INDEX 接线、里程碑与 history 记录、review 队列和 repo hygiene 文档纪律。该团队不替 feature owner 决定产品语义或合同内容，但负责确保这些内容被放在正确的 owner 文档里。

## Owned Surface

Primary paths:

1. `README.md`
2. `docs/`
3. `docs/external/`
4. `scripts/repo-hygiene-gate.py` — updated 2026-06-25: added `cache` language submodule, registered `cache/cache.dart` in canonical language barrel
5. `scripts/docs-index.py`
6. `scripts/docs-lifecycle.py`
7. `scripts/docs-audit.py`
8. `scripts/team-docs-gate.py`
9. `scripts/docs-gate.sh`
10. `scripts/vityo.py` — canonical privacy, architecture, test, coverage, build, install, and launch pipeline
11. `.github/workflows/project-coverage-gate.yml`
12. `scripts/project-coverage-gate.py`
13. `scripts/python-coverage-gate.py`
14. `scripts/bootstrap-dev-env.sh`
15. `scripts/bootstrap-dev-container.sh`
16. `scripts/bootstrap-dev-env-macos.sh`
17. `scripts/bootstrap-dev-env-windows.ps1`
18. `scripts/bootstrap-workspace.sh`
19. `scripts/bootstrap-workspace.ps1`
20. `scripts/android-sdk-profile.sh`
21. `scripts/android-sdk-profile.ps1`
22. `scripts/apple-platform-profile.sh`
23. `scripts/verify-android-device.sh`
24. `scripts/verify-android-device.ps1`
25. `scripts/verify-apple-device.sh`
26. `docker/`
27. `.devcontainer/`
28. `toolchain/android-sdk-profiles.csv`
29. `toolchain/apple-platform-profiles.csv`
30. `prototype/README.md`
31. `products/vityo_app/README.md`
32. `scripts/check_architecture_boundaries.py`
33. `scripts/public-contract-schema-gate.py`
34. `docs/governance/CODEOWNERS-POLICY.md`
35. `docs/rollups/nightly-subbranch-merge-report-20260624.md`
36. `CONTRIBUTING.md`
37. `SECURITY.md`
38. `.github/pull_request_template.md`
39. `docs/governance/`
40. `scripts/ecosystem-product-gate.py`

Key SSOTs:

1. `文档策略 -> ../specs/DOCUMENTATION-POLICY.md`
2. `人机协作规范 -> ../specs/CONTRIBUTOR-AND-AGENT-SPEC.md`
3. `测试目录 -> ../assets/workflow/TEST-CATALOG.md`
4. `文档策略 -> ../specs/DOCUMENTATION-POLICY.md`
5. `当前状态摘要 -> ../rollups/CURRENT-STATE.md`
6. `外部审计入口 -> ../audit/README.md`
7. `活跃缺口登记 -> ../design/Vityo-Implementation-Gaps.md`
8. `IDE 标杆能力矩阵 -> ../design/Vityo-IDE-Benchmark-Matrix.md`
9. `IDE 能力成熟度模型 -> ../design/Vityo-IDE-Capability-Maturity.md`

The ecosystem owner split is documented once across `for-pafio/`,
`for-styio/`, and `for-platform/`; active rollups and release checklists must
not revive removed compiler-management or repository-hosted control-plane
claims.
10. `IDE 交互质量基线 -> ../design/Vityo-IDE-Interaction-Quality-Bar.md`
11. `IDE 能力基线 JSON -> ../../toolchain/vityo-ide-capability-baseline.json`
12. `IDE 产品对标门禁 -> ../../scripts/ide-product-parity-gate.py`
13. `架构边界门禁 -> ../../scripts/check_architecture_boundaries.py`
14. `公共合同 schema 门禁 -> ../../scripts/public-contract-schema-gate.py`
15. `CODEOWNERS 治理策略 -> ../../docs/governance/CODEOWNERS-POLICY.md`
16. `已实现决策摘要 -> ../adr/IMPLEMENTED-DECISIONS.md`

## Daily Workflow

Native backpressure fixtures must first pass the real protocol frame encoder.
Keep the outer socket fixture within the existing control-payload maximum and
retain oversized-frame rejection; do not raise protocol limits to make a test run.


When a native regression reports an impossible zero error after failed I/O,
check first-use FFI resolution before weakening assertions. Keep the original
failure evidence and require a live reader before the peer-disconnect scenario.


Keep raw Windows API diagnosis, portable request-lifetime tests and bounded real
Dart transport results distinct. The latter verifies the candidate transport's
native completion/close behavior but still does not replace complete delivery.


Keep bounded Windows pipe collection documented in the build/dev-environment
owner and test catalog. Its raw API observations and supervisor tests do not
replace full Windows delivery or prove native transport cancellation.


For local daemon request-lifetime maintenance, keep the deadline and retired-reply
rules in [Protocol and Capability Negotiation](../design/Vityo-Protocol-And-Capability-Negotiation.md)
and map portable regression evidence in the [test catalog](../assets/workflow/TEST-CATALOG.md).
Do not turn those client tests into a claim of native Windows cancellation or startup.


Keep macOS CocoaPods at the CI-verified `1.17.0` version and commit regenerated
`Podfile.lock` and Runner project metadata when the Flutter plugin graph changes.
Use observed native generation diffs; preserve product-matrix clean-checkout
failures rather than restoring or ignoring dirty metadata.

The Prototype editor smoke test names browser resolution, server readiness, browser launch,
and page creation as separate steps. Startup failures clean up owned resources; screenshot
capture is best-effort and reports whether an artifact was actually saved. The macOS CI
lane enables `DEBUG=pw:browser` to retain browser stderr and process-exit diagnostics.
All three delivery lanes select the single `VITYO_CI_CHROME_VERSION` workflow pin;
the launched browser must match it. Keep the published Chrome for Testing pairing
separate from the local distribution `.chromium-version` and verify host tests
before claiming the startup failure is resolved.


For local toolchain delivery, distinguish explicit-path selection, Pafio compiler-contract
evidence, and release certification. Keep the Run/Test receipt rejection cases in the
auto-discovered Flutter test root; report native Pafio tests and isolated client
launch separately from real macOS UI acceptance.

The shared test stage runs actual pinned language fixtures between the portable IDE
suites and prototype checks, and stops on failure. Python coverage dependencies belong
in the isolated environment documented in `docs/BUILD-AND-DEV-ENV.md`. Local macOS
launch opens a new instance of the installed candidate and checks LaunchServices' exit
status; it does not inspect the running interface or claim live acceptance.
macOS CI instead supervises the installed executable with the existing candidate-bound
first-frame probe. Its 120-second startup deadline fails closed, then terminates and
reaps only the owned PID (five-second grace before kill). The bounded, redacted
`startup-macos-diagnostics.json` is uploaded alongside startup evidence. Keep exit-zero
without fresh evidence, stale/wrong/malformed evidence, crash, timeout, kill/reap,
argument preservation, and output limits covered in the auto-discovered Python tests.
A supervisor repair is not proof a native startup failure is resolved; require a
successful native delivery rerun and keep live UI acceptance separate.


1. 先判断当前变化属于 owner 文档变化，还是目录/索引/交付接线变化。
2. 任何结构性文档变更，都要同步更新对应目录的 `README.md` 和 `INDEX.md`。
3. 若一次变更改变了团队边界、review 路由或 handoff 路径，同批更新 `docs/teams/`。
4. 中断时把恢复信息写入 `docs/history/<topic>.md`，并在正文记录日期；不要只留在聊天或注释里。
5. docs tree 变化时，同批运行 `docs-lifecycle.py`、`docs-index.py`、`docs-audit.py`，而不是只靠 `README/INDEX` 手工刷新；生成式 `INDEX.md` 必须保持跨本地和 GitHub Actions 可复现，空 collection 继承本目录 `README.md` 的 `Last updated`，不得回退到执行当天日期。
6. 根 `.gitignore` 若新增 temp/build/log/cache 类忽略规则，同批补 `docs/**` 与 `products/vityo_app/test/**` 的显式 negate 规则，并让 `scripts/repo-hygiene-gate.py` 通过。
7. 仓库级 build/dev-env 文档必须保持固定版本基线显式一致：Debian 13、Python 3.13.5、Node.js v24.15.0 LTS、Flutter 3.41.7 / Dart 3.11.5、Chromium 147.0.7727.116；不得把这类版本描述回退成浮动 `stable`。
8. 容器和宿主机开发环境入口必须一起维护：`Dockerfile`、`.devcontainer/`、Linux/macOS/Windows 一键安装脚本，以及可选 `+android` / `+ios` 组合矩阵，都要在仓库级 build/dev-env 入口里保持同一套说明。
9. Linux Android 工具链是 profile 驱动：`toolchain/android-sdk-profiles.csv`、`scripts/android-sdk-profile.sh`、Linux bootstrap、容器镜像和仓库级 build/dev-env 文档必须同步更新；不得只改单一脚本里的 `android-36` 字面量。
10. Windows Android profile 入口和 macOS Apple profile 入口必须与 Linux 规则同步：`scripts/android-sdk-profile.ps1`、`scripts/apple-platform-profile.sh`、`toolchain/apple-platform-profiles.csv`、macOS/Windows bootstrap 与仓库级 build/dev-env 文档要一起维护，不能只更新单一平台脚本。
11. 真实设备验证入口也属于交付表面：Android bash/PowerShell 验证脚本和 Apple 设备验证脚本必须与 profile CSV、bootstrap、仓库级 build/dev-env 文档同步更新，不能单独漂移。
12. 根 `README.md` 只保留仓库级一跳入口；多平台 bootstrap、profile 切换和真实设备验证的细节统一收在 `docs/BUILD-AND-DEV-ENV.md`，不要在 README、runbook 和子系统文档里各自维护平行说明。
13. 新增 external audit、agent findings、contract package 或 toolchain handoff 时，同批刷新 collection `README.md` / `INDEX.md`，并确保缺口被路由到 owner runbook，而不是停留在审计摘要里。
14. Select verification for the current change from [Post-Commit CI Checks](../specs/POST-COMMIT-CI-CHECKS.md); a documentation-only closure does not require unrelated Flutter or cross-repository product suites. Preserve explicitly required product and release checks and reuse unchanged passing evidence.
15. Keep [../specs/POST-COMMIT-CI-CHECKS.md](../specs/POST-COMMIT-CI-CHECKS.md) aligned with actual GitHub Actions monitoring practice whenever commit, push, or CI handoff rules change.
    Keep [the execution runbook](../plan/EXECUTION-RUNBOOK.md) limited to Vityo's authority and verification boundaries. Lifecycle commands, state formats, and recovery operations belong to the active installed planning skill; do not restore retired command recipes here.
16. 外部上游 handoff 统一收在 `docs/external/for-*`，不要在 docs 根目录重新创建 `for-*` collection。
17. Keep [../specs/TECHNOLOGY-COMPONENT-INVENTORY.md](../specs/TECHNOLOGY-COMPONENT-INVENTORY.md) aligned with `styio-audit` whenever the technology stack, internal components, open-source components, dependency manifests, Apache-2.0 evidence, commercial-risk boundaries, or UI asset-source evidence changes.
18. Maintain GitHub merge gates through Rulesets rather than legacy classic branch protection; audit effective branch rules when required status-check governance changes.
19. External audit shard updates must name the remediated finding, the changed security boundary, and the exact validation command; if code and audit evidence move together, update the owning team runbook in the same change.
20. The ecosystem CLI doc gate (`scripts/ecosystem-cli-doc-gate.py`) remains part of the documented architecture stage; its cross-repository severity is defined by the docs gate, not by an alternate delivery mode.
21. Keep [the delivery pipeline](../assets/workflow/DELIVERY-GATE.md), [test and coverage map](../assets/workflow/CHECKPOINT-HEALTH.md), and [test catalog](../assets/workflow/TEST-CATALOG.md) aligned with the actual `scripts/vityo.py` stage registry. `test` collects Python and Flutter reports and instrumented Rust reports for both workspaces once; `coverage` evaluates them without rerunning suites. Rust reports require executed source coverage, with mapped requirement-module coverage for the Agent report, and have no default percentage floor. Styio fixtures are required; the resolver provisions the pinned tool when needed, while invalid explicit overrides or failed provisioning fail the stage.
21. Language-service ADR or contract updates must refresh both the owning contract runbook and generated docs indexes in the same worktree pass; do not rely on passing Flutter tests as evidence that docs ownership is closed.
22. Docs tree structure, milestone files, prototype manifest entries, and fixture paths must be organized by content or functional effect. Version strings, dates, and stage numbers may appear as state metadata or external wire values, but must not define repository directories, entry files, task identities, or implementation routing.
23. Governance docs are part of docs delivery. API compatibility, security, release checklist, CODEOWNERS policy, root contribution/security entries, and PR template changes must keep generated docs indexes current.
24. When a new docs collection is added, update `scripts/docs-index.py` collection metadata and run `python3 scripts/docs-index.py --write` in the same change.
    Update generator titles and descriptions when collection ownership changes; generated planning
    indexes must describe repository guidance without restoring retired planning-tool authority.
25. Platform-native CI changes must keep `README.md`, `docs/BUILD-AND-DEV-ENV.md`, `.github/workflows/local-ci-gate.yml`, and bootstrap script comments aligned. The PowerShell workspace bootstrap may create Flutter plugin junctions on Windows to avoid Developer Mode or admin symlink requirements, but it must restore tracked `.metadata` and `pubspec.lock` after runner generation and dependency restore.
26. `docs/plan/` stores repository-owned planning documents and execution guidance when present.
    Active state for an installed planning tool belongs to its configured workspace; the repository
    does not require an in-tree Plan, mirror external state, or infer authority from planning data.
    Keep product facts in their owner documents and do not restore retired local validators.
27. Implemented architectural decisions belong in `docs/adr/IMPLEMENTED-DECISIONS.md` only when they match current code, tests, gates, or owner SSOTs; stale plan residue must be deleted or routed back to active gap/review docs.
28. Repository documentation is English by default. Chinese prose is allowed only when a document's `Purpose` explicitly scopes it as Chinese localization, Chinese translation, or Chinese user-facing product/marketing copy; when touching legacy Chinese prose in non-localized owner docs, convert the touched passage to English.
29. Workspace bootstrap scripts must not leave Flutter template files that are not tracked product tests. When runner generation, Windows LLVM discovery, or platform bootstrap behavior changes, keep bash, PowerShell, and GitHub Actions entry points aligned in the same change.
30. The ecosystem product gate must create its fixture through public `pafio new` and consume only fixed Pafio and Styio executables. It must not import sibling-repository scripts, read private package-manager home state, or depend on a Pafio source checkout.
31. After an atomic refactor, current owner, contract, architecture, security, release, and runbook
    documents must reference only canonical implementation paths. Removed paths and symbols may
    remain only in clearly marked immutable archive or completed-plan provenance; they must not be
    described as compatibility anchors, future work, or active security gates.

## Change Classes

1. Small: 链接修复、索引补全、history 补记或局部文案整理。运行 repo hygiene 和 docs gate。
2. Medium: docs 树结构、`docs/external/` handoff 路径、里程碑映射、测试目录映射、audit/agent findings、archive/rollup lifecycle、contract package、post-push CI checking rules、technology/component inventory、version/date/stage-number organization cleanup 或 handoff 路径变化。同步相关入口文档和 docs 自动化脚本。
3. High: owner 文档迁移、文档策略重构、团队边界调整或交付纪律变化。走协调 review。

## Required Gates

For a documentation-only focused pass, run the two stages that include privacy/repository hygiene and documentation/architecture validation:

```bash
python3 scripts/vityo.py privacy
python3 scripts/vityo.py architecture
```

After all source review and focused repairs are complete, the integrated local delivery is:

```bash
python3 scripts/vityo.py deliver
```

This command stops at the first failing stage. A targeted repair reruns the affected public stage; it does not mark prior failed or unrun stages as passed. The full command ends after launching the installed candidate and does not include live UI inspection or a real Agent task.

## Cross-Team Dependencies

1. 每个 feature 团队都必须 review 会改变其工作流的文档结构变化。
2. Adapter / Contracts 必须 review handoff 和 contract owner 文档的接线变化。
3. Theme / UX 必须 review 会影响 handbook 或视觉基线记录的文档更新。
4. Shell / Editor、Runtime / Agent、Module / Platform 必须各自确认里程碑和测试目录映射没有失真。

## Handoff / Recovery

The process-environment isolation slice distinguishes omitted/null requests from
explicit maps, including empty maps, and keeps discovery context separate from
child launch inputs. Maintain the System Compatibility Manager contract, runtime
provenance notes, and corresponding test-catalog entries together. Configured and
sandbox-validated environments must never regain ambient values after validation.
Record pure Dart, Flutter, and native-platform results separately.

Record:

1. 更新了哪些 owner 文档、README、INDEX 或 history。
2. 还有哪些目录需要补索引或交付接线。
3. 这批交付影响了哪些 team runbook。
4. 下一个恢复点和需要继续确认的 owner 团队。

2026-06-25: Vityo-Implementation-Gaps.md 校正 — HostedWorkspaceFileSystemProvider 已从 Closed 降为 Partially implemented；Cache Contract 从 Closed 降为 Partially implemented（CacheStore<K,V> 接口未发布、Level 2 持久化未实现）。Vityo-System-Architecture.md、Vityo-Product-Spec.md、CURRENT-STATE.md 日期更新至 2026-06-25。contracts/README.md 新增 CacheContract 为第九条已发布合同。CURRENT-STATE.md 补充 VITYO_PRODUCT_GATE=1 前置条件与已知文档偏差说明。

2026-06-25: Architecture mainstream alignment package merged — added ADR-0010, four architecture/design SSOTs, API compatibility and security/supply-chain governance docs, architecture alignment rollup, and Agent Runtime / Architecture / Extension Module team runbooks. Regenerated docs indexes and refreshed DOC-STATS.md so the new owner documents are represented in docs delivery tracking.

2026-06-28: Windows native compatibility gate repair updated PowerShell bootstrap behavior, Windows validation docs, coverage-gate thresholds, and hosted `windows-latest` evidence expectations. Refresh DOC-STATS.md whenever this runbook changes.

2026-06-28: A legacy nested Better Plan workspace was introduced to index planning, milestone, gap,
rollup, audit, and governance sources. Its useful authority has since been consolidated into the
single `docs/plan/` root; the nested workspace and repository-local validator are retired.

2026-06-28: Added `docs/adr/IMPLEMENTED-DECISIONS.md` as the current-code compressed index for implemented architecture decisions. ADR policy now keeps standalone ADRs for decisions still needing direct review, while implemented decisions must carry current implementation or verification anchors.

2026-06-28: Added the English-by-default documentation rule to the documentation policy, contributor/agent spec, and docs delivery workflow. Chinese prose now requires an explicit localization, translation, or Chinese user-facing product/marketing scope.

2026-06-28: Three-platform CI gates now run the delivery health floor on `ubuntu-latest`, `windows-latest`, and `macos-latest`, then prove native Linux, Windows, and macOS Flutter debug builds. Rulesets should require `audit`, `styio-audit`, `local-ci-gate`, `windows-native`, and `macos-native`.

2026-06-28: Added `docs/design/Vityo-End-To-End-Mainstream-IDE-Plan.md` plus separate Linux, Windows, and macOS desktop adaptation plans. Better Plan now keeps `end-to-end-mainstream-ide-alignment` for shared module/workflow convergence and `linux-desktop-adaptation`, `windows-desktop-adaptation`, and `macos-desktop-adaptation` for host-specific evidence.

2026-06-28: Split the end-to-end mainstream IDE work into granular Better Plan entries for app composition, foundation registries, shell, editor buffers, language protocols, project graph/toolchain protocols, execution/debug protocols, agent interaction, user-facing workflows, module contributions, settings/profile/theme, hosted cloud routes, search/navigation/refactor workflows, problems/testing/source-control surfaces, security/audit, and the prototype editor harness.

2026-07-26: Replaced the former convergence and product-delivery plans with separate IDE and Coding
Agent Better Plan tracks. The repository layout uses two implementation roots plus one Vityo-owned
shared protocol package. As clarified by ADR-0019 on 2026-07-30, these are delivery tracks for one
Vityo product; Vityo Coding Agent is the first-party companion runtime, not a second product
identity. The obsolete line-anchored plan, its permanent verifier, and the outdated repository-local
Better Plan validator/test copy were removed; generated documentation indexes and lifecycle records
were refreshed.

2026-07-30: Completed the owner-adapter documentation migration. System Styio
discovery and machine-contract consumption replaced the former managed Styio
toolchain claims; generic IDE-owned tool provenance remains separate. Refreshed
implementation gaps, foundation ownership, post-commit checks, lifecycle
records, generated indexes, and team document statistics. Removed the obsolete
ecosystem sample-workflow gate after the Pafio metadata and Platform hosted
contracts became the authoritative validation surfaces.

2026-07-30: Closed the remaining product-gate source coupling. The gate now
creates its test project through public `pafio new`, consumes fixed Pafio and
Styio executables, and no longer imports a private fixture factory from a sibling
checkout. CI variables and release/development documentation use the same public
boundary.

2026-07-31: Converged current Agent architecture, contracts, security policy, release inventory,
CODEOWNERS guidance, and team routing on the canonical protocol-only IDE paths. Completed-plan and
archive references remain historical provenance rather than compatibility promises.

2026-07-31: Replaced the stale release-readiness evidence anchor for the removed toolchain
management adapter test with the current toolchain controller boundary. Updated the delivered
baseline and local validation evidence together, then verified that no active documentation or gate
still names the removed test.

2026-08-01: Migrated the sealed Vityo Better Plan workspace to the current capability-aware grouped
lifecycle format. Added the observed capability catalog, explicit Plan Purpose and capability
bindings, historical group-design boundaries, current difficulty classes, and the
Designer/Worker/Verifier/Reviewer runbook. Preserved every prior delivery Node and accepted
regression receipt, updated stale IDE and Coding Agent status projections, removed the one-time migration helper, and
validated both readable Plan projections without authorizing implementation or full regression.

2026-08-01: Consolidated all remaining legacy nested-workspace authority and historical evidence
into the single `docs/plan/` Better Plan root. Removed the final stale nested-path instructions,
declared nested and parallel workspaces invalid, and retained only the two capability-bound delivery
tracks plus their shared protocol fact.

2026-08-03: Added the capability-bound `interactive-editor-input` follow-on delivery group beneath
the existing transactional editor capability. The group freezes multi-cursor and rectangular
selection commands, composition-safe Unicode input, Flutter text-input and accessibility
integration, rendered 10k/100k performance evidence, and one trailing full IDE regression without
creating another product track or Better Plan workspace.

2026-08-09: Explicitly cleared all Better Plan capability, Manifest, task-group, and checkpoint
state. Retained only the empty `docs/plan/` documentation container and reusable execution runbook;
product implementation, tests, performance evidence, and visual evidence remain intact.

2026-09-04: Added one single-purpose external handoff plan for future Styio observable-language
consumption and regenerated its collection indexes. The document is explicitly unapproved and
fixture-gated, does not alter the existing Better Plan workspace, and starts no adapter, UI,
runtime, or `prototype/` implementation.

2026-09-05: Indexed `docs/contracts/ObservableTopologyAdapter.md`, marked the Styio observable
integration plan V1 as authorized and implemented, and refreshed collection indexes. V2/V3 remain
fixture-gated. No `prototype/` change.

2026-09-05: Updated `ObservableTopologyAdapter` and the Styio observable integration plan for V2
delta and lineage intake (bounded query deferred), then regenerated collection indexes. No
`prototype/` change.

2026-09-05: Marked Styio observable integration plan V3 implemented with live tailing deferred,
rewrote `RuntimeEventAdapter` for the v2 envelope mapping, amended ADR-0012, and regenerated
collection indexes. No `prototype/` change.

2026-09-06: Recorded unapproved observable-graph follow-ups in
`docs/rollups/OBSERVABLE-DELIVERY-FOLLOW-UPS.md`, including the execution-adapter
envelope mismatch. Report only; no adapter implementation in this change.

2026-10-03: Recorded the Windows lane state after the cross-platform gate repairs: the lane
now passes `architecture`, builds the pinned Styio CLI with MSVC, and runs the full Python
suite, and its remaining 16 failures and 2 errors are test fixtures encoding POSIX
expectations (permission bits, Unix-domain sockets, path and CRLF formatting) rather than
product defects. No `prototype/` change.

2026-10-03: Moved the docs/process gate composition into `scripts/docs_gate.py` and had
delivery invoke that implementation directly. `scripts/docs-gate.sh` remains the documented
convenience entrypoint and forwards to it, so the two cannot drift. The reason is platform
reach: on Windows `bash` in PATH can resolve to a WSL launcher, which fails the architecture
stage with "Windows Subsystem for Linux has no installed distributions". No `prototype/` change.

2026-10-03: Sealed the staged bundle with a real Developer ID certificate and recorded the
observed result: the application carries the hardened runtime, a Developer ID authority, and a
team identifier, and Gatekeeper reports `rejected` with `source=Unnotarized Developer ID`, which
is the expected pre-notarization state. Clarified that the frameworks' `--strict` ambiguity is a
property of the Flutter build output and is reproducible on the unmodified build, so verification
uses Gatekeeper assessment. Missing input is the notarization credential. No `prototype/` change.

2026-10-03: Resolved the first macOS sealing blocker. The package definition now declares
where the `vityod-component.json` identity record is staged, and macOS moves it to
`Contents/Resources` so `codesign` no longer sees unsigned JSON inside the nested-code
directory `Contents/Helpers`. The Flutter framework layout blocker remains open. Updated
the packaging contract and the signing evidence. No `prototype/` change.

2026-10-03: Exercised macOS sealing against a real Developer ID certificate on the
installed nightly bundle. Sealing stops on two bundle defects rather than on credentials:
`Contents/Helpers/vityod-component.json` is unsigned data inside a directory `codesign`
scans as nested code, and the Flutter frameworks are not a layout `codesign` will seal.
Recorded both in the signing contract with owners, and replaced the seal step's `--deep`
sign with explicit deepest-first enumeration of helpers, frameworks, extensions, and
dylibs. No `prototype/` change.

2026-10-03: Added `docs/release/macos-release-signing.md` as the macOS Developer ID
and notarization credential contract, and pointed the release checklist at it so the
nightly signing gap is discoverable from the release path. Documented the sealing
order, the environment-only credential interface, and the published evidence shape;
credentials remain unprovisioned, so nightly packages keep their explicit gap.
No `prototype/` change.

<!-- codex merge: docs/build/scripts assets imported -->

2026-10-06: Updated architecture source anchors for the production Flow Hero runtime
composition and the injectable packaged Agent launch resolver. Registered the existing
BSD-3-Clause workspace chooser in the dependency license gate. Keep unfinished repairs
on the same Draft PR and validate architecture and governance before pushing.

2026-10-08: Added an isolated, opt-in six-cell Windows Pafio launch diagnostic.
Reuse the existing Python, Dart packages and debug daemon build; do not rebuild
or replace product gates. The supervisor gates descendants until job assignment,
records bounded/redacted launch evidence and verifies owned-tree cleanup. Portable
mock tests establish orchestration only; Windows results remain pending. Any CI
hook is a separate reviewed patch. No `prototype/` change.

2026-10-08: Documented Pafio discovery's caller-side environment boundary after
Windows evidence showed credential-passthrough denial before process start. The
shared allowlist gains SYSTEMROOT/COMSPEC/PATHEXT with explicit casing, duplicate
and value-rejection tests; the daemon guard and explicit process maps stay intact.
The new real version-probe regression uses native Dart, leaving batch-wrapper and
transport lifecycle investigations separate. Never label portable assertions or
blocked Unix-socket integration as native Windows proof. No `prototype/` change.

2026-10-08: Added the app-owned Windows pipe boundary DLL to the existing CMake
build/install and early native-test preparation. The local-service transport owns
same-call Win32 result/error capture and buffer lifetime; Docs / Delivery owns
standalone test preparation, explicit compile-time DLL selection, and bundle
installation. Updated the protocol/build guidance and test catalog. Portable
checks pass; MSVC exports, installed loading, real cancellation and the full
Windows suite require fresh native evidence. No gate threshold or test omission
changed. No `prototype/` change.

2026-10-08: Tightened the same Windows pipe delivery slice: the existing Windows
package manifest declares the required DLL and ABI, packaging/install reject a
missing file, and the existing startup evidence gate requires ABI 1 from the real
bundled loader. Added missing-file/ABI negative tests. Linux/macOS package paths
and startup fields remain unchanged; real Windows validation is still required.

2026-10-08: Corrected the pipe helper's hardcoded VS 2022 selection for runners
whose existing discovery selects VS 18. Resolve installed C++ metadata with
`vswhere`, intersect it with actual CMake generator capabilities, preserve the
selected instance, and reject incompatible cached toolchains. Fresh portable
version/failure tests do not establish Windows compilation; no native gate,
dependency installation, or other platform path changed.

2026-10-08: Kept Draft PR 28's portable native-boundary repair test-local after a
conditional GCC reproduction of a predefined `__declspec` macro collision.
The fake header now safely replaces that macro, available/explicit host compiler
frontends use their own command adapters, and failure output is bounded and
redacted rather than swallowed. Preserve every wrapper assertion and native gate;
the exact CI compiler diagnostic still requires a fresh Windows run.

2026-10-08: Documented the Process Manager's local cleanup metadata alongside its
completed execution receipt. A close failure preserves command status and output;
only an acknowledged close confirms cleanup. Registered deterministic manager/client
transport tests and sandbox metadata-preservation coverage in the test catalog.
Portable Dart evidence is separate from native daemon cleanup and Windows pipe
acceptance; no published product or daemon protocol changed.

2026-10-08: Repaired three desktop test-fixture assumptions without changing
production adapters or security policy. Reconnect expectations use the existing
portable protocol path, scripted file lookup normalizes host separators, and the
real-daemon DAP test uses installed native Dart for raw byte echo instead of a
Unix-only cat path. Preserve byte equality, process ownership, and shutdown checks;
portable fixture checks do not establish a Windows or macOS CI pass.

2026-10-09: The Quick Open widget test now waits in real async time for the
selected file's editor-load notification before deleting its workspace. Preserve
the exact path/text and UI assertions; pumping demo timers alone does not prove
real file I/O completed. The bounded observer is removed in finally. This is a
test-lifetime repair, not a production controller or Windows CI pass claim.

2026-10-09: Registered focused shell live-operation adapter coverage. The probe
uses the no-output exit command accepted by the recognized shell families while
the existing manager and adapter retain entrypoint selection and fallback policy.
Preserve missing/unsupported and failed-result reporting, and the native test's
all-nine-manager requirement. Its diagnostic breakdown is evidence, not a relaxed
gate. Controlled process fixtures remain separate from native Windows execution.
