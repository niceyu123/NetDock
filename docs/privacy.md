# 隐私说明 / Privacy

NetDock 不提供账号或云服务，不收集遥测，不接入广告、分析或推送 SDK。用户指定 TCP/UDP 地址或监听端口后，App 才启动对应网络通信；系统可以为用户输入的主机名进行 DNS 解析。

会话配置与语言、外观偏好仅保存在本机 App 沙盒。通信载荷可能包含敏感数据，默认只进入有界内存日志；退出 App 后消失，不自动上传或写入磁盘。复制操作仅由用户明确触发。快捷指令由用户主动保存到本地。用户可主动导出包含原始载荷的 TXT/JSON 日志、会话配置或 CSV/JSON 监控快照；分享前应检查敏感内容。

macOS 开启 App Sandbox 与入站/出站网络权限，不申请 iCloud、组播、VPN、Network Extension 或额外后台能力。移动端局域网权限用途说明随 App 提供简体中文与英文；操作系统决定权限弹窗实际语言。用户可在系统设置管理权限。进入后台会主动停止移动端会话，不保证后台监听。

NetDock has no accounts, cloud backend, telemetry, advertising, analytics, or push SDKs. It communicates with destinations specified by the user. Session configuration and interface preferences remain local. Raw traffic stays in bounded memory and is not automatically persisted or uploaded. Copy actions are initiated by the user. Named commands are saved locally on request. Users may explicitly export raw logs, session configuration or connection metadata; review sensitive contents before sharing.

The Mac app is sandboxed with inbound/outbound network entitlements. Mobile apps include localized Local Network usage descriptions and stop sessions on entering the background. No continuous background operation, multicast, iCloud, VPN, or Network Extension capability is requested.

网络连接监控仅在 macOS 运行，使用公开 libproc 与 sysctl 接口读取 TCP/UDP 端点和可用的进程归属，无载荷捕获、流量拦截或关闭其他进程连接操作。快照在有界内存中，不自动写盘、不上传。权限不足时保留未知归属和明确的覆盖范围。

The macOS-only monitor reads public libproc/sysctl connection metadata and available process attribution. It neither captures payloads nor intercepts traffic or terminates connections. Snapshots remain bounded in memory unless explicitly exported; inaccessible attribution stays unknown.
