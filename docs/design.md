# 原生界面设计与执行依据

已加载本机 `apple-design/SKILL.md`。该版本明确面向 Web/CSS 动效，并不是规格书推荐的原生 SwiftUI/HIG Skill。因此不将其 Web 视觉示例应用到产品；直接读取 Apple 官方 [Layout HIG](https://developer.apple.com/design/human-interface-guidelines/layout) 和 [Network.framework](https://developer.apple.com/documentation/network) 资料。Skill 不作为运行时依赖打包。

## 三端线框与组件

macOS：`NavigationSplitView` 左侧系统 List（会话名称、TCP 类型、端点、实时状态）→ 中央状态条与通信 List → 右侧可收起的连接参数、客户端、发送区。详情可用宽度不足 780pt 时，发送区转为底部，连接参数通过 sheet 展示。默认窗口 1180×760pt，最小 760×520pt。macOS 菜单新建与工作台快捷键均可用。

```text
macOS / 宽 iPad
┌ 会话侧栏 ┬ 状态 / 连接按钮 ──────┬ 参数 / 编辑 ┐
│ 模式入口 │ 时间 · RX/TX · 字节数  │ 客户端列表   │
│ 会话列表 │ 原始数据通信日志       │ UTF-8 / HEX  │
│          │ 编码 / 自动滚动 / 清空 │ 编辑器 / 发送│
└──────────┴───────────────────────┴─────────────┘
```

iPad：相同的 NavigationSplitView 自适应收敛，依当前窗口可用宽度展示右侧面板，不根据设备型号强制三栏。竖屏和分屏可隐藏侧栏或以列表→详情导航；外接键盘使用同一套快捷键。

iPhone：列表→详情单栏。顶部状态和连接控制；中间可滚动 List；底部 SwiftUI TextEditor 与发送按钮。保留系统键盘安全区，不忽略键盘 inset。Server 的客户端列表通过 sheet 展示，发送对象 Picker 始终明确标识“所有已连接客户端”或指定端点。所选客户端离开后显示失效选项，不隐式改成群发。

```text
iPhone / 窄窗口
┌ 返回 / 会话名称 / 参数 ┐
│ 状态           连接   │
│ 端点         TX/RX B  │
│ UTF-8 / HEX   日志操作│
│ 可滚动通信日志        │
│ 客户端 / 发送目标     │
│ 发送编码             │
│ TextEditor           │
│ 字节数          发送 │
└ 系统键盘安全区 ───────┘
```

## 交互状态

- 无会话：ContentUnavailableView + 真实新建操作；无虚构样例数据。
- 未启动/已停止：可编辑配置；发送禁用。
- 连接中：文字与 ProgressView，允许停止；发送禁用。
- 已连接：真实 NWConnection.ready，启用发送；显示实际累计字节。
- 监听中：真实 NWListener.ready，显示客户端数；没有客户端时广播禁用。
- 日志为空：明确 TCP 字节流/读取 chunk 说明。
- 失败/无网络权限：分类本地化错误摘要与底层诊断，提供检查权限/端口/网络的操作建议；允许重新启动。
- HEX 输入错误：发送时显示字符位置，原输入保留，不悄悄丢弃数据。

## 字体、颜色和辅助功能

采用系统字体、SF Symbols、语义前景/背景和原生 Form/Picker/Toolbar。时间、端点、HEX 和偏移使用等宽字体。TX/RX/SYS 有文字标签，颜色仅辅助。文本支持选择与原始载荷复制，不做纯装饰动效。ViewThatFits 在空间或字体变大时允许状态控制纵向排列。图标操作均有本地化 label/help，工作台状态和编辑器有明确 accessibilityIdentifier。

所有产品文案通过 String Catalog 的 zh-Hans/en Bundle 即时选择；根 locale 与 preferredColorScheme 同步，偏好跨重启保存。系统管理的菜单项与权限弹窗仍可能遵循系统语言；不得宣称已经覆盖系统 UI 的即时语言切换。

实际构建、运行、截图检查范围及仍需人工验证的 Dynamic Type、VoiceOver、Reduce Motion、真机键盘/窗口尺寸，见 testing.md。

## 会话新建与端点编辑（2026-10-26）

左侧顶部「工具」分组常驻 TCP Client、TCP Server、UDP Client、UDP Server 四个入口，点击直接打开预选模式的配置页，不经过「＋」或二级菜单。macOS 网络连接监控与四个入口放在同一分组。下方「网络会话」展示已保存的具体会话。取消不创建会话；菜单栏 Command-N 继续默认创建 TCP Client；UDP Client 初始本地端口留空，由系统自动分配。空会话状态仍完整显示四个入口，不用覆盖式空状态遮挡导航。

侧栏统一采用系统 `.sidebar` List 样式。四个创建动作使用整行可点的 plain Button，移除灰色胶囊背景；图标分别为 TCP Client 的向外箭头、TCP Server 的机架、UDP Client 的纸飞机、UDP Server 的接收托盘，保持系统强调色。监控使用原生 NavigationLink 和统一的类型化侧栏选择值，选中时由系统显示高亮；不绘制假导航背景。会话收紧为两行：名称与状态在第一行，协议与端点在第二行，端点中间截断保留端口尾部。名称、状态、图标都保持系统字体与语义颜色。

macOS、宽 iPad 保留会话列表／日志／可折叠辅助面板。工作台顶部增加协议、客户端主机和远端端口（Server 则为本地监听端口）输入框。详情窄于 780pt 时保持底部发送区；iPhone 仍为列表→详情，在顶部编辑端点，通过键盘「完成」收起键盘。接收显示设置和发送设置继续靠近对应工作区，不移入会话导航。

端点编辑先在会话运行模型中保留草稿，明确点击「保存」或连接／监听时复用既有校验与持久化流程，顶部及侧栏右键启动共用同一入口。非法地址、端口在字段下方显示错误，保留草稿，不启动旧配置。运行及启动过程中字段禁用并显示锁定标识，停止后重新开放。其他窗口修改已保存端点时同步配置；更改收发编码不会覆盖未保存端点。高级本地绑定参数和会话名称仍通过原有编辑页设置，切换会话保留草稿且不停止网络。

本阶段实际验证、基线失败与未验证项见 `testing-session-navigation.md`。
