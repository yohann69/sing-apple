import Charts
import SingClient
import SingCore
import SingDesign
import SwiftUI

struct SongRow: View {
    var song: SongSummary
    var detail: String?
    @Environment(PadModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(songID: song.id, palette: song.paletteColors)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(song.title).fontWeight(.semibold).lineLimit(1)
                    if song.isDuet { Image(systemName: "person.2.fill").font(.caption).foregroundStyle(.secondary) }
                }
                Text(detail ?? song.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(song.durationText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                ReadinessBadge(song.readiness, progress: model.state.preparing[song.id])
            }
        }
        .contentShape(Rectangle())
    }
}

struct SearchView: View {
    @Environment(PadModel.self) private var model
    @State private var query = ""
    @State private var results: [SongSummary] = []
    @State private var filters = SearchFilters()
    @State private var selected: SongSummary?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        filterChip("Ready now", on: filters.readyOnly) { filters.readyOnly.toggle() }
                        filterChip("Duets", on: filters.duetOnly) { filters.duetOnly.toggle() }
                        ForEach([1970, 1980, 1990, 2000, 2010, 2020], id: \.self) { d in
                            filterChip("\(d % 100 == 0 ? "00" : String(d % 100))s", on: filters.decade == d) { filters.decade = filters.decade == d ? nil : d }
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            ForEach(results) { s in
                Button { selected = s } label: { SongRow(song: s) }.buttonStyle(.plain)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .overlay {
            if results.isEmpty && !query.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Songs, artists, albums")
        .task(id: "\(query)|\(filters.readyOnly)|\(filters.duetOnly)|\(filters.decade ?? 0)") {
            try? await Task.sleep(for: .milliseconds(150))
            await search()
        }
        .refreshable { await search() }
        .sheet(item: $selected) { SongSheet(song: $0) }
    }

    private func search() async {
        guard let client = model.client else { return }
        do {
            results = try await client.search(query, filters: filters).songs
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func filterChip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.snappy) { action() } }) {
            Text(title).font(.subheadline.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .glassEffect(on ? .regular.tint(.accentColor.opacity(0.6)).interactive() : .regular.interactive(), in: .capsule)
        .padding(.vertical, 6)
    }
}

struct SongSheet: View {
    var song: SongSummary
    @Environment(PadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var chosen = Set<SingerID>()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    ArtworkView(songID: song.id, palette: song.paletteColors)
                        .frame(width: 200, height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 26))
                        .shadow(radius: 20, y: 10)
                    VStack(spacing: 4) {
                        Text(song.title).font(.title2.bold()).multilineTextAlignment(.center)
                        Text(song.artist).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            ReadinessBadge(song.readiness, progress: model.state.preparing[song.id])
                            if let k = song.lyricsKind { Label(k.rawValue.capitalized, systemImage: "text.quote").font(.caption) }
                            Text(song.durationText).font(.caption.monospacedDigit())
                        }
                        .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(song.isDuet ? "Who sings? Pick two for this duet" : "Who sings?").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                            ForEach(model.state.singers) { s in
                                Button {
                                    if chosen.contains(s.id) { chosen.remove(s.id) } else { chosen.insert(s.id) }
                                } label: {
                                    SingerChip(s).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                }
                                .buttonStyle(.plain)
                                .glassEffect(chosen.contains(s.id) ? .regular.tint(s.color.opacity(0.55)).interactive() : .regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
                            }
                        }
                    }
                    GlassEffectContainer {
                        VStack(spacing: 12) {
                            Button {
                                model.enqueue(song, singers: Array(chosen), playNext: false)
                                dismiss()
                            } label: {
                                Label("Add to queue", systemImage: "text.badge.plus").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            .controlSize(.large)
                            if model.isHost {
                                Button {
                                    model.enqueue(song, singers: Array(chosen), playNext: true)
                                    dismiss()
                                } label: {
                                    Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glass)
                                .controlSize(.large)
                            }
                        }
                    }
                }
                .padding(24)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.large])
        .onAppear { if let me = model.currentSingerID { chosen = [me] } }
    }
}

struct QueueView: View {
    @Environment(PadModel.self) private var model

