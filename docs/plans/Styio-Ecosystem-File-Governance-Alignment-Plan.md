# Styio Ecosystem File Governance Alignment Plan

**Purpose:** 作为 `styio-view` 对三仓文件治理对齐计划的镜像入口，固定 `view` 在文档生命周期、docs 自动化、repo hygiene 与文件治理脚本升级上的职责与本仓出口。

**Last updated:** 2026-04-21

**Authority:** The canonical copy lives at [`styio-nightly/docs/plans/Styio-Ecosystem-File-Governance-Alignment-Plan.md`](../../../../styio-nightly/docs/plans/Styio-Ecosystem-File-Governance-Alignment-Plan.md).

## `styio-view` 的对齐目标

`view` 当前目录结构已经具备产品化形态，但治理自动化最弱；本计划要求 `view` 对齐到与 `nightly` / `spio` 等强的文件治理水位：

1. 补齐 `docs/archive/` 与轻量 `docs/rollups/`。
2. 为 `docs/plans/`、`docs/history/`、`docs/external/for-*`、`docs/contracts/` 建立可检查的索引和 lifecycle 规则。
3. 升级 `scripts/repo-hygiene-gate.py`，让它覆盖 docs 入口、索引、临时产物和 fixture 反忽略策略。

## 里程碑映射

| 里程碑 | `view` 侧完成物 | 本仓主要落点 | 最低 gate |
|--------|------------------|--------------|-----------|
| `FG0` | 镜像计划、文档策略、runbook 接线 | `docs/plans/` `docs/specs/` `docs/teams/` | `python3 scripts/repo-hygiene-gate.py --mode tracked` |
| `FG1` | 与 `nightly` / `spio` 的目录职责对齐 | `docs/README.md` `docs/specs/DOCUMENTATION-POLICY.md` | docs + hygiene floor |
| `FG2` | `archive/rollups`、docs index/audit/lifecycle 接入 | `docs/archive/` `docs/rollups/` `scripts/` | `python3 scripts/repo-hygiene-gate.py --mode tracked` |
| `FG3` | ignore/fixture/gate 基线统一；冻结 shared baseline pattern、`docs/**` + `frontend/styio_view_app/test/**` negate 规则，并让 `repo-hygiene-gate.py` 显式校验 required patterns 与治理文档接线 | `.gitignore` `scripts/repo-hygiene-gate.py` `docs/teams/` | `python3 scripts/repo-hygiene-gate.py --mode tracked` |
| `FG4` | 稳态治理 | 全仓 docs 入口 | full hygiene floor |

## 本仓规则

1. `view` 不能继续只靠人工维护 docs 索引和目录状态。
2. 文件治理变化优先更新本镜像，再更新 `DOCUMENTATION-POLICY.md`、`COORDINATION-RUNBOOK.md` 和受影响计划/交接文档。
3. 根 `.gitignore` 变更必须与 repro fixture 的可追踪性一起审查。
4. 后续新增 docs/file governance 自动化时，优先扩展 `scripts/repo-hygiene-gate.py` 或复用 `nightly` 的脚本思路，而不是平行创建无接线的新工具。
