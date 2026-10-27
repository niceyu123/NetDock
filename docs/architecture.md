# 架构

`NetDock.xcodeproj` 包含 `NetDockMac`、`NetDockMobile` 两个 App Target，以及各自的 XCUITest Target。macOS 使用 AppKit 宿主的原生 SwiftUI，移动端为一个支持 iPhone 与 iPad 的 iOS Universal Target，未启用 Catalyst。

macOS App 及其 UI 测试 Target 的 Debug、Release 均固定为 Apple 芯片的 `arm64`；移动端架构设置独立，不受此限制。

- `Apps/`：平台 App 入口和沙盒配置。
- `Shared/Features/Sessions/`：`AppModel` 管理偏好、JSON 配置；`SessionManager` 持有各会话的 `SessionRuntime`，独立于导航 View 的生命周期。
- `Shared/Features/Workspace/`：只依赖运行时业务模型；状态、日志、发送编辑器和客户端管理分别为组件，不持有 Network.framework 对象。
- `Shared/Features/Settings/`、`Shared/Theme/`：语言、主题与设置；本地化 Bundle 显式选择，不依赖设备语言。
- `Packages/NetDockCore/`：Swift 6 Package，包含纯数据配置、校验、错误、编解码、日志环形缓冲、版本化 JSON Repository 和真实 TCP/UDP 实现及 macOS 条件编译的监控采集。

## 并发与网络生命周期

`TransportService` 定义 start/stop/send/disconnect。`TCPService` 根据 TCP Client/Server 模式选择 `NWConnection` 或 `NWListener`；采用一个网络执行器统一收发与生命周期，避免重复两套 TCP 字节流逻辑。UDPService 使用 NWConnection + receiveMessage 和 NWListener(.udp)，保留数据报边界。UDP Server 的已接收流用于来源回复，显式目标流通过 allowLocalEndpointReuse 共用监听端口；监听器自身不启用 reuse，以便重复占用端口正确报错。

每个 TCPService / UDPService 有私有串行 DispatchQueue；所有 NW 对象、连接字典、发送队列、回调均在该队列。`@unchecked Sendable` 仅用于明确有队列/锁保护的容器，View Model 使用 `@MainActor`。不同会话使用独立服务和队列。

一次 start 创建 UUID 代次；清理立即更换代次，旧回调不能写入下一轮会话。重复启动活跃服务不创建第二个监听/连接，重复停止幂等。监听停止会取消全部已接入客户端，并等待 NWListener 的 `.cancelled` 才完成，防止快速重启时端口尚未释放。失败也会清理，下一次 start 等待取消完成。

客户端 `.ready` 才开始持续 receive，回调保留每个底层 chunk 原始 Data，处理 EOF/错误后停止；每次读取最大 64 KiB。连接超时默认 15 秒；waiting/failed 会立即进入失败状态并给出分类错误。本轮自动重连关闭且没有后台重试 Task。

服务端维护稳定 UUID 的客户端，ready 后才加入可发送列表；保留当前 path 提供的真实端点。定向发送在服务层验证 ID。广播为每个已就绪客户端分别提交和记录结果，单个客户端错误不会停止监听。

发送从同一串行队列依次调用 NWConnection.send，保证每个连接的提交顺序。并发请求受总计 16 MiB 待发送载荷限制；拒绝空载荷与未就绪发送，停止时完成全部挂起发送，避免 continuation 残留。

## 日志与 UI

网络回调通过同步、线程安全的事件 sink 写入 `SessionTrafficStore`，不在每次收包时创建 Task 或积压无界 AsyncStream。其 NSLock 保护状态、客户端、计数和 `TrafficBuffer`。

环形缓冲固定上限 5,000 条、30 MiB 原始载荷，先达到者淘汰最早记录。总累计字节统计与窗口淘汰独立，采用饱和加法。`SessionManager` 每 100 ms 取变化快照并在 MainActor 发布；页面切换不会销毁运行时。List 延迟展示日志，默认每行最多预览 512 字节，可展开和复制原始完整数据。

SYS/错误与 RX 数据分开，失败的 send 记录错误而不累计成功发送字节。TCP 读取不推测应用消息边界。非 UTF-8 chunk 不替换或丢弃，明确提示使用 HEX。

## 存储与平台

配置无 NWConnection、Task 或队列字段。JSON schemaVersion=1，写入前校验、原子替换、保留前次有效备份；读取损坏时显式恢复/报错。没有自动落盘日志。语言与外观使用 UserDefaults；QuickCommand 用独立有版本的 CommandRepository 原子保存并保留备份。SessionTransfer 校验导入的版本、字段、重复 UUID、5MiB / 1000 条上限，AppModel 重新分配身份以保护活跃会话。TXT/JSON 日志导出只由用户触发，通过系统 FileExporter 保存。

移动端进入 background 后主动停止所有会话，返回时需手动启动；没有声明后台模式。macOS 保留多窗口共享的 AppModel 和 SessionManager。多窗口独立选中会话，偏好与连接状态共享。

新建和编辑面板属于各窗口。保存配置先成功落盘再更新会话列表；写入失败保留编辑器草稿。活跃会话的端点与模式不仅在入口处禁用编辑，也在保存时重新校验，以防另一个窗口在编辑期间启动连接。名称、显示编码等非网络偏好仍可更新。

## M3 调度与监控边界

PeriodicSender 在 MainActor 上维护单一任务、runID 和 taskID。新任务等待旧的已提交操作完成；暂停保留计数，停止或重启使旧结果失效。运行循环捕获启动时的载荷/目标，避免编辑器变化把循环发向其他来源。Runtime 的 stop 先取消调度再停止传输以解除挂起发送。历史最多50条/1MiB，单条超过64KiB不加入历史；原始日志仍受独立环形上限约束。

监控模块与 TransportService 相互独立，只读取系统快照，无关闭连接或杀进程操作。核心实现放在 Monitoring/ 并以 macOS 条件编译；Table 页面只编入 NetDockMac。异步采样、刷新去重、稳定连接身份与有限时间的消失记录，详见 connection-monitor.md。
