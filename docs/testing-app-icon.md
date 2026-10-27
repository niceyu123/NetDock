# 应用图标调整验证

日期：2026-10-26（Asia/Shanghai）。

## 修改文件

- `Scripts/generate_app_icon.swift`：移除渐变与彩色点缀，使用纯白背景、纯黑图案；macOS 单独生成带透明边距的圆角图标，iOS 保留不透明方形源图供系统裁切。
- `Shared/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`：重新生成 iPhone/iPad 1024 像素源图。
- `Shared/Resources/Assets.xcassets/AppIconMac.appiconset/*.png`：重新生成全部 10 个 macOS 尺寸。

## 实际验证

- 生成脚本执行成功，退出码 0；实际查看生成 PNG。
- `sips` 确认两端源图均为 1024 × 1024；macOS 有 alpha，iOS 无 alpha。
- macOS `xcodebuild -quiet -project NetDock.xcodeproj -scheme NetDockMac -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/netdock-icon-build build`：圆角版本退出码 0。
- iOS Simulator `xcodebuild -quiet -project NetDock.xcodeproj -scheme NetDockMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/netdock-icon-mobile-build CODE_SIGNING_ALLOWED=NO build`：退出码 0。后续圆角调整仅影响 macOS 资源和生成逻辑。
- 实际启动 macOS 构建产物并截图；在 Finder 中操作“显示简介”并截图，确认最终应用包显示白底黑色圆角图标。
- `git diff --check`：通过。
- `swift test --package-path Packages/NetDockCore`：退出码 1，运行 61 项测试，工作台回归测试中 3 项失败、共 5 个断言失败。失败涉及大数据搜索性能/匹配、服务端连接计时、TCP 模式地址转换。本次未修改这些实现或测试，不能将本轮核心测试报告为通过。

## 未验证与后续

未进行 iPhone/iPad 真机安装、主屏幕图标检查或发布验收。下一步可在真机安装后核对系统圆角裁切效果；核心测试失败另行处理。本次未提交或推送 Git。

## 系统圆角适配修正

用户实际 Dock 截图暴露了上一版的内缩白色底板与系统外框叠加问题。此次改为 macOS 原生 Icon Composer 格式：

- `Shared/Resources/NetDockIcon.icon/`：全画布白底黑色图案，交由系统生成外轮廓，图案关闭玻璃效果与额外阴影。
- `Scripts/generate_app_icon.swift`：同步生成 `.icon` 文档和对应图案资源，避免在现代系统图标中预画第二层圆角。
- `Scripts/generate_project.rb`、`NetDock.xcodeproj/project.pbxproj`：仅 Mac Target 接入并选择 `NetDockIcon`；移动端图标配置保持不变。
- Apple `ictool` 实际导出 macOS 默认外观预览成功；检查预览确认白底与系统轮廓贴合。
- macOS 与 iOS Simulator 使用上文相同构建命令再次执行，均退出码 0；日志分别为 `/tmp/netdock-native-icon-build.log` 和 `/tmp/netdock-native-icon-mobile.log`。
- 构建产物 Info.plist 的 `CFBundleIconName` 与 `CFBundleIconFile` 均为 `NetDockIcon`。复制构建产物到新的临时预览路径后，在 Finder 中实际操作“显示简介”并截图，确认无内缩白色底板；旧构建路径仍显示缓存图标，未清空系统图标缓存。
- 实际通过原生 UI 打开临时预览应用包，应用窗口正常显示。
- Ruby 语法检查与 `git diff --check` 通过。
- 核心测试再次执行，61 项测试，4 项失败、共 6 个失败记录（其中 1 个 unexpected）。除前述 3 个工作台回归用例外，`UDPIntegrationTests.testPeriodicRealUDPStopsAndTCPRemainsIndependent` 报 `notReady`。本次未修改核心网络逻辑，未调查或修复这些测试问题。

本轮未在 macOS 14/15、真机 iOS/iPadOS 或其他图标外观模式上运行。下一步为最低系统版本及设备端图标验收；没有 Git 提交或推送。
