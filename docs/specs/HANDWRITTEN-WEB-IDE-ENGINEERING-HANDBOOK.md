# Handwritten Web IDE Engineering Handbook

**Purpose:** 记录 `prototype/editor.html` 这条手写 Web IDE 原型线的设计理念、设计决策、实现方法、重构原则与标准工作流，避免经验只存在于对话中。

**Scope:** 本文只覆盖 `prototype/` 下的手写 Web IDE，不覆盖 Flutter 主壳。

**Last updated:** 2026-04-21

## 1. 产品定位

1. `prototype/editor.html` 是当前仓库里给人维护的 Web IDE 主入口。
2. 这条线的目标不是做“概念 demo”，而是做可长期演进的高保真 IDE 原型。
3. 这条线优先验证：
   - 编辑器交互
   - 文件树与 workspace
   - 主题与配置体系
   - 样式与布局语言
   - 与未来语言服务 / compile-run 合同兼容的前端结构

## 2. 设计理念

### 2.1 源码与显示分离

1. 源码文本始终是 canonical source。
2. glyph substitution、semantic block surface、selection glow 都只是显示层。
3. 任何视觉替换都不能静默改写用户源码。

### 2.2 IDE 风格优先于营销页风格

1. 页面风格应像 IDE，而不是 landing page。
2. 信息密度要高，但不能杂乱。
3. 交互反馈要轻、稳、克制。
4. 文件树、设置面板、tabs、弹窗，都应偏 JetBrains / VS Code 的现代 IDE 风格，而不是厚重的卡片堆叠。

### 2.3 组件必须服从容器

1. 任何内部组件都不得超过外部容器。
2. 若空间不足，只允许：
   - `min-width: 0`
   - 内部滚动
   - 重排
   - 降低信息密度
3. 不允许通过“让子元素溢出父容器”来掩盖布局问题。

### 2.4 开源资产优先

1. 默认字体、glyph 字体、图标和主题预设必须优先使用开源、低争议来源。
2. 不要把商业品牌名直接作为默认字体或默认主题标签。
3. 用户可见默认项应使用中性命名，例如：
   - `Default`
   - `Gold`
   - `Default Sans`

## 3. 当前架构

## 3.1 文件边界

1. [prototype/editor.html](../../prototype/editor.html)
   负责结构与 DOM 锚点。
2. [prototype/editor.css](../../prototype/editor.css)
   负责视觉系统、布局、状态样式与尺寸变量。
3. [prototype/editor.js](../../prototype/editor.js)
   负责状态、事件、渲染、workspace、配置导入导出与行为编排。
4. [prototype/editor-modules/runtime-config.js](../../prototype/editor-modules/runtime-config.js)
   负责默认配置、存储 key、初始状态模板。
5. [prototype/editor-modules/enums.js](../../prototype/editor-modules/enums.js)
   负责枚举与稳定 key。
6. [prototype/editor-modules/theme-presets.js](../../prototype/editor-modules/theme-presets.js)
   负责 Theme / Editor 主题模板、字体模板、字号模板。
7. [prototype/editor-modules/glyph-presets.js](../../prototype/editor-modules/glyph-presets.js)
   负责 glyph、symbol color、block / line / selection 预设。
8. [prototype/editor-modules/render-pipeline.js](../../prototype/editor-modules/render-pipeline.js)
   负责渲染切片调度。
9. [prototype/editor-modules/surface-actions.js](../../prototype/editor-modules/surface-actions.js)
   负责 `Theme / Editor` 风格行为的层级定义。
10. [prototype/dev_server.py](../../prototype/dev_server.py)
    负责本地开发服务、workspace API、浏览器文件浏览 API。

## 3.2 状态分层

当前状态至少分成四类：

1. 文档与编辑状态
   - 当前文件
   - 文件内容
   - 选区
   - caret
   - dirty / save state
2. workspace 状态
   - root path
   - 文件树
   - active tree path
   - expanded tree paths
   - 多选删除状态
3. surface 风格状态
   - `Theme`
   - `Editor`
   - `Block`
   - `Line`
   - `Selection`
   - `Symbol Colors`
4. UI 辅助状态
   - 抽屉展开
   - 下拉展开
   - picker / dialog / toast

