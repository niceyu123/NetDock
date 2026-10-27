# macOS Connection Monitor

本阶段增加原生 macOS 连接监控。监控是只读的，不终止进程、不修改 socket，不影响现有 TCP/UDP 会话。所有采集与差异历史默认只在有界内存中保留；仅用户主动选择 CSV/JSON 导出时写入其选择的文件。

## 真实数据来源与权限结论

产品使用两种 SDK 公开接口：

- `proc_listallpids`、`proc_pidinfo(PROC_PIDTBSDINFO / PROC_PIDLISTFDS)`、`proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`：读取允许访问的进程及其真实 socket，取得进程名、PID、进程出生时间、FD、socket token 和 generation。
- `sysctlbyname("net.inet.tcp.pcblist64")` 与 `net.inet.udp.pcblist64`：按 SDK 公开的 `xinpgen`、`xtcpcb64`、`xinpcb64`、`xsocket64` 解析系统允许读取的 TCP/UDP IPv4/IPv6 端点与 TCP 状态。未使用 `pcblist_n` 私有 ABI、固定猜测偏移、`lsof` 子进程、提权或沙盒例外。

相关公开定义位于 macOS SDK 的 `libproc.h`、`sys/proc_info.h`、`netinet/in_pcb.h`、`netinet/tcp_var.h`、`sys/socketvar.h`，Swift 通过 `Darwin` 导入，无第三方依赖，无需额外 C target。

在保留项目 App Sandbox、network client/server 权限的临时 ad-hoc 签名 `.app` 中真实验证：

| 验证 | 实际结果 |
| --- | --- |
| `proc_listallpids` | 返回 0，`EPERM`；产品回退读取自身 PID |
| 已知其他进程的 `PROC_PIDLISTFDS` | 返回 0，`EPERM`；其 BSD 基本信息可读不等于其 FD 可读 |
| 自身 `PROC_PIDTBSDINFO` | 136 字节，成功 |
| 自身 TCP / UDP `PROC_PIDFDSOCKETINFO` | 各 792 字节，成功；socket token 非零 |
| `tcp.pcblist64` / `udp.pcblist64` | size query 和实际 read 均成功，errno 0 |
| PCB record layout | `xinpgen` 24、`xtcpcb64` 472、`xinpcb64` 260 字节；逐条长度匹配 SDK，头尾均存在，解析字节数等于返回字节数，无猜测偏移 |

另用**当前产品 Monitoring 源码**编译探针，在相同沙盒并启用 hardened runtime 后创建 4 个真实本地测试 socket。仅输出下列聚合指标，不记录进程名、PID、IP、端口、设备信息或原始 PCB 数据：

- fixture socket 4 个，真实映射成功 4 个；TCP / UDP 各 2，IPv4 / IPv6 各 2。
- 当次公开系统快照可读且头尾一致；可读进程 1 个、系统端点 416 个、未知归属 412 个、权限拒绝事件 1 个。
- 这些数量是一次验证的聚合结果，不是固定覆盖率或系统完整性保证。

系统 PCB 与 libproc 通过 socket token、generation、协议和地址族匹配，避免把已知自身 socket 重复显示成未知条目。公开 PCB 结构中的 `so_pgid` 是**进程组 ID**，不是 PID，产品从不将其作为归属。无法确认归属时，进程显示“未知（权限限制）”，PID、进程出生时间和 FD 为空；JSON 用 `null` 与 `attribution: unavailable` 表达，CSV 使用空值与明确的 attribution 列。

## 界面与行为

