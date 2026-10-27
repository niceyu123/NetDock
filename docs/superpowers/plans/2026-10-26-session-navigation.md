# 会话新建与顶部连接参数 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 左侧常驻四个 TCP/UDP 入口，点击直接新建对应类型会话，在当前工作台直接编辑常用端点参数；不通过「＋」或二级菜单。

**Architecture:** 保留 NavigationSplitView、SessionEditor 和 SessionManager。端点草稿置于 SessionRuntime，顶部字段绑定同一份草稿；AppModel.saveEndpoint/startSession 统一顶部及侧栏的校验、持久化和启动入口，继续复用 EndpointInput、SessionConfig.validated 与 AppModel.save。

**Tech Stack:** 原生 SwiftUI、Network.framework、本地 NetDockCore，无新增依赖。

**Spec:** `NetDock_V1_Codex_开发规格书.md` §4；用户明确要求 TCP/UDP 四个入口直接放左侧菜单栏，下方保留具体会话。

## Global Constraints

- macOS 原生 Target，iPhone/iPad 共用 Universal Target；按窗口宽度自适应。
- 保留现有接口与真实 TCP/UDP 能力；不增加 UDP 组播或其他网络工具。
- 简中/英文、动态外观、键盘和辅助功能标签。
- 保留任务开始前的连接监控、字符串目录和 UI 测试修改。
- 本次直接在现有工作区实施，不创建提交或移动用户未提交工作。

## Review Focus

- 左侧四个常驻入口预选正确，UDP Client 默认自动分配本地端口；取消不创建会话。
- 非法主机/端口不能保存，也不能通过连接按钮启动旧端点。
- 连接/监听中禁用端点编辑，保存时仍检查实际运行状态。
- 会话切换不停止连接，端点修改持久化且不覆盖编码等其他配置。
- iPhone 键盘与窄窗口仍可操作，macOS/iPad 主工作区保持日志与发送区域。

### Task 1: 新建入口与模式预选

**Files:** `Shared/Features/Sessions/RootView.swift`、`SessionEditor.swift`、`Tests/NetDockUITests/WorkspaceUITests.swift`。

- [x] 添加左侧四种模式常驻、预选及取消的 UI 验证，检查不存在旧「＋」入口。
- [x] 使用系统 List Section 内四个 Button 直接新建；移除工具栏「＋」，保留菜单栏快捷键默认创建 TCP Client。
- [x] 复用现有 SessionEditor，UDP Client 初始 localPort 为 0。

### Task 2: 顶部端点编辑

**Files:** `Shared/Features/Workspace/WorkspaceView.swift`、`Shared/Features/Sessions/AppModel.swift`、`SessionManager.swift`、`Tests/NetDockUITests/WorkspaceUITests.swift`。

- [x] 添加非法端口/主机、真实 TCP 回显、运行锁定及保存后重启的 UI 验证。
- [x] 顶部展示协议、客户端主机、远端/本地端口；草稿改变时可保存，启动前先校验保存。
- [x] 同步外部端点及运行锁定变化，保持高级编辑入口，iOS 提供收起端点键盘按钮。

Ruling: 草稿从 View 状态调整到 SessionRuntime，顶部与侧栏通过 AppModel 统一保存后启动；原因是侧栏原始启动入口会绕过 View 内草稿，并且切换详情会销毁局部草稿。只读复核已确认共同入口覆盖，新增右键非法草稿断言。

### Task 3: 验证与交付

- [x] 执行 `swift test --package-path Packages/NetDockCore`，保留已有失败，详见验证记录。
- [x] macOS 与 iOS Simulator `xcodebuild` 构建。
- [x] 功能阶段 macOS/iPhone/iPad 实际 UI 操作、真实通信与截图；最终视觉轮按用户要求只做必要构建和 macOS 点按截图，不继续扩大测试。
- [x] 检查差异及本地化；在 `docs/testing-session-navigation.md` 记录结果、未验证项和下一阶段。

Ruling: 用户要求先减少测试并重新设计侧栏。最终将四个创建动作与监控统一放入「工具」分组，采用无灰色按钮背景的原生侧栏行；监控通过 NavigationLink 使用系统选中状态，会话改为两行。最终样式不重新执行自动化套件。

## Baseline

- 任务开始时 `Scripts/check_localization.rb` 已失败：字符串目录中已有自动提取的格式串及通用标签缺少显式双语条目。本次复用现有本地化 key，不改写用户已有字符串目录。
- 原始未提交差异已备份到 `/tmp/netdock-session-ui-before.patch`，仅用于核对是否保留，不作为产品内容。