## 3.3 模板先于状态

1. 所有主题、颜色、字体、字号、glyph 和高亮风格，都应来自模板。
2. 运行时状态只保存“当前选择的 key”，而不是到处散落匿名颜色值。
3. 只有用户手动改 `Symbol Colors` 这种局部覆盖时，才允许偏离模板。

## 4. 渲染模型

## 4.1 渲染切片

当前渲染切片定义在 [render-pipeline.js](../../prototype/editor-modules/render-pipeline.js)：

1. `themeAppearance`
2. `settingsControls`
3. `settingsState`
4. `sidebar`
5. `editorLines`
6. `editorLayout`
7. `editorBlocks`
8. `editorCaret`
9. `statusbar`
10. `saveUi`

## 4.2 为什么要切片

1. 编辑器和侧边栏不能总是一起刷新。
2. 行、块、光标、状态栏的刷新成本不同。
3. 高频行为必须尽量局部化：
   - 输入
   - 选区
   - 双击
   - 三连击
   - 方向键
4. 低频行为可以接受整块刷新：
   - 切换文件
   - workspace 重载
   - 删除后重建树

## 4.3 当前统一行为入口

`Theme / Editor` 风格行为不应该由按钮本身决定刷新哪些管线，而应通过统一的动作分发器：

1. `switchSurfaceMode(surfaceKey, nextMode)`
2. `selectSurfacePalette(surfaceKey, paletteKey)`
3. `dispatchSurfaceAction(action, applyState, options)`

这三者都在 [editor.js](../../prototype/editor.js) 中。

## 5. 行为层级模型

行为必须按作用域分层，而不是统一粗暴全量刷新。

### 5.1 surface

示例：

1. `Theme Dark / Light`
2. `Theme Palette`
3. `Editor Dark / Light`
4. `Editor Palette`

规则：

1. 触发整块 surface 的状态切换。
2. 子项会跟着该 surface 的模板一起切。
3. 例如 `Editor Dark / Light` 要让 `Editor Background / Text / Highlight / Block / Line / Selection` 一起切到同模式的模板。

### 5.2 section

示例：

1. `Interface Font`
2. `Interface Size`
3. `Theme Text`
4. `Theme Background`
5. `Theme Lines`
6. `Editor Font`
7. `Editor Font Size`
8. `Editor Text`
9. `Editor Background`
10. `Editor Text Highlight`

规则：

1. 只刷新所属 section 对应的 appearance。
2. 不能误触发整个 editor DOM 重建。

### 5.3 leaf

示例：

1. `Block`
2. `Line`
3. `Selection`
4. `Symbol Colors`

规则：

1. 这些属于 editor 的子组件风格。
2. 改 `Block` 时，应只触发 block 渲染路径。
3. 改 `Line` 时，应只触发行高亮路径。
4. 改 `Selection` 时，应只触发选区高亮路径。
5. 改 `Symbol Colors` 时，应只触发 glyph 颜色路径。

## 6. 当前分层规则的落点

动作模板定义在 [surface-actions.js](../../prototype/editor-modules/surface-actions.js)。

关键约束：

1. 每个动作必须声明：
   - `surface`
   - `scope`
   - `section`
   - `renderTarget`
   - `persistTarget`
2. 按钮层只负责触发 action。
3. `persist` 和 `render` 由统一分发器负责。
4. 不允许按钮事件里再次直接串：
   - `persist...`
   - `requestEditorThemeRender()`
   - `flushFullAppRender()`
   除非是明确的低频全局流程。

## 7. 设计决策记录

## 7.1 为什么保留手写 Web IDE

1. 这条线的迭代速度比 Flutter 更快。
2. 更适合高频试验编辑器交互和布局。
3. 更容易做 DOM 级几何测量与调试。

## 7.2 为什么 Theme / Editor 分成两个 surface

1. `Theme` 管的是整个页面壳。
2. `Editor` 管的是编辑器内部语义和视觉。
3. 两者有交集，但不应该共享同一个状态块。

## 7.3 为什么保留模板和导入配置

1. 配置不能只存在 UI 里。
2. 需要一份可导入/导出/审查的 canonical 配置。
3. 配置格式参考 VS Code，是为了可理解性和可迁移性，而不是为了兼容 VS Code 本身。