- 系统 SwiftUI `Table`，进程/PID、协议与 IPv4/IPv6、本地/远端 IP 和端口、TCP 状态、变化标记。列可调整宽度，可按列排序并通过 Shift 点击组合多列排序；端口和 PID 按数值排序。
- 9 列表头均有本地化字段说明；通过原生 AppKit `NSTableColumn.headerToolTip` 提供悬停提示。顶部“字段说明”弹出层提供同一份完整说明，支持键盘和辅助功能，解释通配地址、端口 0、权限限制、UDP 状态及消失标记的含义。SwiftUI macOS 14 的表头尚无自定义 View 标签 API，因此用局部 NSView 桥接公共 AppKit 属性，保留原表格的排序和列宽行为。
- 监控内容受实际窗口区域约束，表格仅占用剩余高度，避免原生表格的理想尺寸把搜索栏和筛选控件撑到可视区域之外。
- 搜索框按系统可读的服务/进程名、PID、本地/远端 IP 和端口、协议或 TCP 状态即时过滤，名称不区分大小写；空格分隔的关键词必须同时匹配。Command-F 聚焦，清空按钮或搜索框内 Escape 清空关键词，并保留协议、本地端口筛选。名称搜索仅使用真实可读的进程名，不推断未知归属或按端口猜测服务名称。
- TCP/UDP 协议筛选；指定本地端口精确查询。非法端口显示错误并不显示误导结果。通用端口关键词采用包含匹配（例如 `80` 也能匹配 `8080`）；需要精确本地端口时使用独立端口框。
- 1 / 2 / 5 秒自动刷新、暂停/继续、手动刷新（Command-R）。一次采集完成后等待所选间隔；不会同时启动两个采集，也不会在主线程执行 libproc/sysctl。
- 选择条目显示进程出生时间、FD、本地/远端端点及最后出现时间；详情和上下文菜单提供复制端点。IPv6 使用方括号格式，link-local 保留可用的数值 scope。
- 新增与状态/端点变化高亮 3 秒；不再可见的条目保留 5 秒。暂停时仍按时间消退，不会无限显示已消失条目。
- CSV/JSON 导出的是**当前筛选和排序后的可见结果**，通过系统保存面板选择位置。导出包含采样时间、可见范围与归属标记；JSON 另含聚合采集限制。CSV 采用 RFC 4180 引号/换行逃逸，并中和进程名中的公式前缀。不会导出内核 socket token。
- 使用现有动态中英文本地化与主题；系统字体、VoiceOver 标签、键盘焦点和原生交互。`apple-design` Skill 当前是 Web/CSS 版本，本实现直接参考 [Apple HIG Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables) 的原生 macOS Table 指引。

## 有界采集与失败处理

- 进程上限 65,536，每进程 FD 上限 65,536；每种协议 PCB buffer 上限 16 MiB；合并结果与差异历史最多 20,000 条。达到上限明确计入 `limitReached`，不宣称完整结果。
- 已知进程身份包含 PID 与微秒级出生时间，连接身份另含 FD、socket token、generation、协议与地址族，避免 PID/FD 复用混淆。未知归属身份使用 socket token、generation、协议与地址族，不使用随机 UUID。
- 读取进程前后再次核对出生时间。PCB 每条 record 的长度和数据边界必须与公开 SDK 结构匹配，必须存在完整头尾 marker。
- PCB 大小增长或头尾 generation 不一致会重试一次。TCP / UDP 任一采集失败、持续不一致或达到上限时，已有结果整体保留并显示过期提示，不把另一协议的条目整批误判为消失。最初尚无历史结果时可显示当前可读的部分，同时标明限制。
- libproc 与 PCB 都不可读时保留最后已知结果；仅 libproc 可读且从未获得系统快照时仍可显示真实自身范围。错误只归类为权限拒绝、进程/FD 消失、接口不可用、达到上限、读取不一致、取消，不自动记录实际端点或进程清单。

## 产品边界

页面始终显示可读范围与限制。`partialSystem` 表示**读到了公开系统端点，但无法保证全系统覆盖或完整进程归属**，不等于全系统连接清单。进程“可读 / 尝试”数量只反映本次 libproc 尝试范围；沙盒拒绝枚举时的 `1 / 1` 不代表系统只有一个进程。端口查询无结果不能证明端口空闲，也不应作为绑定许可或释放端口的依据。

