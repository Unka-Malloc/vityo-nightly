# Specs Docs

**Purpose:** Define the scope of collaboration, dependency, and repository policies in `docs/specs/`; see [INDEX.md](./INDEX.md) for the file inventory.

**Last updated:** 2026-10-02

## Scope

1. 文档策略、仓库边界、贡献和 agent 协作规则。
2. 第三方依赖与工具链边界。
3. 跨模块、跨服务的接口合同与 schema 基线。
4. UX、可访问性、性能和布局维护准则。
5. 不在此目录维护具体 feature 的产品行为规格。
6. 手写 Web IDE 原型线的工程方法、重构原则与实现工作流，也在此目录维护。
7. 代码审计与 agent review 的强制规则维护在 [audit/CODE-AUDIT-CHECKLIST.md](./audit/CODE-AUDIT-CHECKLIST.md)；所有 agent 必须先按其中七大设计原则检查实现。
8. Local verification and authorized post-push GitHub Actions evidence live in [POST-COMMIT-CI-CHECKS.md](./POST-COMMIT-CI-CHECKS.md).
9. 技术栈、自研组件、开源组件和依赖 manifest 清单维护规则维护在 [TECHNOLOGY-COMPONENT-INVENTORY.md](./TECHNOLOGY-COMPONENT-INVENTORY.md)。
