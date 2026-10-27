import SwiftUI
import NetDockCore

struct SendOptionsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Bindable var runtime: SessionRuntime

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(app.t("intervalMS"), text: $runtime.intervalText).monospaced().accessibilityIdentifier("loopInterval")
                    Toggle(app.t("continuous"), isOn: $runtime.continuous).accessibilityIdentifier("continuousSend")
                    if !runtime.continuous {
                        TextField(app.t("repeatCount"), text: $runtime.repeatCountText).monospaced().accessibilityIdentifier("loopCount")
                    }
                    Button(app.t("startRepeat")) {
                        runtime.startPeriodic()
                        if runtime.periodic.state == .running, let ms = Double(runtime.intervalText) {
                            var config = runtime.config
                            config.repeatInterval = ms / 1000
                            config.repeatCount = runtime.continuous ? 0 : Int(runtime.repeatCountText) ?? 0
                            app.save(config)
                        }
                    }
                        .disabled(!runtime.canSend || runtime.payload.isEmpty).accessibilityIdentifier("startRepeat")
                } footer: { Text(app.t("loopSnapshotHint")) }
                Section {
                    Text(app.t("loop.\(String(describing: runtime.periodic.state))"))
                        .accessibilityIdentifier("loopState")
                    LabeledContent(app.t("sentCount"), value: String(runtime.periodic.sentCount))
                        .accessibilityIdentifier("loopSentCount")
                    loopButtons
                }
                if let error = runtime.inputError ?? runtime.periodic.lastError { Text(app.errorText(error)).foregroundStyle(.red) }
            }
            .formStyle(.grouped).navigationTitle(app.t("periodicSend"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(app.t("done")) { dismiss() }.accessibilityIdentifier("closeLoop") } }
        }
        #if os(macOS)
        .frame(width: 500, height: 440)
        #endif
    }
    @ViewBuilder private var loopButtons: some View {
        if runtime.periodic.state == .running {
            Button(app.t("pause")) { runtime.periodic.pause() }.accessibilityIdentifier("pauseRepeat")
        } else if runtime.periodic.state == .paused {
            Button(app.t("resume")) { runtime.periodic.resume() }.accessibilityIdentifier("resumeRepeat")
        }
        Button(app.t("stop"), role: .destructive) { runtime.periodic.stop() }
            .disabled(runtime.periodic.state != .running && runtime.periodic.state != .paused)
            .accessibilityIdentifier("stopRepeat")
    }
}

struct CommandsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Bindable var runtime: SessionRuntime
    @State private var title = ""
    @State private var renaming: QuickCommand?
    @State private var renamedTitle = ""

    var body: some View {
        NavigationStack {
            List {
                Section(app.t("saveCommand")) {
                    TextField(app.t("commandTitle"), text: $title).accessibilityIdentifier("commandTitle")
                    Button(app.t("saveCommand")) {
                        let command = QuickCommand(title: title, encoding: runtime.config.sendEncoding, payloadText: runtime.payload,
                                                   sessionID: runtime.config.id, mode: runtime.config.mode)
                        if app.saveCommand(command) { title = "" }
                    }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || runtime.payload.isEmpty)
                        .accessibilityIdentifier("saveCommand")
                }
                Section(app.t("savedCommands")) {
                    ForEach(app.quickCommands.filter { ($0.sessionID == nil || $0.sessionID == runtime.config.id) && ($0.mode == nil || $0.mode == runtime.config.mode) }) { command in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(command.title).font(.headline)
                            Text(command.payloadText.prefix(120)).font(.caption.monospaced()).lineLimit(3)
                            HStack {
                                Button(app.t("reuse")) { use(command.payloadText, encoding: command.encoding) }
                                Spacer()
                                Button(app.t("rename")) { renaming = command; renamedTitle = command.title }
                                Button(app.t("delete"), role: .destructive) { app.deleteCommand(command.id) }
                            }.buttonStyle(.borderless)
                        }.padding(.vertical, 4)
                    }
                }
                Section(app.t("sendHistory")) {
                    ForEach(runtime.history) { entry in
                        Button { use(entry.text, encoding: entry.encoding) } label: {
                            Text("\(entry.encoding.rawValue.uppercased()) · \(entry.text.prefix(100))").font(.body.monospaced()).lineLimit(3)
                        }
                    }
                }
            }
            .navigationTitle(app.t("commands"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(app.t("done")) { dismiss() }.accessibilityIdentifier("closeCommands") } }
            .alert(app.t("rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField(app.t("commandTitle"), text: $renamedTitle)
                Button(app.t("save")) {
                    if var command = renaming { command.title = renamedTitle; _ = app.saveCommand(command) }
                    renaming = nil
                }
                Button(app.t("cancel"), role: .cancel) { renaming = nil }
            }
        }
        #if os(macOS)
        .frame(width: 540, height: 540)
        #endif
    }
    private func use(_ text: String, encoding: DataEncoding) {
        runtime.payload = text
        var config = runtime.config; config.sendEncoding = encoding; app.save(config)
        dismiss()
    }
}
