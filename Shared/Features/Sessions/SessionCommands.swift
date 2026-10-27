import SwiftUI

private struct NewSessionActionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

extension FocusedValues {
    var newSessionAction: (@MainActor () -> Void)? {
        get { self[NewSessionActionKey.self] }
        set { self[NewSessionActionKey.self] = newValue }
    }
}

#if os(macOS)
struct SessionCommands: Commands {
    let app: AppModel
    @FocusedValue(\.newSessionAction) private var newSessionAction

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(app.t("newSession")) { newSessionAction?() }
                .keyboardShortcut("n").disabled(newSessionAction == nil)
        }
        CommandGroup(replacing: .appSettings) {
            SettingsLink { Text(app.t("settings")) }.keyboardShortcut(",")
        }
    }
}
#endif
