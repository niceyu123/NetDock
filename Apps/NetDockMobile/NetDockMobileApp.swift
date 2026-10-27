import SwiftUI

@main
struct NetDockMobileApp: App {
    @State private var app = AppModel()
    var body: some Scene {
        WindowGroup { RootView().environment(app) }
    }
}
