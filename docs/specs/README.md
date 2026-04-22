# Specs Docs

**Purpose:** 定义 `docs/specs/` 中协作、依赖和仓库规则的范围；文件索引见 [INDEX.md](./INDEX.md)。

**Last updated:** 2026-04-23

## Scope

1. 文档策略、仓库边界、贡献和 agent 协作规则。
2. 第三方依赖与工具链边界。
3. 跨模块、跨服务的接口合同与 schema 基线。
4. UX、可访问性、性能和布局维护准则。
5. 不在此目录维护具体 feature 的产品行为规格。
6. 手写 Web IDE 原型线的工程方法、重构原则与实现工作流，也在此目录维护。
7. 代码审计与 agent review 的强制规则维护在 [audit/CODE-AUDIT-CHECKLIST.md](./audit/CODE-AUDIT-CHECKLIST.md)；所有 agent 必须先按其中七大设计原则检查实现。
8. Post-push GitHub Actions checking rules live in [POST-COMMIT-CI-CHECKS.md](./POST-COMMIT-CI-CHECKS.md).
