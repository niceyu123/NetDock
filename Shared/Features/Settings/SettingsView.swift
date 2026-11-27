import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    private let privacyPolicyURL = URL(string: "https://github.com/niceyu123/NetDock/blob/main/docs/privacy.md")!
    var body: some View {
        @Bindable var app = app
        Form {
            Section(app.t("interface")) {
                Picker(app.t("language"), selection: $app.language) {
                    Text("简体中文").tag(AppLanguage.chinese)
                    Text("English").tag(AppLanguage.english)
                }.accessibilityIdentifier("languagePicker")
                Picker(app.t("appearance"), selection: $app.appearance) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(app.t("appearance.\(mode.rawValue)")).tag(mode)
                    }
                }.accessibilityIdentifier("appearancePicker")
            }
            Section(app.t("privacy")) {
                Text(app.t("privacyDescription")).font(.callout)
                Text(app.t("logLimitDescription")).font(.caption).foregroundStyle(.secondary)
                Link(app.t("privacyPolicy"), destination: privacyPolicyURL)
                    .accessibilityIdentifier("privacyPolicyLink")
                if app.recoveredStorage { Text(app.t("recoveredBackup")).foregroundStyle(.orange) }
            }
            Section(app.t("about")) {
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    LabeledContent(app.t("version"), value: version)
                }
                Text(app.t("aboutDescription")).font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(app.t("settings"))
        .environment(\.locale, Locale(identifier: app.language.rawValue))
        .preferredColorScheme(app.appearance.colorScheme)
    }
}