libproc 以 FD 为入口，无法枚举已经失去 FD 引用的 TCP TIME_WAIT；公开 PCB 快照可能显示部分 TIME_WAIT，此时通常无法确认进程归属，但可见性仍取决于操作系统返回内容。不能保证所有 TIME_WAIT 均可见。轮询也可能错过短连接与短暂状态；TCP ESTABLISHED 是内核状态，不证明应用载荷送达。UDP 不展示虚构的 TCP 连接状态。

消失表示身份不再出现在一次可用快照中，也可能源于退出、归属可读性改变或系统过滤，不是 TCP 关闭的充分证据。实时监控本身不需要局域网探测权限；它观察系统允许读取的状态，不主动扫描远端。

## 文件与集成

- `Packages/NetDockCore/Sources/NetDockCore/Monitoring/ConnectionMonitor.swift`：数据与权限覆盖模型。
- `ConnectionMonitorCollector.swift`：actor 后台 libproc 采集与系统数据合并。
- `ConnectionMonitorSystemSnapshot.swift`：公开 PCB 读取、布局验证与解析。
- `ConnectionMonitorAddress.swift`：IPv4/IPv6 与 scope 解码。
- `ConnectionMonitorDiff.swift`：有界差异、筛选、多列比较器。
- `ConnectionMonitorExport.swift`：CSV/JSON 安全导出。
- `Packages/NetDockCore/Tests/NetDockCoreTests/ConnectionMonitorTests.swift`：真实 socket、差异与导出验证。
- `Apps/NetDockMac/ConnectionMonitorView.swift`：`ConnectionMonitorView()` 与独立 UI model，仅 macOS。

主集成负责 macOS 导航入口、将 `/tmp/netdock-monitor-localizations.json` 的键值合入资源、macOS 文件选择读写 entitlement、工程生成和最终启动截图。不需要修改 Package targets 或 AppModel。所有 Monitoring Swift 文件均受 `#if os(macOS)` 保护，不向 iPhone/iPad 暴露入口。

UI 关键标识为 `monitorTable`、`monitorRefresh`、`monitorPause`、`monitorInterval`、`monitorSearch`、`monitorProtocol`、`monitorPortQuery`、`monitorExport`、`monitorScope`。验证截图应先筛选专用测试 listener 的端口，仅保留合成测试连接，避免将真实系统连接清单存入仓库。

## 验证记录

- 测试先行：真实 socket 的首个测试在空采集实现上出现预期 `XCTUnwrap` 失败；差异/筛选/导出出现 9 个预期断言失败；新增系统数据与单协议失败保留测试也先出现预期失败，再实现通过。
- 独立监控测试：11 项 / 0 失败，包含真实 IPv4/IPv6 TCP/UDP、公开 PCB 布局与实际端点匹配、libproc 归属映射去重、未知归属 JSON null、PID/FD 复用、状态变化、消失过期、历史上限、读取失败保留、PCB 截断/generation 不一致、导出逃逸、数值多列排序和筛选。
- `swift test --package-path Packages/NetDockCore --scratch-path /tmp/netdock-monitor-tests`：56 项 / 0 失败，日志 `/tmp/netdock-monitor-full-tests.log`。随后补充真实 ESTABLISHED TCP 与 connected UDP 的远端 IPv4/IPv6 端点测试，正在运行最新完整回归；以主交付记录的最终结果为准。
- Swift 6 / macOS 14 的独立 `swiftc -typecheck` 已通过当前完整 Monitoring 模块及 View；View 类型检查使用临时 AppModel/Clipboard 接口，仅证明编译接口，不冒充完整 App 构建或 UI 运行。
- macOS 整体 `xcodebuild`、真正启动/操作/截图与系统保存面板验证由主集成继续；未在本子任务中虚构这些验证结果。无 Git 提交或 push。
