import AppKit
import Charts
import SingCore
import SingDesign
import SingHost
import SwiftUI

struct QueuePane: View {
    var host: HostController

    var body: some View {
        let entries = host.queue.withEstimates(remainingCurrent: max(0, host.duration - host.lyricTime))
        List {
            ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                HStack(spacing: 12) {
                    Text("\(i + 1)").font(.title3.monospacedDigit().bold()).foregroundStyle(.secondary).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.song.title).fontWeight(.semibold)
                        Text(e.song.artist).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack { ForEach(e.singers) { SingerChip($0) } }
                    ReadinessBadge(e.song.readiness, progress: host.preparing[e.song.id]).frame(width: 130, alignment: .leading)
                    if let t = e.estimatedStart { Text(t, style: .time).monospacedDigit().foregroundStyle(.secondary) }
                    Button(role: .destructive) { try? host.removeFromQueue(e.id, by: nil) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
            }
            .onMove { from, to in
                guard let f = from.first else { return }
                try? host.moveInQueue(entries[f].id, to: to > f ? to - 1 : to)
            }
            if !host.requests.isEmpty {
                Section("Requested, not in your library") {
                    ForEach(host.requests) { r in
                        HStack(spacing: 12) {
                            AsyncImage(url: r.track.artworkURL.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                                .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading) {
                                Text(r.track.title).fontWeight(.semibold)
                                Text("\(r.track.artist) · \(r.track.sources.joined(separator: ", "))").foregroundStyle(.secondary)
                            }
                            Spacer()
                            HStack { ForEach(r.singers) { SingerChip($0, compact: true) } }
                            Text("\(r.votes) ♥").monospacedDigit().foregroundStyle(.secondary)
                            Button { host.dismissRequest(r.id) } label: { Image(systemName: "checkmark.circle") }
                                .buttonStyle(.borderless).help("Mark as handled")
                        }
                    }
                }
            }
        }
        .overlay {
            if entries.isEmpty { ContentUnavailableView("The queue is empty", systemImage: "list.number", description: Text("Songs queued from the library or from pads show up here.")) }
        }
        .navigationTitle("Queue")
        .navigationSubtitle(host.session.map { "Party started \($0.startedAt.formatted(date: .omitted, time: .shortened))" } ?? "No party running")
        .toolbar {
            ToolbarItem {
                if host.session != nil {
                    Button("End Party") { Task { await host.endSession() } }
                } else {
                    Button("Start Party") { Task { await host.startSession() } }
                }
            }
        }
    }
}

struct SingersPane: View {
    var host: HostController
    @State private var name = ""
    @State private var stats: [SingerID: SingerStats] = [:]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                ForEach(host.singers) { s in
                    VStack(alignment: .leading, spacing: 10) {
                        SingerChip(s)
                        Text("\(stats[s.id]?.plays ?? 0) songs sung").font(.callout).foregroundStyle(.secondary)
                        if let top = stats[s.id]?.topSongs.first {
                            Text("Favourite: \(top.song.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .glassEffect(.regular.tint(s.color.opacity(0.15)), in: RoundedRectangle(cornerRadius: 20))
                    .task { stats[s.id] = try? await host.singerStats(s.id) }
                }
            }
            .padding(24)
        }
        .overlay {
            if host.singers.isEmpty { ContentUnavailableView("No singers yet", systemImage: "person.2", description: Text("Singers are created from the pads or here.")) }
        }
        .toolbar {
            ToolbarItem {
                HStack {
                    TextField("New singer", text: $name).frame(width: 160).onSubmit(add)
                    Button("Add", action: add)
                }
            }
        }
        .navigationTitle("Singers")
    }

    private func add() {
        let n = name
        name = ""
        Task { _ = try? await host.addSinger(name: n, emoji: nil, padID: nil) }
    }
}

