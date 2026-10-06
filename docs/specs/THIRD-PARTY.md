# Third-Party Inventory

**Purpose:** Record accepted, planned, and deferred dependencies across the Vityo IDE and its first-party companion Agent runtime.

**Last updated:** 2026-10-03

## 1. 已接受依赖

| Dependency | Status | Role | Notes |
|------------|--------|------|-------|
| Flutter SDK | Accepted | 主前端运行时与跨端 UI 框架 | 负责桌面、移动与 Web 端 UI。 |
| Dart SDK | Accepted | Flutter 语言运行时 | 作为 Flutter 的直接依赖。 |
| `styio` upstream repository | Accepted (first-party upstream) | 语言与编译器核心 | 非第三方，但属于本仓依赖边界。 |
| LLVM | Accepted (via `styio`) | CodeGen / JIT / IR 后端 | 由上游 `styio` 维护。 |
| `file_selector` | Accepted | Platform-native workspace directory chooser | BSD-3-Clause; exact locked version and runtime boundary are registered in [Dependency Usage](../../DEPENDENCY-USAGE.md). |
| `flutter_secure_storage` | Accepted | 系统安全凭据存储 | 桌面与移动端使用操作系统密钥存储；Web 不作为长期凭据的生产持久化路径。BSD-3-Clause。 |

## 1.1 Rust Runtime And Delivery Dependencies

The direct Cargo registration, exact constraints, resolved versions, and source boundaries are
maintained in [Dependency Usage](../../DEPENDENCY-USAGE.md). The selected Rust integrations are:

| Dependency | Status | Role | Notes |
|------------|--------|------|-------|
| `agent-client-protocol` 2.2.0 | Accepted | ACP process/session protocol for the independent Coding Agent | Uses the standard Agent Client Protocol boundary; it does not replace the Vityo-owned IDE-side client. |
| `rmcp` 3.5.0 | Accepted | MCP client library and child-process transport in the Coding Agent | The SDK and tool adapters are implemented and covered with deterministic peer tests. Production ACP `session/new` and `session/load` reject non-empty `mcpServers` with `-32003`; no production attachment lifecycle is claimed. |
| `async-openai` 0.42.1 | Accepted | OpenAI-compatible chat request and streaming adapter | The Rust runtime uses the configured adapter, not a bundled endpoint, account, or model. Unit fixtures exercise local HTTP/SSE behavior through a test-only transport seam; live provider acceptance remains separate. |
| `reqwest` 0.13.5 | Accepted | TLS HTTP transport | Native TLS backend is selected for the configured Rust provider request path. |
| `keyring` 4.2.0 and `secrecy` 0.10.3 | Accepted | Native credential lookup and in-memory secret handling | Provider configuration contains a credential-service/account reference, not a raw credential. |
| `cargo-llvm-cov` 0.9.0 | Accepted | Rust test coverage instrumentation | `python3 scripts/vityo.py test` prepares `llvm-tools-preview` and verifies or installs this exact tool version; direct helper calls require both prerequisites already available. |
| `cargo-about` 0.9.2 | Accepted | Locked dependency license analysis and third-party notices | The repository wrapper installs it project-locally and checks the supported desktop-target dependency graphs. |

The first-party Rust Coding Agent is the current runtime. The independent Dart protocol client
binding remains under `packages/vityo_agent_protocol`; it is not an Agent runtime. These package
selections and deterministic fixtures do not establish live provider acceptance.

## 1.2 UI 字体与预设来源

| Asset | Status | Role | Notes |
|-------|--------|------|-------|
| IBM Plex Sans / IBM Plex Mono | Accepted | 默认界面 / 编辑器字体族的一部分 | 开源字体，允许作为默认 fallback。 |
| Inter | Accepted | 默认界面字体族的一部分 | 开源字体，允许作为默认 fallback。 |
| JetBrains Mono | Accepted | 默认编辑器等宽字体 | 开源字体，允许作为默认 fallback。 |
| Recursive | Accepted | 默认界面 / 编辑器备选字体 | 开源字体，允许作为默认 fallback。 |
| Noto Sans / Noto Sans Math | Accepted | 多语言与数学 glyph fallback | 开源字体，允许作为默认 fallback。 |
| STIX Two Math | Accepted | 数学 glyph fallback | 开源字体，允许作为默认 fallback。 |

## 1.3 UI 预设命名策略

1. 用户可见的主题、调色盘和高亮预设标签优先使用中性命名，例如 `Studio Dark`、`Graphite Blue`、`Amber Night`。
2. 不把第三方产品品牌名直接作为默认 UI 标签，即使对应调色思路来自开源社区主题。
3. 色值本身视为功能性配置数据；风险控制重点放在字体许可和用户可见命名上，而不是十六进制数值本身。

## 2. 计划中但未冻结

| Dependency / Service | Status | Intended Role | Blocking Question |
|----------------------|--------|---------------|-------------------|
| 图布局引擎 | Planned | 底部运行可视图的自动布局 | 选择 Flutter 原生实现还是引入外部库未定。 |
| 云容器执行平面 | Planned | iOS 与远程工作区执行后端 | 资源调度、计费与沙箱边界待定。 |
| 本地 AI 模型运行时 | Planned | 移动端输入预测 agent / 本地 coding agent | 模型大小、授权与设备门槛待定。 |
| 模块分发与更新服务 | Planned | 模块下载、筛选、staged update | 平台分发、签名和缓存策略待定。 |
| OpenAI-compatible provider endpoint | Selected adapter boundary; no live endpoint selected | Configurable chat completion provider for the Coding Agent | Provider endpoint/model are Agent-owned configuration; no endpoint or account is bundled. Deterministic transport fixtures are engineering checks; live service behavior is not claimed. |
| OpenRouter provider | Planned prelaunch candidate, Agent runtime only | Optional Coding Agent provider | Connect through an Agent-runtime adapter; never hardcode it in Vityo. |
| Profile sync service | Planned | prompt / profile 的可选云同步组件 | 未挂载时必须保持 local-only。 |

## 3. 明确暂缓

| Dependency | Status | Reason |
|------------|--------|--------|
| Qt / Qt Quick | Deferred | 当前已决定 Flutter 为主前端。 |
| Electron | Rejected | 不符合项目对原生显示与非 Chromium 主路径的要求。 |
| Tauri 作为主 UI 路线 | Rejected | 仍以 WebView 为主，不符合当前架构目标。 |

## 4. 维护规则

1. 引入新的长期依赖前先更新本文件。
2. 若依赖会影响平台策略、打包、许可或运行时模型，应新增 ADR。
3. 若某依赖只用于实验，不得写入“已接受”表。
