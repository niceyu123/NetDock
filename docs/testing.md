# M0 + M1 验证记录

日期：2026-10-26（Asia/Shanghai）。仅记录实际执行的结果；不代表 V1 全量 DoD 或真机验收。

本文件保留当时的历史验证记录。macOS App 现已改为仅支持 Apple 芯片，当前架构配置及验证结果见 [Apple 芯片构建记录](testing-apple-silicon.md)。

## 阶段与具体文件

| 阶段 | 交付文件 | 已实现行为 |
| --- | --- | --- |
| M0 工程 | `NetDock.xcodeproj/`、`Scripts/generate_project.rb`、`Apps/NetDockMac/`、`Apps/NetDockMobile/`、`Packages/NetDockCore/Package.swift` | macOS 原生 Target、iPhone/iPad Universal Target、共享本地 Swift Package、独立 UI 测试 Target |
| M0 应用基础 | `Shared/Features/Sessions/{RootView,AppModel,SessionEditor,SessionCommands}.swift`、`Shared/Features/Settings/SettingsView.swift`、`Shared/Theme/AppPreferences.swift`、`Shared/Resources/Localizable.xcstrings` | 原生导航、会话增删改/复制、本地偏好、中英即时切换、三种外观、菜单/快捷键、窗口独立面板 |
| M0 数据基础 | `Packages/NetDockCore/Sources/NetDockCore/Models/`、`Packages/NetDockCore/Sources/NetDockCore/Persistence/SessionRepository.swift`、`Packages/NetDockCore/Tests/NetDockCoreTests/ModelTests.swift` | 纯配置模型与校验、版本 JSON 原子保存/备份恢复、保存错误可读且草稿保留 |
| M1 网络 | `Packages/NetDockCore/Sources/NetDockCore/TCP/TCPService.swift`、`Transport/NetworkEvent.swift`（相对 Sources/NetDockCore） | NWConnection、NWListener、多客户端、定向/广播/独立断开、真实状态、超时/错误、停止与取消清理 |
| M1 工作台 | `Shared/Features/Sessions/SessionManager.swift`、`Shared/Features/Workspace/{WorkspaceView,LogView,SendPanel,PeerListView}.swift`、`Shared/Components/Clipboard.swift` | 网络生命周期独立于 View、三端按宽度布局、日志和发送面板、客户端选择/失效提示 |
| M1 编解码/验证 | Package 内 `Codec/PayloadCodec.swift`、`Logging/{TrafficBuffer,SessionTrafficStore}.swift`、`Tests/NetDockCoreTests/{CodecAndLogTests,TCPIntegrationTests}.swift`、仓库 `Tests/NetDockUITests/WorkspaceUITests.swift` | 严格 UTF-8/HEX、有界原始日志、批量 UI 更新、真实 TCP 与 UI 测试 |

M0 的最终验证由下述两个 App 构建、本地化检查、模型/存储测试和三端偏好 UI 测试覆盖。M1 由真实 TCP 集成测试及三端 Client/Server UI 流程覆盖。下一阶段按规格书进入 M2 UDP；真机局域网与权限验收仍需设备，不能用上述模拟器结果代替。

## 工具链与构建

- 本机 Xcode 27.1（27A9275）、Swift 6.4，macOS arm64。
- 部署下限 macOS 14 / iOS、iPadOS 17；未在这些最低系统版本上运行。
- `NetDockMac` 为原生 macOS App，`NetDockMobile` 为 iPhone/iPad Universal iOS App，未启用 Catalyst。
- Debug macOS、通用 iOS Simulator 构建已实际成功。
- macOS Release 通用构建已成功，`lipo -archs` 确认 `x86_64 arm64`；Intel 仅交叉编译，未在 Intel Mac 上运行。
- Release 签名 entitlement 已检查，仅 App Sandbox、network.client、network.server；无 get-task-allow、iCloud、组播、后台模式。此为本地 ad-hoc 签名，不是正式发布签名。

执行命令：

```sh
swift test --package-path Packages/NetDockCore
swift test --package-path Packages/NetDockCore -c release
swift test --package-path Packages/NetDockCore --sanitize=thread
ruby Scripts/check_localization.rb
ruby -c Scripts/generate_project.rb
xcodebuild -project NetDock.xcodeproj -scheme NetDockMac \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build build
xcodebuild -project NetDock.xcodeproj -scheme NetDockMobile \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build-mobile \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project NetDock.xcodeproj -scheme NetDockMac -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build-release build
lipo -archs build-release/Build/Products/Release/NetDockMac.app/Contents/MacOS/NetDockMac
codesign -d --entitlements :- build-release/Build/Products/Release/NetDockMac.app
```

