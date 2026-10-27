import SwiftUI
import AppKit

@main
struct NetDockMacApp: App {
    @State private var app = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView().environment(app).frame(minWidth: 760, minHeight: 520)
                .onAppear {
                    guard ProcessInfo.processInfo.arguments.contains("-ui-testing") else { return }
                    // Keep deterministic UI screenshots inside one display; no change to normal windows.
                    DispatchQueue.main.async {
                        guard let screen = NSScreen.screens.first,
                              let window = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }) else { return }
                        let area = screen.visibleFrame
                        window.setFrame(NSRect(x: area.minX + 40, y: area.maxY - 800,
                                               width: min(1180, area.width - 80), height: min(760, area.height - 80)), display: true)
                    }
                }
        }
        .defaultSize(width: 1180, height: 760)
        .defaultPosition(.center)
        .commands { SessionCommands(app: app) }
        Settings { SettingsView().environment(app).frame(width: 510, height: 480) }
    }
}
