import SingCore
import SwiftUI

/// Storage limits, processing limits and network settings; only the owner sees them.
public struct OwnerSettingsSections: View {
    @Binding var settings: SingSettings

    public init(settings: Binding<SingSettings>) { _settings = settings }

    public var body: some View {
        Section {
            Stepper(value: $settings.storage.limitGB, in: 0...2000, step: 5) {
                LabeledContent("Cache limit", value: settings.storage.limitGB == 0 ? "No limit" : "\(Int(settings.storage.limitGB)) GB")
            }
            Stepper(value: $settings.storage.stemsLimitGB, in: 0...2000, step: 5) {
                LabeledContent("Stems limit", value: settings.storage.stemsLimitGB == 0 ? "No limit" : "\(Int(settings.storage.stemsLimitGB)) GB")
            }
            Stepper(value: $settings.storage.lowDiskWarningGB, in: 1...200, step: 1) {
                LabeledContent("Warn when free space is under", value: "\(Int(settings.storage.lowDiskWarningGB)) GB")
            }
            Toggle("Free space automatically when over a limit", isOn: $settings.storage.autoFree)
        } header: { Text("Storage limits") } footer: {
            Text("Over a limit, the stems of songs not sung for the longest time are deleted. Pinned, favorite and queued songs stay. Deleted stems are rebuilt when the song is queued again.")
        }
        Section {
            Toggle("Process the whole library in the background", isOn: $settings.system.processLibraryInBackground)
            Toggle("Pause processing while someone sings", isOn: $settings.system.pauseProcessingWhileSinging)
            Stepper(value: $settings.system.restAfterMinutes, in: 0...240, step: 15) {
                LabeledContent("Rest 10 min after", value: settings.system.restAfterMinutes == 0 ? "Never" : "\(Int(settings.system.restAfterMinutes)) min")
            }
        } header: { Text("Processing") } footer: {
            Text("Songs in the queue are always processed right away.")
        }
        PrivacySettingsSection(privacy: $settings.privacy)
        Section {
            TextField("Name on the network", text: $settings.network.bonjourName, prompt: Text("This Mac's name"))
            Stepper(value: $settings.network.maxPads, in: 0...50) {
                LabeledContent("Paired devices allowed", value: settings.network.maxPads == 0 ? "No limit" : "\(settings.network.maxPads)")
            }
            Stepper(value: $settings.network.port, in: 1024...65000) {
                LabeledContent("Port", value: String(settings.network.port))
            }
        } header: { Text("Network") } footer: {
            Text("A new port applies after Sing! restarts on the Mac; pads paired before then need to pair again.")
        }
    }
}

public struct StorageDashboard: View {
    let report: StorageReport
    let onClear: (ClearCacheRequest) -> Void
    @State private var olderThan = 90

    public init(report: StorageReport, onClear: @escaping (ClearCacheRequest) -> Void) {
        self.report = report
        self.onClear = onClear
    }

