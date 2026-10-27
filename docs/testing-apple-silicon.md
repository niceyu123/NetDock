# macOS Apple 芯片构建记录

日期：2026-10-28（Asia/Shanghai）。

- `Scripts/generate_project.rb` 和 `NetDock.xcodeproj/project.pbxproj` 将 macOS App 与 UI 测试 Target 的 Debug、Release 架构设为 `arm64`；移动端设置未改变。
- `Scripts/verify.sh` 使用 arm64 macOS 目标，并检查 Debug、Release 主程序的架构。README、规格书及架构说明已更新。
- 本机 macOS arm64、Xcode 27.1、Swift 6.4：macOS Debug 和 Release 构建成功；两者主程序经 `lipo -archs` 检查均为 `arm64`。Release App 内的 Mach-O 文件仅有该 arm64 主程序。
- iOS Simulator 通用目标构建成功；未进行移动端设备运行或权限验收。
- `swift test --package-path Packages/NetDockCore` 执行 61 项，3 个 `WorkbenchRegressionTests` 用例共 5 个断言失败：大载荷搜索耗时/结果、服务端连接时长、TCP 模式转换后的绑定地址。其他测试通过；这些既有回归问题未在本次架构调整中修改。
- `ruby Scripts/check_localization.rb` 报告现有本地化资源的缺失翻译，因此完整 `Scripts/verify.sh` 尚不能通过。生成脚本语法、验证脚本语法和 `git diff --check` 通过。
- 未运行 UI 自动化、最低系统版本或 App Store 发布签名验证；下一步需处理既有核心回归及本地化检查，再执行完整验证。