构建出现的 `AppIntents` 元数据跳过警告表示项目未使用 AppIntents，未因此添加无关依赖。Xcode 对 iOS 27.1 SDK 内部 build number 记录 `invalidDigitCount` 诊断；不将其当作产品测试通过或失败依据，最终以 XCTest / xcodebuild 结果为准。

最终 `./Scripts/verify.sh` 已以退出码 0 完成：116 条中英本地化键与全部错误码检查通过，20 项核心测试通过，macOS 和通用 iOS Simulator 构建成功，`git diff --check` 通过。另对尚未跟踪的源码执行尾随空格检查、解析资源 JSON，41 个相关文件检查通过。CI 工作流已提供，未在远端执行。

## 核心自动测试

共 20 项 XCTest，Debug、Release 均已执行通过；Thread Sanitizer 运行 20 项通过，本次运行未报告数据竞争。日志分别为 `/tmp/netdock-core-final-review.log`、`/tmp/netdock-core-release-final.log`、`/tmp/netdock-core-tsan-final.log`。

| 范围 | 实际覆盖 |
| --- | --- |
| 模型/存储（4） | 主机与端口校验、IPv6 方括号；版本 JSON 往返、损坏主文件恢复有效备份；未知 schemaVersion、重复 ID 拒绝；活跃会话禁止修改端点/模式，允许语言无关的名称与显示偏好变更 |
| 编解码/日志（6） | HEX 空白/大小写/00/FF、空输入/奇数/非法字符位置；UTF-8 往返、无效字节不丢失；环形缓冲计数/字节淘汰、5,000 条/30MiB 默认上限、SYS/错误与 RX 分离 |
| 真实 TCP（10） | 双向二进制及真实端点；3 客户端定向与广播隔离/独立断开；1B、64KiB、1MiB 双向完整性；拒绝连接、端口占用、无效域名；重复启停/立即重启；未就绪/空发送拒绝；IPv6 loopback；真实 FIN 与 RST；空广播与 16MiB 待发送限制 |

这些测试使用真实 Network.framework 和 loopback socket，不以 Mock 替代网络。FIN/RST 用系统 BSD socket 产生真实关闭行为；生产网络实现仍统一使用 Network.framework。大数据断言合并收到的 chunk 后比较全部字节，不假设 TCP 消息边界。

停止/重启回归曾失败：旧监听器尚未完成 cancel 时重绑触发 EADDRINUSE。已调整 stop 等待 `.cancelled`，该原始用例随后通过。

## UI 运行验证

XCUITest 实际操作新建会话、设置、连接和发送；测试进程启动真实 TCP echo listener / client。App 使用独立 `NetDock-UITests` 配置目录，不预置会话或通信成功状态。

macOS 最新版本完整 3 项 UI 测试已通过（`TestResults/mac-delivery.xcresult`）：

1. 简中切换英文、深色/浅色/跟随系统，终止后重启保持偏好。
2. 新建 TCP Client，真实连接与收发 `NetDock live TCP`，计数 TX 16 / RX 16，主动断开。
3. 新建 TCP Server，独立客户端接入发送，App 显示 RX，并向已连接客户端广播回复。

iPad Air 11 / iPadOS 27.0 的相同 3 项流程已通过：Client 见 `TestResults/ipad-input.xcresult`，偏好与 Server 见 `TestResults/ipad-settings-server.xcresult`。已查看竖屏真实收发、横屏三栏和 Server 广播截图，竖屏键盘打开时发送控件可操作。

iPhone 17 / iOS 27.0 的最新版本完整 3 项 UI 测试已通过（`TestResults/iphone17-delivery.xcresult`，`TEST EXECUTE SUCCEEDED`）。已检查 Client 截图，计数 TX 16 / RX 16，主动断开正常；Server 截图显示 RX 16 / TX 12，独立客户端实际收到广播回复。最终这一轮系统没有展开软件键盘；本轮较早的 `iphone17-resume` 运行实际展开了键盘，编辑器、发送按钮和最新 RX 均可见，其截图单独保留为 `TestResults/screenshots/iphone-tcp-keyboard.png`。两次运行间工作台布局未改动，不将最终截图文件名中的 keyboard 字样当作键盘已展开的证据。

四份正常完成的 xcresult 均通过 `xcresulttool get test-results summary` 复核：macOS 3/3、iPhone 3/3、iPad Client 1/1、iPad 设置与 Server 2/2，无失败或跳过。