struct StatsPane: View {
    var host: HostController
    @State private var period: StatsPeriod = .allTime
    @State private var data: StatsResponse?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Period", selection: $period) {
                    Text("Tonight").tag(StatsPeriod.tonight)
                    Text("This year").tag(StatsPeriod.year)
                    Text("All time").tag(StatsPeriod.allTime)
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                if let d = data {
                    HStack(spacing: 16) {
                        StatTile(value: "\(d.totalPlays)", label: "songs sung")
                        StatTile(value: "\(d.totalMinutes)", label: "minutes")
                        StatTile(value: "\(d.distinctSongs)", label: "different songs")
                        StatTile(value: "\(d.topSingers.count)", label: "singers")
                    }
                    HStack(alignment: .top, spacing: 16) {
                        RankCard(title: "Top songs", rows: d.topSongs.map { ("\($0.song.title) · \($0.song.artist)", $0.count, nil) })
                        RankCard(title: "Top singers", rows: d.topSingers.map { ($0.name, $0.count, $0.colorHex) })
                    }
                    HStack(alignment: .top, spacing: 16) {
                        RankCard(title: "Top artists", rows: d.topArtists.map { ($0.name, $0.count, nil) })
                        RankCard(title: "Most skipped", rows: d.mostSkipped.map { ($0.song.title, $0.count, nil) })
                    }
                    if !d.decades.isEmpty {
                        VStack(alignment: .leading) {
                            Text("Decades").font(.headline)
                            Chart(d.decades) { Bar in
                                BarMark(x: .value("Decade", Bar.name), y: .value("Plays", Bar.count)).foregroundStyle(.orange.gradient)
                            }
                            .frame(height: 180)
                        }
                        .padding(18)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
                    }
                }
            }
            .padding(24)
        }
        .task(id: period) { data = try? await host.stats(period) }
        .navigationTitle("Stats")
    }
}

struct StatTile: View {
    var value: String
    var label: String

    var body: some View {
        VStack(alignment: .leading) {
            Text(value).font(.system(size: 34, weight: .heavy, design: .rounded)).contentTransition(.numericText())
            Text(label).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct RankCard: View {
    var title: String
    var rows: [(String, Int, String?)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if rows.isEmpty { Text("Nothing yet").foregroundStyle(.secondary) }
            ForEach(Array(rows.prefix(8).enumerated()), id: \.offset) { i, r in
                HStack {
                    Text("\(i + 1)").foregroundStyle(.secondary).monospacedDigit().frame(width: 20)
                    if let hex = r.2 { Circle().fill(Color(hex: hex)).frame(width: 10, height: 10) }
                    Text(r.0).lineLimit(1)
                    Spacer()
                    Text("\(r.1)").monospacedDigit().fontWeight(.semibold)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct PadsPane: View {
    var host: HostController
    @State private var pads: [PadInfo] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 24) {
                    codeCard(title: "Host pads", subtitle: "Full control: transport, mixer, settings. Keep this code private.", code: host.hostCode, url: host.hostJoinURL)
                    codeCard(title: "Guests", subtitle: "Search and queue their own songs. This QR is also shown on the TV.", code: host.guestCode, url: host.joinURL) {
                        Button("New guest code") { host.regenerateGuestCode() }
                    }
                }
                Form {
                    PadListSection(pads: pads) { p in Task { await host.revokePad(p.id); pads = await host.padList() } }
                    Section {
                        Text("Address: \(host.hostJoinURL.replacingOccurrences(of: "sing://", with: "").components(separatedBy: "?").first ?? "")").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("Unpair every device", role: .destructive) { Task { await host.revokeAllPads(); pads = await host.padList() } }
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(minHeight: CGFloat(160 + max(1, pads.count) * 52))
            }
            .padding(24)
        }
        .navigationTitle("Pads")
        .task(id: host.connectedPads.map(\.padID)) { pads = await host.padList() }
    }

    private func codeCard(title: String, subtitle: String, code: String, url: String, @ViewBuilder extra: () -> some View = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.bold())
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 20) {
                QRCodeView(url).padding(10).background(.white, in: RoundedRectangle(cornerRadius: 14)).frame(width: 150, height: 150)
                VStack(alignment: .leading) {
                    Text("Code").font(.caption).foregroundStyle(.secondary)
                    Text(code).font(.system(size: 34, weight: .bold, design: .monospaced)).textSelection(.enabled)
                    extra()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct StoragePane: View {
    var host: HostController
    @State private var report: StorageReport?
    @State private var pending: ClearCacheRequest?
    @State private var preview: ClearCacheResult?

    var body: some View {
        Form {
            if let report {
                StorageDashboard(report: report) { req in
                    Task {
                        var dry = req
                        dry.dryRun = true
                        preview = await host.clearCache(dry)
                        pending = req
                    }
                }
            } else {
                ProgressView("Measuring…")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Storage")
        .task { report = await host.storageReport() }
        .refreshable { report = await host.storageReport() }
        .confirmationDialog("Free \(ByteCountFormatter.string(fromByteCount: preview?.freedBytes ?? 0, countStyle: .file))?",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                guard let req = pending else { return }
                Task { _ = await host.clearCache(req); report = await host.storageReport() }
            }
        } message: {
            Text(preview.map { "\($0.songs) songs are affected. They are processed again when queued." } ?? "")
        }
    }
}
