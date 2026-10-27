import SwiftUI
import UniformTypeIdentifiers
import NetDockCore

struct SessionTransferView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var exporting = false
    @State private var document = DataFileDocument()
    @State private var error: NetDockError?
    @State private var importedCount: Int?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button(app.t("importSessions")) { importing = true }.accessibilityIdentifier("importSessions")
                    Button(app.t("exportSessions")) {
                        do { document = DataFileDocument(data: try SessionTransfer.encode(app.sessions)); exporting = true }
                        catch { self.error = (error as? NetDockError) ?? NetDockError(.storage) }
                    }.accessibilityIdentifier("exportSessions")
                } footer: { Text(app.t("importHint")) }
                if let importedCount { Text("\(app.t("sessions")): +\(importedCount)") }
                if let error { Text(app.errorText(error)).foregroundStyle(.red).textSelection(.enabled) }
            }
            .formStyle(.grouped).navigationTitle(app.t("configurationTransfer"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(app.t("done")) { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard bytes <= 5 * 1_024 * 1_024 else { throw NetDockError(.fileTooLarge) }
                    importedCount = try app.importSessions(Data(contentsOf: url)); error = nil
                } catch { self.error = (error as? NetDockError) ?? NetDockError(.storage, detail: error.localizedDescription) }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "NetDock-Sessions") { result in
                if case .failure(let error) = result { self.error = NetDockError(.storage, detail: error.localizedDescription) }
            }
        }
        #if os(macOS)
        .frame(width: 500, height: 340)
        #endif
    }
}