## 7.4 为什么不用浏览器原生弹窗

1. 原生弹窗和页面风格割裂。
2. 无法纳入统一设计语言。
3. 无法做复杂输入和一致的可访问性语义。

## 7.5 为什么文件树与设置面板不共享一套重绘

1. 作用域不同。
2. 触发频率不同。
3. 一起刷性能差，也更容易带来布局抖动。

## 8. 标准实现方法

## 8.1 新增一个设置项时

标准步骤：

1. 先判断它属于 `Theme` 还是 `Editor`
2. 再判断它属于：
   - `surface`
   - `section`
   - `leaf`
3. 如果它是预设型能力，先加模板，再加状态 key，再加 UI
4. 在 [surface-actions.js](../../prototype/editor-modules/surface-actions.js) 中声明动作
5. 按钮事件只调用统一 action 分发
6. 确认对应的 `persistTarget`
7. 确认对应的 `renderTarget`

## 8.2 新增一个主题色或 palette 时

1. 不要直接把颜色写死在事件里。
2. 先加到模板文件：
   - `theme-presets.js`
   - 或 `glyph-presets.js`
3. 再决定它属于：
   - `Theme`
   - `Editor`
   - `Block / Line / Selection`
4. 最后让 UI 读取模板。

## 8.3 新增一个 glyph 或 symbol 行为时

1. 区分源码层和显示层。
2. 显示层替换必须可逆。
3. `Glyph Composition` 关闭后，应回退到原文本显示，而不是只关闭部分样式。
4. 样式颜色、字号、偏移尽量通过模板和 CSS 变量控制。

## 8.4 改布局时

1. 先找容器边界。
2. 明确谁负责滚动。
3. 禁止把滚动条和文本抢同一个布局槽。
4. 复杂视口应拆成：
   - 外层壳
   - 内容区
   - 独立滚动区

## 9. 标准工作流

## 9.1 改交互前

1. 先判断问题属于：
   - 结构
   - 视觉
   - 状态
   - 渲染
2. 先找现有模块落点，再决定是否新增模块。
3. 不允许直接在 `editor.js` 底部继续堆新行为，而不先判断是否应归入现有 action / render slice。

## 9.2 改代码时

1. 优先改模板与模块，不要先改事件。
2. 先让状态结构正确，再让 UI 读取状态。
3. 如果一个按钮切换的是模板，按钮本身就不该拼渲染逻辑。
4. 如果一个设置只影响 `leaf`，不要让它走整块 `surface` 渲染。

## 9.3 改完后

至少检查：

1. `node --check prototype/editor.js`
2. 新模块也要单独 `node --check`
3. `GET /editor.html -> 200 OK`
4. 相关模块资源返回 `200 OK`
5. 手动检查：
   - 抽屉开合
   - 主题切换
   - 文件树
   - 编辑器 block / line / selection
   - 配置导入/编辑
6. 检查所有子组件是否溢出父容器

## 10. 当前明确反模式

以下做法应视为错误：

1. 在按钮事件里直接调用多个 UI 同步函数。
2. 在同一个事件里同时写状态、写 DOM、写 CSS 变量、写持久化，而没有统一分发。
3. 让 `Block` 之类叶子样式误走整块 editor 刷新。
4. 让 `Theme` 或 `Editor` 的模式切换只改一部分文字、背景、线条，而不是整套模板一起切。
5. 用浏览器原生弹窗替代应用弹窗。
6. 让内部组件溢出侧边栏、弹窗或卡片容器。
7. 让视觉替换直接改写源码。

## 11. 推荐后续重构顺序

当前建议的下一步顺序：

1. 继续把 `Theme / Editor` 剩余细粒度行为并入统一 action 分发
2. 把 workspace 低频流程拆进单独的 `workspace-session` 控制器
3. 把 editor 几何测量与 block overlay 的重排逻辑再独立一层
4. 补局部行为测试清单，至少覆盖：
   - `surface` action
   - `section` action
   - `leaf` action
   - 配置导入后的状态恢复

## 12. 一句话原则

1. 模板先于按钮。
2. 状态先于渲染。
3. 作用域决定刷新范围。
4. 子组件永远服从父容器。
5. 源码永远高于视觉替换。
