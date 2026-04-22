# Styio View Independent Work Breakdown

**Purpose:** 把 `styio-view` 在不依赖上游新接口的前提下可独立推进的工作拆开，同时明确哪些能力必须转到 `../for-styio/` 或 `../for-spio/`。

**Last updated:** 2026-04-21

**Status:** Active breakdown

## 1. 何为“独立可做”

满足下列条件的工作视为 `styio-view` 可独立推进：

1. 不要求上游发布新的 machine contract
2. 可以先用 canonical files、mock data、占位 provider 或 blocked session 驱动
3. 完成后不会推翻未来的 adapter 结构

## 2. 当前可独立推进的工作包

### 2.0 2026-04-21 已闭环工作包

以下独立工作包已有当前代码和测试证据，可从“独立可做”的待办池中移出：

1. `2.1 Shell And Viewport` 已闭合：Flutter 主壳、桌面/移动视窗族、侧栏/底部 surface/状态栏、命令路由均有实现与 smoke/command/viewport 测试覆盖。
2. `2.2 Editor Core` 已闭合到当前阶段：`DocumentState / SelectionState / undo-redo`、键盘编辑、source buffer fidelity、glyph substitution 光标映射、completion/formatting/quick-fix 交互链已有 editor 和 language smoke 测试覆盖。
3. `2.4 Project UI And Persistence` 已闭合到当前阶段：canonical project state、本地文件系统持久化、Web/内存持久化、文件切换、文档缓存、revision 管理已有 project graph、workspace store、shell smoke 测试覆盖。
4. `2.6 Runtime And Agent Shells` 中 runtime/debug shell 已闭合：runtime replay、thread lane、graph summary、debug console replay 已有 widget 测试覆盖。agent profile/provider route/context channel persistence contract 已有 `agent_profile_test.dart` 覆盖；真实 provider 调用、密钥注入和 local/cloud execution 仍不在本次闭环范围内。
5. `2.5 Module Host` 已闭合到 lifecycle policy 层：core/optional lifecycle、staged update flag、optional uninstall reclamation policy 已有 `module_lifecycle_test.dart` 覆盖。真实安装包 staging、平台文件删除和按端 package/cache/data 回收仍需 integration gate。
6. `2.7 Theme System` 已闭合到 token persistence 层：preset + user override token round-trip、persisted hash color decode 已有 `styio_theme_test.dart` 覆盖。可视化主题编辑面板、用户 profile store 和跨会话 UI 验证仍需后续 gate。

仍不应标为完成：

1. `2.5 Module Host` 的真实安装/更新包处理、平台文件删除和平台化资源回收。
2. `2.7 Theme System` 的可编辑主题面板、本地 profile store 和跨会话 UI 验证。
3. `W9 Mobile And Hosted` 的 Android 本地优先执行路径、移动端交互矩阵和真机/模拟器 platform gate；当前仅能提交 hosted/iOS/Web route 与 Android route metadata 的测试锚点。

### 2.1 Shell And Viewport

1. Flutter 六端主壳
2. 桌面/移动统一视窗族
3. 工作区侧栏、模块侧栏、底部 surface、状态栏
4. 全局命令路由和快捷键分发

### 2.2 Editor Core

1. `DocumentState / SelectionState / undo-redo`
2. 键盘输入、删除、换行、拖拽选区
3. source buffer fidelity
4. 多层渲染骨架：`text / decoration / overlay`
5. token 级点击、hover 定位、局部高亮

### 2.3 Display-Only Semantic UX

1. glyph substitution 的显示层规则
2. token context、inline feedback、language inspector 的交互壳
3. semantic block surface 的展示结构
4. completion / formatting / quick-fix 的 UI 交互链

### 2.4 Project UI And Persistence

1. 围绕 canonical files 的项目树和状态 UI
2. 本地文件系统持久化
3. Web 侧轻量持久化
4. 文件切换、文档缓存、revision 管理

### 2.5 Module Host

1. `ModuleManifest`
2. capability matrix
3. 可见性、挂载占位、平台过滤
4. staged update 的 UI 表达和宿主状态机骨架

### 2.6 Runtime And Agent Shells

1. 底部 runtime / debug / agent 面板骨架
2. thread lanes 与 graph view 占位
3. provider adapter 抽象
4. prompt profile 与 local bridge 入口

### 2.7 Theme System

1. 主题分层模型
2. 预设主题
3. 可编辑主题面板
4. 本地 profile store

## 3. 必须等待 `styio` 的对接面

统一放到 `../for-styio/`：

1. 真实 `TokenSpan / SemanticSpan / Diagnostic / QuickFix / TextEdit`
2. minimal compilable unit resolution
3. compile / run session
4. runtime event stream
5. compile-plan consumer
6. machine-info 扩展

## 4. 必须等待 `spio` 的对接面

统一放到 `../for-spio/`：

1. project graph payload
2. workflow success payload
3. toolchain state payload
4. registry / package state payload
5. compile-plan preview 的正式 project orchestration contract

## 5. 当前执行顺序建议

1. 保持主壳只依赖 adapter，并把新增后端能力继续收敛到 `backend_toolchain` surface。
2. 推进 agent 真实 provider 调用、密钥注入和 local/cloud bridge execution gate。
3. 推进 theme editor、用户 profile store 和跨会话 UI 验证。
4. 推进 module 真实安装/更新包处理、平台文件删除和回收 integration gate。
5. 把新增上游缺口继续集中沉淀到 handoff 文档。