    static func size(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    static let colors: [String: Color] = [
        "stems": .orange, "analysis": .yellow, "translations": .pink, "artwork": .purple,
        "recordings": .red, "models": .blue, "database": .green, "backups": .gray,
    ]

    public var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.size(report.totalBytes)).font(.title2.bold())
                    Text("used by Sing!").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Self.size(report.diskFreeBytes)) free on disk").foregroundStyle(report.lowDisk ? .red : .secondary)
                }
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(report.categories.filter { $0.bytes > 0 }) { c in
                            Rectangle().fill(Self.colors[c.id] ?? .gray)
                                .frame(width: max(3, geo.size.width * CGFloat(c.bytes) / CGFloat(max(report.totalBytes, 1))))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 12)
                if let limit = report.limitBytes {
                    ProgressView(value: min(1, Double(report.totalBytes) / Double(limit))) {
                        Text("\(Self.size(report.totalBytes)) of \(Self.size(limit)) limit").font(.caption)
                    }
                }
                if report.lowDisk {
                    Label("The disk is almost full. Clear some cache below.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            ForEach(report.categories) { c in
                HStack {
                    Circle().fill(Self.colors[c.id] ?? .gray).frame(width: 10, height: 10)
                    VStack(alignment: .leading) {
                        Text(c.name)
                        Text(c.items == 1 ? "1 item" : "\(c.items) items").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Self.size(c.bytes)).monospacedDigit().foregroundStyle(.secondary)
                    if c.clearable {
                        Button("Clear") { onClear(ClearCacheRequest(category: c.id)) }.disabled(c.bytes == 0)
                    }
                }
            }
        } header: { Text("Storage") }
        Section {
            Picker("Not sung for", selection: $olderThan) {
                ForEach([30, 90, 180, 365], id: \.self) { Text("\($0) days").tag($0) }
            }
            Button("Clear caches of songs not sung for \(olderThan) days") { onClear(ClearCacheRequest(notPlayedForDays: olderThan)) }
            Button("Clear every rebuildable cache", role: .destructive) { onClear(ClearCacheRequest()) }
        } header: { Text("Clear cache") } footer: {
            Text("Stems, lyrics and pitch are rebuilt the next time a song is queued. Your music files, history and favorites are never deleted.")
        }
        if !report.biggestSongs.isEmpty {
            Section("Biggest songs") {
                ForEach(report.biggestSongs.prefix(12)) { s in
                    HStack {
                        if s.pinned { Image(systemName: "pin.fill").foregroundStyle(.orange) }
                        VStack(alignment: .leading) {
                            Text(s.title).lineLimit(1)
                            Text(s.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(Self.size(s.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        Button { onClear(ClearCacheRequest(songID: s.id)) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).disabled(s.bytes == 0)
                    }
                }
            }
        }
    }
}

public struct PadListSection: View {
    let pads: [PadInfo]
    let onRevoke: (PadInfo) -> Void

    public init(pads: [PadInfo], onRevoke: @escaping (PadInfo) -> Void) {
        self.pads = pads
        self.onRevoke = onRevoke
    }

    public var body: some View {
        Section {
            if pads.isEmpty { Text("No device paired").foregroundStyle(.secondary) }
            ForEach(pads) { p in
                HStack {
                    Image(systemName: p.role == .host ? "crown.fill" : "person.fill").foregroundStyle(p.role == .host ? .orange : .secondary)
                    VStack(alignment: .leading) {
                        Text(p.name)
                        Text(p.connected ? "Connected now" : p.lastSeenAt.map { "Last seen \($0.formatted(.relative(presentation: .named)))" } ?? "Never connected")
                            .font(.caption).foregroundStyle(p.connected ? .green : .secondary)
                    }
                    Spacer()
                    Button("Unpair", role: .destructive) { onRevoke(p) }
                }
            }
        } header: { Text("Paired devices") } footer: {
            Text("Unpairing disconnects the device; it needs a code to come back.")
        }
    }
}

public struct PrivacySettingsSection: View {
    @Binding var privacy: PrivacySettings

    public init(privacy: Binding<PrivacySettings>) { _privacy = privacy }

    public var body: some View {
        Section {
            Toggle("Family mode", isOn: $privacy.familyMode)
            Toggle("Save history and stats", isOn: $privacy.keepHistory)
            Toggle("Guests can see stats", isOn: $privacy.guestsSeeStats)
            Toggle("Guests can request songs", isOn: $privacy.guestsCanRequest)
            Toggle("Guests can add themselves as singers", isOn: $privacy.guestsCanCreateSingers)
        } header: { Text("Privacy") } footer: {
            Text("Family mode hides explicit songs from the catalog and songs you mark as not for kids. With history off, nothing about tonight is saved or recorded.")
        }
    }
}

/// Timing, mix, key and family visibility for one song.
public struct SongSettingsForm: View {
    @Binding var settings: SongSettings

    public init(settings: Binding<SongSettings>) { _settings = settings }

    public var body: some View {
        Section("Lyrics") {
            Stepper(value: $settings.lyricOffsetMs, in: -5000...5000, step: 50) {
                LabeledContent("Lyric timing", value: settings.lyricOffsetMs == 0 ? "As found" : "\(settings.lyricOffsetMs > 0 ? "+" : "")\(settings.lyricOffsetMs) ms")
            }
            Text("Positive values show the words later.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Mix") {
            Toggle("Own guide vocal level", isOn: Binding(get: { settings.defaultGuideVocal != nil }, set: { settings.defaultGuideVocal = $0 ? 0.2 : nil }))
            if let g = settings.defaultGuideVocal {
                VStack(alignment: .leading) {
                    Text("Guide vocal: \(Int(g * 100))%")
                    Slider(value: Binding(get: { g }, set: { settings.defaultGuideVocal = $0 }), in: 0...1)
                }
            }
            Stepper(value: $settings.keyShift, in: -6...6) {
                LabeledContent("Key", value: settings.keyShift == 0 ? "Original" : "\(settings.keyShift > 0 ? "+" : "")\(settings.keyShift)")
            }
            Stepper(value: $settings.tempo, in: 0.75...1.25, step: 0.05) {
                LabeledContent("Tempo", value: "\(Int((settings.tempo * 100).rounded()))%")
            }
        }
        Section {
            Toggle("Hide in family mode", isOn: $settings.hiddenInFamilyMode)
            Toggle("Keep stems (never auto-delete)", isOn: $settings.pinned)
        }
    }
}
