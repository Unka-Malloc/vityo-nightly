# Styio View Implementation Plan

**Purpose:** 给出 `styio-view` 从产品合同冻结到跨端实现的实施顺序、工作流拆分、依赖链与阶段性门禁。

**Last updated:** 2026-04-22

**Status:** Active plan

## 0. 与三仓统一总纲的关系

`styio-view` 的跨仓里程碑以 [Styio-Ecosystem-Delivery-Master-Plan.md](./Styio-Ecosystem-Delivery-Master-Plan.md) 为镜像入口，权威副本位于 `styio-nightly`。

本文件继续负责 `view` 自己的工作流拆分和实施顺序，但不得私自改写三仓共同的 milestone ID、repo exit 或 cutover 定义。

当前映射关系固定为：

| Ecosystem milestone | `styio-view` workstreams | 本仓含义 |
|---------------------|--------------------------|----------|
| `M0` | `W1` | 产品合同、文档策略、adapter 边界、团队协作入口锁定 |
| `M1` | `W3` + `W5` compiler side consumption | 正式消费 `styio-nightly` 发布的 language/execution contract |
| `M2` | `W3` + `W4` + `W5` package/environment consumption | 正式消费 `spio` 的 project graph/toolchain/source/registry state |
| `M3` | `W2` + `W4` + `W5` | IDE core、project UI、execution shell、environment shell 闭合 |
| `M4` | `W6` + `W7` + `W8` + `W10` | runtime surface、AI、theme、module runtime 闭合 |
| `M5` | `W9` | Android、本地/云 iOS、Web hosted workspace 路线闭合 |
| `M6` | hardening across `W1-W10` | 完整产品级 IDE 与样板项目矩阵闭合 |

## 1. 实施目标

在不复用传统 IDE 组件的前提下，分阶段交付：

1. Flutter 主前端
2. 自研编辑器引擎
3. 产品拥有的 adapter 合同
4. canonical project model
5. scratch file 与项目路径的执行闭环
6. runtime surface
7. AI 面板
8. 主题系统
9. Android 本地优先能力
10. iOS 云执行能力
11. 模块挂载、卸载与 staged update 体系

## 2. 工作流拆分

| Workstream | Scope | First Major Exit |
|------------|-------|------------------|
| W1 Product Foundation | 文档、目录、合同、ADR、平台边界 | `docs/contracts/` 与 handoff 目录冻结 |
| W2 Editor Engine | 文档模型、布局、选择、输入、装饰层 | 可编辑的自研文本引擎 |
| W3 Adapter Layer | 语言、项目图、执行、runtime 事件的产品合同与实现槽位 | Flutter 只依赖 adapter |
| W4 Project Model | `spio.toml / spio.lock / spio-toolchain.toml / .spio / styio.toml` UI 与状态模型 | 正式项目图主线 |
| W5 Execution Routing | scratch single-file、project preview、cloud route | 执行路径与 capability gap 可视化 |
| W6 Runtime Surface | 底部运行图、线程轨与状态视图 | runtime 面板最小闭环 |
| W7 AI Surface | Agent 面板、provider adapter、prompt/profile 接入 | IDE 内建 AI 壳闭环 |
| W8 Theme System | 预设主题、分层主题、自定义存储 | 可切换/可编辑主题 |
| W9 Mobile And Hosted | Android 本地优先、iOS 云执行、Web hosted workspace | 移动端与云端首批可用路径 |
| W10 Module Runtime | 模块 manifest、capability matrix、安装/卸载、数据回收、staged update | 模块宿主闭环 |

## 3. 依赖顺序

```mermaid
flowchart LR
  W1["W1 Foundation"] --> W2["W2 Editor Engine"]
  W1 --> W3["W3 Adapter Layer"]
  W1 --> W10["W10 Module Runtime"]
  W3 --> W4["W4 Project Model"]
  W3 --> W5["W5 Execution Routing"]
  W2 --> W5
  W10 --> W5
  W5 --> W6["W6 Runtime Surface"]
  W2 --> W7["W7 AI Surface"]
  W1 --> W8["W8 Theme System"]
  W5 --> W9["W9 Mobile And Hosted"]
  W7 --> W9
  W10 --> W9
```

## 4. 当前主线策略

1. `styio-view` 先冻结产品合同和 adapter 边界。
2. 主线先支持 `CLI Adapter`。
3. `FFI Adapter` 是统一本地原生接入标识。
4. `Cloud Adapter` 作为移动端和 hosted workspace 的补充。
5. 上游缺能力时，写入 `../for-styio/` 或 `../for-spio/`，不牺牲产品语义。
6. 三仓共同里程碑变化必须先回写镜像总纲，再调整本文件中的 workstream 顺序和出入口。

## 5. 当前项目级任务清单

### 5.0 2026-04-21 可验证闭环标注

以下条目已在当前代码和测试中闭环，可从本计划的“当前下一步”里移出。未列出的条目仍按原计划推进，不因存在壳代码或占位结构而视为完成。

