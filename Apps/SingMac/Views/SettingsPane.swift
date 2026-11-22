import AppKit
import SingCore
import SingDesign
import SingHost
import SwiftUI
import UniformTypeIdentifiers

struct SettingsPane: View {
    @Bindable var host: HostController
    @Environment(AppModel.self) private var app
    @State private var outputs: [AudioDevice] = []
    @State private var inputs: [AudioDevice] = []
    @State private var apiStatus: String?
    @State private var pickingFolder = false
    @State private var languages: [LanguageOption] = []
    @State private var pin = ""
    @State private var exporting = false
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("TV") {
                Picker("Show the TV on", selection: Binding(get: { app.tv.preferredScreenName ?? "" }, set: { app.tv.preferredScreenName = $0.isEmpty ? nil : $0; if app.tv.isVisible { app.showTV() } })) {
                    Text("Automatic (second display, else a window)").tag("")
                    ForEach(NSScreen.screens, id: \.localizedName) { s in Text(s.localizedName).tag(s.localizedName) }
                }
                VStack(alignment: .leading) {
                    Text("Lyrics delay: \(Int(host.lyricOffset * 1000)) ms")
                    Slider(value: $host.lyricOffset, in: -0.5...0.5, step: 0.01)
                    Text("Move it if words light up before or after you hear them.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Library") {
                LabeledContent("Watch folder", value: host.watchFolder?.path ?? "None")
                HStack {
                    Button("Choose…") { pickingFolder = true }
                    if host.watchFolder != nil { Button("Stop watching") { host.watchFolder = nil } }
                }
                Text("Music files saved in this folder are imported automatically. A requested song that arrives is queued for whoever asked for it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TVDisplaySettingsSections(tv: $host.settings.tv, languages: languages)
            Section("Audio") {
                Picker("Music and mics play on", selection: $host.outputDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(outputs) { d in Text(d.isHDMI ? "\(d.name) (TV)" : d.name).tag(Optional(d.uid)) }
                }
                Picker("Microphone", selection: $host.inputDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(inputs) { d in Text(d.name).tag(Optional(d.uid)) }
                }
            }
            PartySettingsSections(settings: $host.settings)
            Section("Lyrics sources") {
                Toggle("Sing lyrics database", isOn: $host.settings.services.singAPIEnabled)
                TextField("Sing API address", text: $host.settings.services.singAPIBase)
                Toggle("NetEase (word synced)", isOn: $host.settings.services.neteaseEnabled)
                Toggle("Kugou (word synced)", isOn: $host.settings.services.kugouEnabled)
                Toggle("LRCLIB (line synced)", isOn: $host.settings.services.lrclibEnabled)
                Toggle("Word timing with on-device AI when only line timing exists", isOn: $host.settings.services.aiAlignmentEnabled)
                Toggle("Search Apple Music and Deezer catalogs from the pads", isOn: $host.settings.services.catalogSearchEnabled)
                HStack {
                    Button("Test connection") { testAPI() }
                    if let apiStatus { Text(apiStatus).foregroundStyle(.secondary) }
                }
            }
            OwnerSettingsSections(settings: $host.settings)
            Section {
                LabeledContent("Status", value: host.processingStatus)
                SecureField("Owner PIN", text: $pin, prompt: Text(host.ownerPINSet ? "PIN set, type a new one" : "No PIN"))
                HStack {
                    Button(host.ownerPINSet ? "Change PIN" : "Set PIN") { host.setOwnerPIN(pin); pin = "" }.disabled(pin.count < 4)
                    if host.ownerPINSet { Button("Remove PIN", role: .destructive) { host.setOwnerPIN(nil) } }
                }
            } header: { Text("Owner") } footer: {
                Text("With a PIN, host pads must enter it before changing storage, lyrics sources, processing, network or unpairing devices. Five wrong tries lock the pad out for a while.")
            }
            Section {
                LabeledContent("Last backup", value: host.lastBackupDate?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                HStack {
                    Button("Back up now") {
                        let url = host.paths.root.appendingPathComponent("Backups/sing-manual-\(Int(Date.now.timeIntervalSince1970)).sqlite")
                        try? host.backupDatabase(to: url)
                    }
                    Button("Export…") { exporting = true }
                    Button("Show backups") { NSWorkspace.shared.open(host.paths.root.appendingPathComponent("Backups")) }
                }
                Button("Erase everything and start over…", role: .destructive) { confirmReset = true }
            } header: { Text("Backups") } footer: {
                Text("A copy of the history, singers, favorites and settings is made every day; the last seven are kept. Erasing keeps your music files.")
            }
            Section("Vocal separation") {
                LabeledContent("Model", value: host.modelAvailable ? "HTDemucs (Core ML)" : "Not installed")
                if !host.modelAvailable {
                    Text("Put htdemucs.mlpackage in \(host.paths.models.path) and relaunch.").font(.caption).foregroundStyle(.secondary)
                    Button("Open Models folder") { NSWorkspace.shared.open(host.paths.models) }
                }
                Button("Open data folder") { NSWorkspace.shared.open(host.paths.root) }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { r in
            if case .success(let url) = r { host.watchFolder = url }
        }
        .navigationTitle("Settings")
        .fileExporter(isPresented: $exporting, document: SQLiteDocument(data: (try? host.exportDatabase()) ?? Data()), contentType: .data, defaultFilename: "Sing backup.sqlite") { _ in }
        .confirmationDialog("Erase history, singers, favorites, recordings, settings and caches?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Erase everything", role: .destructive) { Task { await host.factoryReset() } }
        } message: { Text("A last backup is saved first. Music files stay where they are and are processed again.") }
        .task {
            languages = await LyricsTranslator.languages().map { LanguageOption(code: $0.code, name: $0.name) }
            outputs = AudioDevices.outputs
            inputs = AudioDevices.inputs
        }
    }

    private func testAPI() {
        apiStatus = "Testing…"
        let base = host.settings.services.singAPIBase
        Task {
            guard let url = URL(string: base) else { apiStatus = "Invalid address"; return }
            apiStatus = await SingLyricsAPI(base: url, timeout: 5).healthy() ? "Connected" : "Not reachable, LRCLIB and local lyrics are used instead"
        }
    }
}

struct SQLiteDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
