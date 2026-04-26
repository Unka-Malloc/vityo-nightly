# Styio View Docs

**Purpose:** 定义 `docs/` 树的范围、入口和维护规则；具体主题分别由各目录下的 `README.md`、`INDEX.md` 和权威文档负责。

**Last updated:** 2026-04-19

## Tree Contract

1. 产品与系统级 SSOT 放在 `docs/design/`。
2. 协作规则、仓库边界、依赖与文档策略放在 `docs/specs/`。
3. 实施路线、工作流与跨阶段拆解放在 `docs/plans/`。
4. 冻结里程碑与任务清单放在 `docs/milestones/`。
5. 架构决策记录放在 `docs/adr/`。
6. 风险、冲突和待裁决问题放在 `docs/review/`。
7. 可复用测试/交付资产放在 `docs/assets/`。
8. 当前状态和活跃缺口摘要放在 `docs/rollups/`。
9. 按日记录的演进历史放在 `docs/history/`。
10. 已归档 provenance 与 lifecycle 元数据放在 `docs/archive/`。
11. `styio-view` 产品拥有的 adapter 合同放在 `docs/contracts/`。
12. 与上游 `styio` 的对接边界、接口合同和阻塞项放在 `docs/external/for-styio/`。
13. 与上游 `spio` 的项目图、toolchain 与 workflow handoff 放在 `docs/external/for-spio/`。
14. 团队 ownership、review routing、handoff 和 checkpoint 入口放在 `docs/teams/`。

## Entry Points

1. 目录索引：[INDEX.md](./INDEX.md)
2. 构建与开发环境：[BUILD-AND-DEV-ENV.md](./BUILD-AND-DEV-ENV.md)
3. 产品规格：[design/Styio-View-Product-Spec.md](./design/Styio-View-Product-Spec.md)
4. 系统架构：[design/Styio-View-System-Architecture.md](./design/Styio-View-System-Architecture.md)
5. 文档策略：[specs/DOCUMENTATION-POLICY.md](./specs/DOCUMENTATION-POLICY.md)
6. 当前状态摘要：[rollups/CURRENT-STATE.md](./rollups/CURRENT-STATE.md)
7. 实施计划：[plans/Styio-View-Implementation-Plan.md](./plans/Styio-View-Implementation-Plan.md)
8. 文件治理对齐计划镜像：[plans/Styio-Ecosystem-File-Governance-Alignment-Plan.md](./plans/Styio-Ecosystem-File-Governance-Alignment-Plan.md)
9. 里程碑入口：[milestones/INDEX.md](./milestones/INDEX.md)
10. ADR 入口：[adr/INDEX.md](./adr/INDEX.md)
11. 产品合同入口：[contracts/INDEX.md](./contracts/INDEX.md)
12. `styio` 对接入口：[external/for-styio/INDEX.md](./external/for-styio/INDEX.md)
13. `spio` 对接入口：[external/for-spio/INDEX.md](./external/for-spio/INDEX.md)
14. 手写 Web IDE 工程手册：[specs/HANDWRITTEN-WEB-IDE-ENGINEERING-HANDBOOK.md](./specs/HANDWRITTEN-WEB-IDE-ENGINEERING-HANDBOOK.md)
15. 团队协作入口：[teams/COORDINATION-RUNBOOK.md](./teams/COORDINATION-RUNBOOK.md)

## Maintenance Rules

1. `README.md` 解释目录边界与维护方式。
2. `INDEX.md` 维护该目录内的人工索引。
3. docs 树变更后，用 `python3 scripts/docs-index.py --write` 刷新生成式索引。
4. 用 `python3 scripts/docs-lifecycle.py validate` 校验 active/history/archive 生命周期。
5. 用 `python3 scripts/docs-audit.py` 校验 docs 结构与元数据。
6. 产品语义变化时，同批更新 `design/`、相关 ADR、对应里程碑和测试目录。
7. `styio-view` 的产品合同由本仓拥有；上游实现需适配这些合同，而不是反过来驱动前端退化。
8. 若实现边界与上游仓库当前实现冲突，先把 required handoff 记录到 `external/for-styio/` 或 `external/for-spio/`，再在本仓 ADR 中记录适配决策。
9. 若一次变更改变了团队 owned surface、review 路由或 handoff 路径，同批更新受影响的 `teams/*.md` 和 `teams/COORDINATION-RUNBOOK.md`。