补拍记录：`ipad-rotation` 的 XCTest 用例通过，横竖屏稳定截图已检查并保留。但收集结果期间提前关闭模拟器，导致 xcodebuild 未正常收尾，已终止该进程；不使用这份未完整收尾的结果包作为整体通过依据。iPad 的正常验收依据为上述 `ipad-input` 和 `ipad-settings-server` 两份结果。

手工回归：对 macOS 独立 UI 测试目录暂时移除写权限，实际触发 Cocoa Code 513 / POSIX EACCES。保存失败后编辑页仍在，名称和端口草稿保留；恢复原权限后点击保存成功。未修改正常会话目录。多窗口编辑在保存时重新校验活跃状态，防止过期编辑页覆盖运行中的真实端点；新建面板状态限制在当前窗口。

实际完成的 UI 命令（移动端复用此前已构建的产物；本轮设备名）：

```sh
xcodebuild -project NetDock.xcodeproj -scheme NetDockMac \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build \
  -parallel-testing-enabled NO -resultBundlePath TestResults/mac-delivery.xcresult test
xcodebuild -project NetDock.xcodeproj -scheme NetDockMobile \
  -destination 'platform=iOS Simulator,name=NetDock iPhone 17' -derivedDataPath build-mobile \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  -resultBundlePath TestResults/iphone17-delivery.xcresult test-without-building
xcodebuild -project NetDock.xcodeproj -scheme NetDockMobile \
  -destination 'platform=iOS Simulator,name=NetDock iPad Air 11' -derivedDataPath build-mobile \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  -only-testing:NetDockMobileUITests/WorkspaceUITests/testRealTCPRoundTripAndScreenshots \
  -resultBundlePath TestResults/ipad-input.xcresult test
xcodebuild -project NetDock.xcodeproj -scheme NetDockMobile \
  -destination 'platform=iOS Simulator,name=NetDock iPad Air 11' -derivedDataPath build-mobile \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  -only-testing:NetDockMobileUITests/WorkspaceUITests/testLanguageAndAppearancePersistAcrossRelaunch \
  -only-testing:NetDockMobileUITests/WorkspaceUITests/testServerReceivesAndBroadcastsToRealClient \
  -resultBundlePath TestResults/ipad-settings-server.xcresult test-without-building
```

运行前用 `xcrun simctl list devices available` 确认名称与运行时。已存在的 resultBundlePath 不能复用，需给新路径。首次下载的 iOS 27.1 runtime 仅支持 iPhone Duo；已另安装 iOS 27.0 来运行常规 iPhone/iPad，未篡改运行时支持列表。

截图由 XCTest 附件和独立 PNG 保存在 `TestResults/` 或测试 Runner 的临时目录；`TestResults` 被 Git 忽略。仅使用测试文本/loopback 端点，不保留用户实际通信载荷。

已人工查看并保存的截图包括 `TestResults/screenshots/mac-server.png`、`mac-tcp.png`、`mac-settings-en-dark.png`、`ipad-tcp-portrait.png`、`ipad-tcp-landscape.png`、`ipad-09-server-real-client-broadcast.png`、`ipad-07-settings-en-light.png`、`iphone-tcp-keyboard.png`、`iphone-03-real-tcp-tx-rx-keyboard.png`、`iphone-09-server-real-client-broadcast.png`。

## 尚未验证与后续验收

- 运行期仍有诊断：移动端键盘出现时记录 `Invalid frame dimension (negative or non-finite)`，macOS UI 测试记录内部 QoS 等待警告。功能断言通过，已查看的截图未见关键控件被遮挡；这些告警的调用源尚未定位，不宣称运行期零警告，后续应在稳定工具链和真机复核。
- 无已连接真机，iPhone↔Mac、iPad↔Mac 同一 Wi-Fi 双设备收发、真实局域网授权/拒绝、AP 隔离均未验证。模拟器不能替代这些场景。
- 未对物理网络断开、切换 Wi-Fi、系统休眠/唤醒完成全矩阵测试。
- 最低系统 macOS 14 / iOS 17、Intel Mac 实际运行未验证。
- VoiceOver 完整流程、辅助功能字号全档位、Reduce Motion、iPad 多任务任意分屏尺寸和外接键盘/多窗口全矩阵未完成。
- 本轮没有 UDP、自动重连、周期发送、快捷指令、配置/日志导出和搜索；相应 T06–T08、T10 的 UDP 部分、T11 属后续里程碑。
- App 图标、正式签名、App Store 截图/提交属于 M4；本轮未发布。