1. `W1 Product Foundation` 已闭合：`docs/contracts/`、`docs/for-styio/`、`docs/for-spio/`、Flutter 主前端、平台执行矩阵、capability gap 规则均已落到文档或 adapter surface；验证入口为 `docs/contracts/`、`docs/for-spio/`、`frontend/styio_view_app/lib/src/backend_toolchain/adapter_contracts.dart`、`frontend/styio_view_app/test/required_handoff_summary_test.dart`。
2. `W2 Editor Engine` 的文档模型、选择模型、撤销栈、键盘编辑、glyph substitution 光标映射、completion / formatting / quick-fix 交互链已闭合；验证入口为 `frontend/styio_view_app/lib/src/editor/`、`frontend/styio_view_app/test/editor_controller_editing_test.dart`、`frontend/styio_view_app/test/styio_language_service_smoke_test.dart`。
3. `W3 Adapter Layer` 的 project graph、execution、runtime event、dependency source、deployment、toolchain management 与 capability snapshot 已闭合到产品 adapter surface，旧 `integration/` 入口保留为兼容导出；验证入口为 `frontend/styio_view_app/lib/src/backend_toolchain/`、`frontend/styio_view_app/test/integration_compatibility_exports_test.dart`、`frontend/styio_view_app/test/hosted_control_plane_client_test.dart`。
4. `W4 Project Model` 的 canonical project graph、workspace members、dependencies、targets、toolchain、lock/vendor/build 状态，以及 `project_graph / toolchain_state / source_state / package_distribution` payload 消费已闭合；验证入口为 `frontend/styio_view_app/test/project_graph_adapter_test.dart`、`frontend/styio_view_app/test/toolchain_management_adapter_test.dart`、`frontend/styio_view_app/test/hosted_control_plane_client_test.dart`。
5. `W5 Execution Routing` 的 scratch single-file、project build/run/test、JIT route intent、deploy preflight、capability gap、`Cmd/Ctrl+Enter` 命令路由、required handoffs UI 已闭合；验证入口为 `frontend/styio_view_app/test/execution_adapter_test.dart`、`frontend/styio_view_app/test/execution_route_summary_test.dart`、`frontend/styio_view_app/test/deployment_adapter_test.dart`、`frontend/styio_view_app/test/app_commands_test.dart`、`frontend/styio_view_app/test/required_handoff_summary_test.dart`。真实 JIT compiler/backend contract 仍未发布，继续通过 capability gap / blocked status 呈现。
6. `W6 Runtime Surface` 的 `RuntimeEventEnvelope`、runtime event registry、thread lanes、graph summary、debug console replay 已闭合；验证入口为 `frontend/styio_view_app/lib/src/runtime/`、`frontend/styio_view_app/lib/src/backend_toolchain/runtime_event_adapter.dart`、`frontend/styio_view_app/test/runtime_surfaces_test.dart`。
7. `W9 Mobile And Hosted` 的 iOS cloud route、Web hosted workspace 控制面、hosted project/dependency/deployment/execution payload 回路已闭合；验证入口为 `frontend/styio_view_app/lib/src/backend_toolchain/hosted_control_plane*.dart`、`frontend/styio_view_app/test/hosted_control_plane_client_test.dart`、`frontend/styio_view_app/test/hosted_payload_codec_test.dart`。Android 本地优先路径与完整移动端交互模型未在当前测试中证明闭合。

以下条目已补到测试/文档层面的最小闭环，但不等同于完整产品级闭环：

1. `W7 AI Surface`：OpenAI-compatible endpoint profile、platform provider route、context channel persistence contract 已由 `frontend/styio_view_app/test/agent_profile_test.dart` 覆盖；真实 provider 调用与密钥接入仍需后续 gate。
2. `W8 Theme System`：主题 preset + user override token round-trip 已由 `frontend/styio_view_app/test/styio_theme_test.dart` 覆盖；可视化编辑面板仍需后续 UI gate。
3. `W10 Module Runtime`：core/optional lifecycle、staged update flag、optional uninstall reclamation policy 已由 `frontend/styio_view_app/test/module_lifecycle_test.dart` 覆盖；真实安装包更新与平台文件删除仍需后续 integration gate。
4. `M5/M6` 级平台矩阵和产品级 hardening 仍需后续专门 gate，当前 `flutter test` 只能证明 unit/widget/adapter 层。

### 5.0.1 2026-04-22 可立即闭环建议

以下条目已有代码和测试锚点，可作为当前阶段的最小闭环提交；未列为“可闭环”的能力不应仅凭壳代码或静态文档标为完成。

