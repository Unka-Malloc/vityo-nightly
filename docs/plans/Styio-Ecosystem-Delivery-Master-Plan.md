# Styio Ecosystem Delivery Master Plan

**Purpose:** 作为 `styio-view` 对三仓统一交付总纲的镜像入口，固定 IDE、runtime、AI、theme、module、mobile/cloud 路线与跨仓里程碑的映射关系。

**Last updated:** 2026-04-21

**Authority:** The canonical copy lives at [`styio-nightly/docs/plans/Styio-Ecosystem-Delivery-Master-Plan.md`](../../../../styio-nightly/docs/plans/Styio-Ecosystem-Delivery-Master-Plan.md).

## `styio-view` 的长期职责

在统一产品里，`styio-view` 持续负责：

1. editor shell and workspace UX
2. project graph consumption
3. build/run/test routing
4. diagnostics mapping
5. runtime event rendering
6. environment install / use / pin / switch UX
7. deploy preflight and version-switch shell behavior

## 里程碑映射

| 里程碑 | `view` 侧完成物 | 本仓权威文档 | 本仓最低 gate |
|--------|------------------|--------------|---------------|
| `M0` | 镜像总纲、文档策略、团队 runbook、implementation-plan 映射接线 | `docs/plans/Styio-Ecosystem-Delivery-Master-Plan.md` `docs/specs/DOCUMENTATION-POLICY.md` | `python3 scripts/repo-hygiene-gate.py --mode tracked` |
| `M1` | `nightly` 的 language/execution contract 正式消费，停止使用未发布语义 | `docs/external/for-styio/` `docs/contracts/` | adapter contract tests |
| `M2` | `spio` 的 project graph/toolchain/source/registry payload 正式消费 | `docs/external/for-spio/` `docs/contracts/` | `flutter analyze && flutter test` |
| `M3` | editor/project/execution/environment/deploy shell 闭合 | `docs/plans/Styio-View-Implementation-Plan.md` `docs/assets/workflow/TEST-CATALOG.md` | `flutter analyze && flutter test`，必要时 `npm run selftest:editor` |
| `M4` | runtime surface、AI panel、theme system、module runtime 闭合 | `docs/design/` `docs/plans/` `docs/teams/` | runtime/agent/module/theme tests |
| `M5` | Android、本地/云 iOS、Web hosted workspace 路线闭合 | `docs/design/` `docs/plans/` `docs/review/` | platform matrix tests |
| `M6` | 统一语言产品级 IDE 完成态与 hardening | `docs/history/` `docs/assets/workflow/TEST-CATALOG.md` | full UI + contract + sample matrix floor |

## `styio-view` Checkpoint Rules

1. `styio-view` must consume published machine payloads before adding filesystem heuristics.
2. If a required upstream capability is not published, the shell must surface `blocked` or `partial`.
3. Contract wording in `docs/external/for-styio/` and `docs/external/for-spio/` must be updated in the same checkpoint as adapter behavior changes.
4. Front-end visual polish does not outrank compiler, workflow, or environment correctness.
5. Any milestone or repo-exit change must be reflected here, in `Styio-View-Implementation-Plan.md`, and in the affected `external/for-styio/` / `external/for-spio/` handoff docs.

## 本仓优先顺序

当前 `view` 的推进顺序固定为：

1. project and execution contract truth
2. runtime and environment shell behavior
3. IDE workflow closure
4. visual/UI polish
