# NetDock · 网络工作台

[English](README.en.md)

免费开源的 Apple 原生网络调试工具。使用 Swift、SwiftUI、Network.framework，无第三方运行时依赖。

当前已在原工程增量加入 **M2 UDP + M3 调试工作台**，并新增仅 macOS 可用的网络连接监控。真机局域网、最低系统版本和完整无障碍验收仍需补充，实际验证见测试记录。

## 运行

macOS App 仅支持 Apple 芯片（arm64），不支持 Intel Mac。需要 Xcode 16 或更新版本及 Swift 6；本次实际使用 Xcode 27.1 / Swift 6.4。最低系统为 macOS 14、iOS/iPadOS 17。

```sh
open NetDock.xcodeproj
```

选择 `NetDockMac` 后在本机运行；选择 `NetDockMobile` 后在 iPhone/iPad 模拟器或真机运行。真机需自行配置唯一 Bundle ID、Development Team 与签名。仓库没有个人开发者凭据。macOS 开发构建使用本地 ad-hoc 签名，启用 App Sandbox 入站/出站权限；不等同于 App Store 发布签名。

工程文件已包含在仓库内，直接用 Xcode 打开即可。新增源文件后可执行 `ruby Scripts/generate_project.rb` 重新生成工程，仅使用 Ruby 标准库，不需要 XcodeGen 或第三方 gem。共享网络 Package 也可独立打开与测试。

## 已实现

- 独立会话的新建、编辑、复制、删除及本地 JSON 保存；切换会话不影响连接。
- TCP Client：主机名/IPv4/IPv6，连接、断开、串行有界发送、持续接收、连接超时和分类错误。
- TCP Server：端口监听、多客户端接入、真实远端/本地端点、定向发送、广播给已连接客户端、独立断开；停止监听关闭已接入连接。
- UDP Client / Server：IPv4/IPv6 单播、指定本地 IP/端口、实际端点、保持完整数据报、多来源定向回复和服务端指定目标发送；UDP 无连接语义。
- 最低 100ms 周期发送、有限/连续次数、暂停/恢复/停止；停止会话、网络失败或移动端进入后台时取消。
- 快捷指令保存/重命名/删除/复用、当前会话有界发送历史、日志查询和方向筛选、TXT/JSON 日志导出、JSON 会话配置导入导出。
- macOS 原生 Table 网络连接监控：自动/暂停/手动刷新、搜索/过滤/排序、变更高亮、详情/复制、可见端口查询、CSV/JSON 导出；系统权限限制见 [监控说明](docs/connection-monitor.md)。
- UTF-8 与 HEX 发送，HEX 空白与大小写容忍、错误字符位置；原始 `Data` 日志、微秒时间展示、TX/RX/SYS 区分、HEX 偏移、复制、清空、自动滚动。
- 默认简体中文，应用内即时切换 English；跟随系统/浅色/深色，重启保留偏好。
- macOS 侧栏与可收起的参数/发送面板；iPad 依可用宽度自适应；iPhone 单栏工作台、客户端面板和底部编辑区。

快捷键：`⌘N` 新建、`⌘K` 连接/停止、`⌘Return` 发送、`⌘L` 清空当前会话日志。

## 本机通信

1. 新建 TCP Server，例如监听端口 `9000`，点击开始监听。
2. 新建 TCP Client，主机 `127.0.0.1`（IPv6 可用 `::1`），端口 `9000`，点击连接。
3. 在客户端发送 UTF-8 或 `00 FF 41 42` HEX；切换服务端查看 RX，再选择客户端回复或广播。
4. 可同时创建多个客户端。停止服务端会关闭这些 TCP 连接。

TCP 是字节流，一次发送可能对应多次底层读取，多次发送也可能合并。RX 日志记录读取 chunk，不代表应用协议的完整消息。UTF-8 字符也可能跨读取分割；某一 chunk 不能独立解码时明确提示并保留完整原始字节，可切换 HEX。发送完成仅表示本机网络 API 已处理数据，不代表远端应用确认收到。

UDP 本机调试：创建 UDP Server 监听 `9001`，再创建 UDP Client 指向 `127.0.0.1:9001`（本地端口留空自动分配）。发送 `00 FF E4 B8 AD` HEX，服务端从来源列表选择客户端回复。UDP TX 仅表示本机 API 接受数据，不表示对端收到；收到的数据报逐条保留边界。

## 验证

```sh
./Scripts/verify.sh
# 有可用模拟器时运行 UI 测试（会启动真实 TCP echo 服务）
xcodebuild -project NetDock.xcodeproj -scheme NetDockMac \
  -destination 'platform=macOS,arch=arm64' test
xcodebuild -project NetDock.xcodeproj -scheme NetDockMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

UI 测试使用独立的 `NetDock-UITests` 目录和偏好，不替代真实网络、不预置通信成功状态。实际执行结果、截图与未验证项见 [测试记录](docs/testing.md)。设备名称以 `xcrun simctl list devices available` 为准。

## 数据与权限

保存会话配置、主动保存的快捷指令及语言/主题/编码/周期设置偏好，不保存原始通信日志到磁盘。会话文件位于沙盒 Application Support 的 `NetDock/sessions.json`；原子保存，保留上次有效 `.backup`，损坏原文件在后续保存时保留为 `.damaged`。快捷指令保存至同目录的 `commands.json`。发送历史仅在有界内存保留；快捷指令与导出均由用户主动操作。导入会分配新 UUID，不替换或自动启动已有会话。

每个会话的内存日志最多 5,000 条或 30 MiB 载荷，先达到者淘汰最早记录；UI 最多每 100 ms 批量刷新，TCP 待发送队列最多 16 MiB、128 个客户端；UDP 最多 128 个流与 4 MiB / 128 个挂起发送。UDP 单次发送最多 65,507 字节。输入和通信内容可能敏感，请谨慎复制与导出。

无账号、云同步、广告、遥测或远程后台；网络数据只发送给用户指定的地址。iOS/iPadOS 包含中英局域网用途说明；系统权限弹窗语言由系统决定。移动端进入后台时主动停止全部会话，不保证后台监听，返回前台需手动启动。详见 [隐私说明](docs/privacy.md)。

TCP 自动重连仍未实现，M4 继续做稳定性与发布准备。没有 DNS 查询、Ping、Traceroute、扫描、TLS 或其他扩展工具。正常 TCP 连接可由系统解析用户输入的主机名。

## 设计与许可

原生系统组件优先。已阅读本机 `apple-design` Skill，但它是 Web/CSS 同名版本；根据规格书第 4.4 节，原生布局直接参考 [Apple HIG](https://developer.apple.com/design/human-interface-guidelines/layout)，设计记录见 [docs/design.md](docs/design.md)。

按规格书建议采用 MIT 许可证，见 [LICENSE](LICENSE)。项目尚未完成 V1 全量 DoD，也未提交 App Store。