1. `W7 AI Surface` 可闭环项：提交 `frontend/styio_view_app/lib/src/agent/agent_profile.dart` 与 `frontend/styio_view_app/test/agent_profile_test.dart`，闭合 provider route、OpenAI-compatible endpoint profile、context channel persistence contract。暂不闭合项：真实 provider HTTP call、密钥注入、local bridge / cloud execution 成功回路。
2. `W8 Theme System` 可闭环项：提交 `frontend/styio_view_app/lib/src/theme/styio_theme.dart` 与 `frontend/styio_view_app/test/styio_theme_test.dart`，闭合 preset + user override token round-trip 与 persisted hash color decode。暂不闭合项：可视化主题编辑面板、用户 profile store 与跨会话 UI 验证。
3. `W10 Module Runtime` 可闭环项：提交 `frontend/styio_view_app/lib/src/module_host/module_lifecycle.dart` 与 `frontend/styio_view_app/test/module_lifecycle_test.dart`，闭合 core/optional lifecycle、staged update flag、optional uninstall reclamation policy。暂不闭合项：真实安装包 staging、平台文件删除、按端 package/cache/data 回收 integration gate。
4. `W9 Mobile And Hosted` 可闭环项：提交 hosted control-plane/payload 测试、`frontend/styio_view_app/test/viewport_profile_test.dart` 与 `frontend/styio_view_app/test/agent_profile_test.dart` 中 iOS cloud-only、Web hosted、Android local-bridge route 的锚点；这些只能证明 hosted/iOS/Web 路由和 Android route metadata。暂不闭合项：Android 本地优先执行路径、移动端交互矩阵、真机/模拟器平台 gate。

### 5.1 W1 Product Foundation

1. 冻结 `docs/contracts/`
2. 建立 `docs/for-styio/` 与 `docs/for-spio/` handoff
3. 固定 Flutter 作为主前端
4. 固定平台执行矩阵
5. 建立 capability gap 验收规则

### 5.2 W2 Editor Engine

1. `DocumentState` 与撤销模型
2. 多层渲染：文本层、装饰层、overlay 层
3. glyph substitution 与光标映射
4. semantic block surface
5. 桌面快捷键与移动手势模型

### 5.3 W3 Adapter Layer

1. 定义 `LanguageServiceAdapter`
2. 定义 `ProjectGraphAdapter`
3. 定义 `ExecutionAdapter`
4. 定义 `RuntimeEventAdapter`
5. 定义 `AdapterCapabilitySnapshot`
6. 主壳只消费 adapter，不直接依赖上游内部实现

### 5.4 W4 Project Model

1. 围绕 `spio.toml / spio.lock / spio-toolchain.toml / .spio / styio.toml` 建立项目 UI
2. 项目树、workspace members、dependencies、targets、toolchain、lock/vendor/build 状态
3. 正式消费 `project_graph / toolchain_state / source_state / package_distribution`，不再停留在 compile-plan preview 占位

### 5.5 W5 Execution Routing

1. scratch single-file 路径
2. 项目路径的 live build/run/test / JIT / deploy preflight 路由
3. capability gap 与 blocked status UI，仅用于尚未发布的上游路径
4. `Cmd/Ctrl+Enter` 命令路由
5. `Required Handoffs` UI，只陈述上游需要交付的 machine contract

### 5.6 W6 Runtime Surface

1. `RuntimeEventEnvelope`
2. thread lanes / graph view 的最小数据模型
3. runtime feature registry

### 5.7 W7 AI Surface

1. agent panel 的输入/输出协议
2. prompt profile 存储
3. `OpenAI-compatible endpoint` adapter
4. local bridge / cloud provider 入口

### 5.8 W8 Theme System

1. 主题分层模型
2. 预设主题
3. 用户局部覆写

### 5.9 W9 Mobile And Hosted

1. Android 本地优先路径
2. iOS 云执行路径
3. Web hosted workspace 生命周期
4. 移动端交互模型

### 5.10 W10 Module Runtime

1. `ModuleManifest`
2. `ModuleCapabilityMatrix`
3. core / optional module 生命周期
4. staged update
5. 平台化卸载回收策略

## 6. 跨阶段门禁

1. 没有正式产品合同前，不把 Flutter 与上游实现绑死。
2. 没有 capability gap 语义前，不承诺任何未发布的执行路径。
3. 没有 project graph contract 前，不通过私有目录猜业务状态。
4. 没有 runtime event contract 前，不承诺复杂运行图。
5. 没有模块 lifecycle 协议前，不承诺热更新或按端卸载能力。

## 7. 当前下一步

1. 继续推进 `W7 AI Surface` 的真实 provider 调用、密钥注入与 local bridge / cloud provider execution 回路。
2. 补齐 `W8 Theme System` 的可编辑主题面板，并把已验证的 override token 接到用户存储。
3. 推进 `W10 Module Runtime` 的真实安装/更新包处理与平台化文件回收 integration gate。
4. 对接真实 JIT compiler/backend contract；在未发布能力前继续通过已验证的 JIT route intent、capability gap / blocked status 呈现。
5. 为 `W9 Mobile And Hosted` 补 Android 本地优先路径和移动端交互模型的 platform matrix gate。
