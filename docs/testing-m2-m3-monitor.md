# M2 / M3 / macOS 监控本地交付验证

日期：2026-10-26（Asia/Shanghai）。本记录针对合入 `master` 的当前代码快照，不代表完整产品验收通过。

## 交付范围

- UDP：`Packages/NetDockCore/Sources/NetDockCore/UDP/UDPService.swift`，以及 Models、Transport、TCP 兼容调整和 UDP 集成测试。
- 工作台：Core 的 Logging、Sending、Persistence、QuickCommand，以及 Shared 下的会话导入导出、周期发送、日志筛选与统计界面。
- macOS 连接监控：Core 的 Monitoring、`Apps/NetDockMac/ConnectionMonitorView.swift`、沙盒用户选择文件权限及相关测试。
- 工程与资源：Xcode 工程、生成脚本、应用图标、中英本地化、README 和架构/隐私文档。

## 本次实际验证

- `swift test --package-path Packages/NetDockCore`：执行 60 个 XCTest，57 个用例通过，3 个用例失败（共 5 个断言失败），退出码 1。TCP、UDP、监控及其余核心套件通过；失败集中于 `WorkbenchRegressionTests`。
- `ruby Scripts/check_localization.rb`：244 个键，中英及全部错误码检查通过。
- `ruby -c Scripts/generate_project.rb`：语法检查通过。
- `git diff --check`：通过。
- macOS Debug 构建：`xcodebuild -quiet -project NetDock.xcodeproj -scheme NetDockMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`，退出码 0。此为禁用签名的编译验证。
- iOS Simulator 首次构建与 macOS 共用默认 DerivedData，因构建数据库锁退出 65；待 macOS 结束后单独重跑，结果见下文。
- iOS Simulator 单独重跑：`xcodebuild -quiet -project NetDock.xcodeproj -scheme NetDockMobile -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`，退出码 0。

## 已知失败

1. `testLargeBinaryNonmatchingSearchDoesNotFormatWholePayload`：4 MiB 二进制日志搜索耗时约 7.14 秒，超过 2 秒断言；跨换行 HEX 搜索也未匹配。
2. `testServerDurationCountsWhileSourcesAreConnectedAndFreezesAfterLastPeer`：TCP Server 有客户端接入后，连接时长仍为 0。
3. `testTCPDoesNotClaimAnUnsupportedUDPBindAddressAfterModeConversion`：从 UDP 切为 TCP Server 后仍保留 `::1` 本地地址，显示为 `[::1]:9000`，而非实际支持的通配绑定显示。

此次任务为合并及本地 Git 提交，保留上述失败测试和实现供后续修复，没有删除断言或改动功能来掩盖失败。

## 未验证与下一步

- 本次未重跑 UI 启动、操作与截图，不以编译成功替代 UI 验收；既有 M0/M1 记录仅见 `testing.md`，不能直接套用于新增功能。
- 未验证真机局域网权限、双设备通信、最低系统版本、正式签名、完整无障碍与生命周期矩阵。
- 下一步先修复上述 3 个回归用例，再执行完整核心测试和新增 UI 的实际操作/截图，最后补充真机验收。