    var body: some View {
        List {
            ForEach(Array(model.state.queue.enumerated()), id: \.element.id) { i, e in
                HStack(spacing: 12) {
                    Text("\(i + 1)").font(.headline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26)
                    SongRow(song: e.song, detail: e.singers.map(\.name).joined(separator: " & ").isEmpty ? e.song.artist : e.singers.map(\.name).joined(separator: " & ") + " · " + e.song.artist)
                }
                .swipeActions {
                    if model.isHost || e.addedBy == model.saved?.padID {
                        Button("Remove", role: .destructive) { model.send(.remove(entryID: e.id)) }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let t = e.estimatedStart {
                        Text("~\(t.formatted(date: .omitted, time: .shortened))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .onMove { from, to in
                guard model.isHost, let f = from.first else { return }
                let id = model.state.queue[f].id
                model.send(.move(.init(entryID: id, toIndex: to > f ? to - 1 : to)))
            }
            .moveDisabled(!model.isHost)
        }
        .overlay {
            if model.state.queue.isEmpty {
                ContentUnavailableView("The queue is empty", systemImage: "list.number", description: Text("Search for a song to get the party going."))
            }
        }
        .navigationTitle("Queue")
        .toolbar { if model.isHost { EditButton() } }
    }
}

struct SuggestionsView: View {
    @Environment(PadModel.self) private var model
    @State private var items: [Suggestion] = []
    @State private var selected: SongSummary?

    var body: some View {
        List(items) { s in
            Button { selected = s.song } label: { SongRow(song: s.song, detail: s.reason) }.buttonStyle(.plain)
        }
        .overlay { if items.isEmpty { ContentUnavailableView("No suggestions yet", systemImage: "sparkles", description: Text("Sing a few songs and suggestions get smarter.")) } }
        .navigationTitle(model.currentSinger.map { "For \($0.name)" } ?? "For You")
        .task(id: model.currentSingerID) { await load() }
        .refreshable { await load() }
        .sheet(item: $selected) { SongSheet(song: $0) }
    }

    private func load() async {
        items = (try? await model.client?.suggestions(singer: model.currentSingerID)) ?? []
    }
}

struct StatsView: View {
    @Environment(PadModel.self) private var model
    @State private var period: StatsPeriod = .tonight
    @State private var data: StatsResponse?
    @State private var mine: SingerStats?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Period", selection: $period) {
                    Text("Tonight").tag(StatsPeriod.tonight)
                    Text("This year").tag(StatsPeriod.year)
                    Text("All time").tag(StatsPeriod.allTime)
                }
                .pickerStyle(.segmented)
                if let d = data {
                    HStack(spacing: 12) {
                        tile("\(d.totalPlays)", "songs")
                        tile("\(d.totalMinutes)", "minutes")
                        tile("\(d.topSingers.count)", "singers")
                    }
                    if !d.topSingers.isEmpty {
                        card("Top singers") {
                            Chart(d.topSingers) { r in
                                BarMark(x: .value("Songs", r.count), y: .value("Singer", r.name))
                                    .foregroundStyle(r.colorHex.map { Color(hex: $0) } ?? .accentColor)
                                    .cornerRadius(6)
                            }
                            .frame(height: CGFloat(max(1, d.topSingers.count)) * 36)
                        }
                    }
                    card("Top songs") { ranked(d.topSongs.map { ("\($0.song.title)", $0.song.artist, $0.count) }) }
                    card("Top artists") { ranked(d.topArtists.map { ($0.name, nil, $0.count) }) }
                }
                if let mine {
                    card("You, \(mine.singer.name)") {
                        Text("\(mine.plays) songs sung").font(.title3.bold())
                        ranked(mine.topSongs.map { ($0.song.title, $0.song.artist, $0.count) })
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Stats")
        .task(id: period) { data = try? await model.client?.stats(period) }
        .task(id: model.currentSingerID) {
            if let id = model.currentSingerID { mine = try? await model.client?.singerStats(id) }
        }
        .refreshable { data = try? await model.client?.stats(period) }
    }

    private func tile(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading) {
            Text(v).font(.system(size: 30, weight: .heavy, design: .rounded))
            Text(l).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }

    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
    }

    private func ranked(_ rows: [(String, String?, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if rows.isEmpty { Text("Nothing yet").foregroundStyle(.secondary) }
            ForEach(Array(rows.prefix(8).enumerated()), id: \.offset) { i, r in
                HStack {
                    Text("\(i + 1)").foregroundStyle(.secondary).monospacedDigit().frame(width: 22)
                    VStack(alignment: .leading) {
                        Text(r.0).lineLimit(1)
                        if let sub = r.1 { Text(sub).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text("\(r.2)").fontWeight(.semibold).monospacedDigit()
                }
            }
        }
    }
}

struct PadSettingsView: View {
    @Environment(PadModel.self) private var model

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Mac", value: model.saved?.endpoint.name ?? "–")
                LabeledContent("Role", value: model.isHost ? "Host" : "Guest")
                LabeledContent("Status", value: statusText)
                Button("Disconnect from this Mac", role: .destructive) { model.disconnect() }
            }
            Section {
                Picker("Translate lyrics into", selection: Binding(get: { model.translationLanguage ?? "" }, set: { model.translationLanguage = $0.isEmpty ? nil : $0 })) {
                    Text("Off").tag("")
                    ForEach(model.languages, id: \.code) { l in Text(l.name).tag(l.code) }
                }
            } header: {
                Text("My lyrics")
            } footer: {
                Text("Translated on the Mac with on-device AI, shown under each line on this device.")
            }
            if model.isHost {
                let tv = Binding(get: { model.state.settings.tv }, set: { v in model.updateSettings { $0.tv = v } })
                let all = Binding(get: { model.state.settings }, set: { v in model.updateSettings { $0 = v } })
                TVDisplaySettingsSections(tv: tv, languages: model.languages.map { LanguageOption(code: $0.code, name: $0.name) })
                PartySettingsSections(settings: all)
            } else {
                Section {
                    Text("Only host pads can change the TV display and party settings.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
        .task { await model.loadLanguages() }
    }

    private var statusText: String {
        switch model.connection {
        case .none: "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .lost: "Reconnecting…"
        }
    }
}
