# 隐私说明 / Privacy

NetDock 不提供账号或云服务，不收集遥测，不接入广告、分析或推送 SDK。用户指定 TCP/UDP 地址或监听端口后，App 才启动对应网络通信；系统可以为用户输入的主机名进行 DNS 解析。

会话配置与语言、外观偏好仅保存在本机 App 沙盒。通信载荷可能包含敏感数据，默认只进入有界内存日志；退出 App 后消失，不自动上传或写入磁盘。复制操作仅由用户明确触发。快捷指令由用户主动保存到本地。用户可主动导出包含原始载荷的 TXT/JSON 日志、会话配置或 CSV/JSON 监控快照；分享前应检查敏感内容。

macOS 开启 App Sandbox 与入站/出站网络权限，不申请 iCloud、组播、VPN、Network Extension 或额外后台能力。移动端局域网权限用途说明随 App 提供简体中文与英文；操作系统决定权限弹窗实际语言。用户可在系统设置管理权限。进入后台会主动停止移动端会话，不保证后台监听。

NetDock has no accounts, cloud backend, telemetry, advertising, analytics, or push SDKs. It communicates with destinations specified by the user. Session configuration and interface preferences remain local. Raw traffic stays in bounded memory and is not automatically persisted or uploaded. Copy actions are initiated by the user. Named commands are saved locally on request. Users may explicitly export raw logs, session configuration or connection metadata; review sensitive contents before sharing.

The Mac app is sandboxed with inbound/outbound network entitlements. Mobile apps include localized Local Network usage descriptions and stop sessions on entering the background. No continuous background operation, multicast, iCloud, VPN, or Network Extension capability is requested.

网络连接监控仅在 macOS 运行，使用公开 libproc 与 sysctl 接口读取 TCP/UDP 端点和可用的进程归属，无载荷捕获、流量拦截或关闭其他进程连接操作。快照在有界内存中，不自动写盘、不上传。权限不足时保留未知归属和明确的覆盖范围。

The macOS-only monitor reads public libproc/sysctl connection metadata and available process attribution. It neither captures payloads nor intercepts traffic or terminates connections. Snapshots remain bounded in memory unless explicitly exported; inaccessible attribution stays unknown.

独立 DNS 工具只在用户点击查询后向选择的解析服务器发送查询名和类型，默认服务器为 1.1.1.1:53；结果只在当前页面内存中。TLS 使用系统信任与服务器名称验证，不绕过证书校验。

The DNS tool sends query names and types to the selected resolver only on request (default 1.1.1.1:53). Results remain in page memory. TCP Client TLS uses system trust and hostname verification. No private keys or client identities are stored by this extension.

### 数据保留与权限管理 / Retention and permission controls

可在会话列表删除保存的会话，在相应面板删除快捷指令或清空当前会话日志。在 iPhone 或 iPad 上选择「删除 App」可移除 App 的本机数据。主动导出的文件保存在您选择的位置，可在该位置删除。您可以在系统的「隐私与安全性」→「本地网络」中关闭 NetDock 的访问权限。

您主动连接或查询时，目标设备、服务或 DNS 解析商会收到对应请求，并按其自身政策处理。您可以修改目标地址或 DNS 服务器，或停止会话。NetDock 开发者不接收这些请求或日志。

You can delete saved sessions from the session list, delete saved commands from their panel, and clear traffic logs within a session. On iPhone and iPad, choosing Delete App removes the app’s local data. Exported files can be deleted from the location you chose when saving them. You can revoke NetDock's local network access in the system's Privacy & Security → Local Network settings.

When you initiate a connection or lookup, the destination device, service, or DNS resolver receives the relevant request and handles it according to its own policies. You can change the destination or DNS server, or stop the session. The NetDock developer does not receive these requests or logs.
