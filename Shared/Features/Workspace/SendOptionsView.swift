import SwiftUI
import NetDockCore

/// Shared inline controls; the session runtime owns the sending task and its lifecycle.
struct PeriodicSendControls: View {
    @Environment(AppModel.self) private var app
    @Bindable var runtime: SessionRuntime
    @FocusState private var editing: Bool

    private var isActive: Bool {
        runtime.periodic.state == .running || runtime.periodic.state == .paused
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Label(app.t("periodicSend"), systemImage: "repeat").foregroundStyle(.secondary)
                    .help(app.t("loopSnapshotHint"))
                intervalField
                Toggle(app.t("continuous"), isOn: $runtime.continuous)
                    .accessibilityIdentifier("continuousSend").disabled(isActive)
                if !runtime.continuous { countField }
                Spacer(minLength: 0)
                progress
                actions
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(app.t("periodicSend"), systemImage: "repeat")
                    Spacer()
                    Toggle(app.t("continuous"), isOn: $runtime.continuous)
                        .accessibilityIdentifier("continuousSend").disabled(isActive)
                }
                HStack { intervalField; if !runtime.continuous { countField } }
                HStack { progress; Spacer(minLength: 8); actions }
            }
        }
        .font(.callout)
        .textFieldStyle(.roundedBorder)
        .monospacedDigit()
        .focused($editing)
        .onSubmit { editing = false }
    }

    private var intervalField: some View {
        HStack(spacing: 6) {
            Text(app.t("intervalMS")).foregroundStyle(.secondary)
            TextField(app.t("intervalMS"), text: $runtime.intervalText)
                .accessibilityLabel(app.t("intervalMS")).accessibilityIdentifier("loopInterval")
                .frame(width: 70).disabled(isActive)
        }
    }

    private var countField: some View {
        HStack(spacing: 6) {
            Text(app.t("repeatCount")).foregroundStyle(.secondary)
            TextField(app.t("repeatCount"), text: $runtime.repeatCountText)
                .accessibilityLabel(app.t("repeatCount")).accessibilityIdentifier("loopCount")
                .frame(width: 60).disabled(isActive)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(app.t("loop.\(String(describing: runtime.periodic.state))"))
                .accessibilityIdentifier("loopState")
            Text("\(app.t("sentCount")): \(runtime.periodic.sentCount)")
                .monospacedDigit().foregroundStyle(.secondary)
                .accessibilityIdentifier("loopSentCount")
        }.font(.caption)
    }

    @ViewBuilder private var actions: some View {
        if runtime.periodic.state == .running {
            Button(app.t("pause")) { runtime.periodic.pause() }
                .accessibilityIdentifier("pauseRepeat")
        } else if runtime.periodic.state == .paused {
            Button(app.t("resume")) { runtime.periodic.resume() }
                .accessibilityIdentifier("resumeRepeat")
        } else {
            Button(app.t("startRepeat")) {
                editing = false
                runtime.startPeriodic()
                if runtime.periodic.state == .running {
                    var config = runtime.config
                    config.repeatInterval = (Double(runtime.intervalText) ?? 1000) / 1000
                    config.repeatCount = runtime.continuous ? 0 : Int(runtime.repeatCountText) ?? 0
                    app.save(config)
                }
            }
            .disabled(!runtime.canSend || runtime.payload.isEmpty)
            .accessibilityIdentifier("startRepeat")
        }
        if isActive {
            Button(app.t("stop"), role: .destructive) { runtime.periodic.stop() }
                .accessibilityIdentifier("stopRepeat")
        }
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
