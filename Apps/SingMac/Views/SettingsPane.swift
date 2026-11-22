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
    @State private var profiles: [SettingsProfile] = []
    @State private var profileName = ""
    @State private var pickingVideo = false
    @State private var pickingRelink = false
    @State private var pickingCache = false
    @State private var clapping = false
    @State private var toolStatus: String?
    @State private var duplicates: [[SongSummary]] = []
    @State private var modelsTick = 0
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
                HStack {
                    LabeledContent("TV video loop", value: host.tvVideoURL?.lastPathComponent ?? "None")
                    Button("Choose…") { pickingVideo = true }
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
                Picker("Singer's headphones (monitor)", selection: $host.monitorDeviceUID) {
                    Text("None").tag(String?.none)
                    ForEach(outputs) { d in Text(d.name).tag(Optional(d.uid)) }
                }
                Picker("Microphone", selection: $host.inputDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(inputs) { d in Text(d.name).tag(Optional(d.uid)) }
                }
            }
            Section("Quick settings") {
                HStack {
                    ForEach(profiles) { p in Button(p.name) { Task { await host.applySettingsProfile(p.name, by: "Mac") } } }
                    Spacer()
                    TextField("Save current as…", text: $profileName).frame(width: 160)
                    Button("Save") { Task { await host.saveSettingsProfile(profileName); profileName = ""; profiles = await host.settingsProfiles() } }.disabled(profileName.isEmpty)
                }
            }
            PartySettingsSections(settings: $host.settings)
            MicSettingsSection(playback: $host.settings.playback, channels: host.micChannels)
            LocksSection(locks: $host.settings.locks)
            Section("Lyrics sources") {
                Toggle("Sing lyrics database", isOn: $host.settings.services.singAPIEnabled)
                TextField("Sing API address", text: $host.settings.services.singAPIBase)
                Toggle("NetEase (word synced)", isOn: $host.settings.services.neteaseEnabled)
                Toggle("Kugou (word synced)", isOn: $host.settings.services.kugouEnabled)
                Toggle("QQ Music (line synced)", isOn: $host.settings.services.qqEnabled)
                Toggle("Musixmatch (word synced when available)", isOn: $host.settings.services.musixmatchEnabled)
                Toggle("LRCLIB (line synced)", isOn: $host.settings.services.lrclibEnabled)
                Toggle("Word timing with on-device AI when only line timing exists", isOn: $host.settings.services.aiAlignmentEnabled)
                Toggle("Search Apple Music and Deezer catalogs from the pads", isOn: $host.settings.services.catalogSearchEnabled)
                VStack(alignment: .leading) {
                    Text("Order when two sources are equally precise")
                    List {
                        ForEach(host.settings.services.providerOrder, id: \.self) { Text($0) }
                            .onMove { host.settings.services.providerOrder.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .frame(height: 150)
                }
                Stepper("Give up on a source after \(Int(host.settings.services.timeoutSeconds)) s", value: $host.settings.services.timeoutSeconds, in: 2...20)
                Toggle("Share AI-synced and fixed lyrics with the Sing database", isOn: $host.settings.services.uploadsEnabled)
                TextField("Upload API address", text: $host.settings.services.uploadAPIBase)
                if host.pendingUploads > 0 { LabeledContent("Waiting to upload", value: "\(host.pendingUploads)") }
                Button("Reset these to the defaults") { host.settings.services = ServiceSettings() }
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
            Section {
                LabeledContent("Room latency (clap test)", value: host.settings.playback.roundTripLatencyMs > 0 ? "\(Int(host.settings.playback.roundTripLatencyMs)) ms" : "Not measured")
                HStack {
                    Button(clapping ? "Clap with each click…" : "Run the clap test") {
                        clapping = true
                        Task {
                            do { toolStatus = "Measured \(Int(try await host.clapTest())) ms" } catch { toolStatus = error.localizedDescription }
                            clapping = false
                        }
                    }.disabled(clapping)
                    if let toolStatus { Text(toolStatus).foregroundStyle(.secondary) }
                }
                Picker("Nightly upkeep", selection: $host.settings.system.maintenanceHour) {
                    Text("Off").tag(Int?.none)
                    ForEach([1, 2, 3, 4, 5, 6], id: \.self) { Text("\($0):00").tag(Optional($0)) }
                }
                Toggle("Fill missing year, genre and artwork from MusicBrainz", isOn: $host.settings.system.musicBrainz)
                HStack {
                    Button("Check caches now") { Task { let n = await host.integrityCheck(); toolStatus = n == 0 ? "Every cache is fine" : "Rebuilding \(n) song(s)" } }
                    Button("Find moved music…") { pickingRelink = true }
                    Button("Find duplicates") { Task { duplicates = await host.findDuplicates(); toolStatus = duplicates.isEmpty ? "No duplicates" : "\(duplicates.count) group(s) found" } }
                    Button("Fill metadata now") { Task { await host.enrichMetadata(limit: 100); toolStatus = "Metadata updated" } }
                }
                ForEach(Array(duplicates.enumerated()), id: \.offset) { _, g in
                    Text(g.map { "\($0.title) (\($0.artist))" }.joined(separator: "  ≈  ")).font(.callout)
                }
                HStack {
                    LabeledContent("Song caches", value: host.cacheLocation.path)
                    Button("Move…") { pickingCache = true }
                }
                Button("Show logs") { NSWorkspace.shared.open(HostController.logsFolder) }
            } header: { Text("Upkeep and tools") } footer: {
                Text("The nightly upkeep processes the library, checks and cleans the caches, and backs up while nobody sings. Moving the caches takes effect after Sing! restarts.")
            }
            Section("AI models") {
                ForEach(host.installedModels()) { m in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(m.name)
                            Text("\(m.task) · \(ByteCountFormatter.string(fromByteCount: m.bytes, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { host.removeModel(m.name); modelsTick += 1 }
                    }
                }
                Button("Reinstall the models shipped with Sing!") { host.reinstallBundledModels(); modelsTick += 1 }
            }
            .id(modelsTick)
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
        .background(EmptyView().fileImporter(isPresented: $pickingRelink, allowedContentTypes: [.folder]) { r in
            if case .success(let url) = r { Task { let n = await host.relink(folder: url); toolStatus = "Found \(n) moved song(s)" } }
        })
        .background(EmptyView().fileImporter(isPresented: $pickingCache, allowedContentTypes: [.folder]) { r in
            if case .success(let url) = r { Task { do { try await host.moveCache(to: url); toolStatus = "Caches moved; restart Sing! to use them" } catch { toolStatus = error.localizedDescription } } }
        })
        .background(EmptyView().fileImporter(isPresented: $pickingVideo, allowedContentTypes: [.movie]) { r in
            if case .success(let url) = r { host.tvVideoURL = url; host.settings.tv.background = .video }
        })
        .navigationTitle("Settings")
        .fileExporter(isPresented: $exporting, document: SQLiteDocument(data: (try? host.exportDatabase()) ?? Data()), contentType: .data, defaultFilename: "Sing backup.sqlite") { _ in }
        .confirmationDialog("Erase history, singers, favorites, recordings, settings and caches?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Erase everything", role: .destructive) { Task { await host.factoryReset() } }
        } message: { Text("A last backup is saved first. Music files stay where they are and are processed again.") }
        .task {
            profiles = await host.settingsProfiles()
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
