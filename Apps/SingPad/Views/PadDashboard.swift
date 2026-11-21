import SingClient
import SingCore
import SingDesign
import SwiftUI

/// iPad layout: always landscape, search always on the left, the stage on the right, no page scrolling.
struct PadDashboard: View {
    @Environment(PadModel.self) private var model
    @Environment(\.singTheme) private var theme
    @State private var page = "stage"
    @State private var pickingSinger = false

    var body: some View {
        let np = model.state.nowPlaying
        ZStack {
            BlobBackground(colors: (np.entry?.song.paletteColors ?? theme.blobs).vivid(with: theme), base: theme.background, period: 34, dim: 0.42)
            HStack(spacing: 0) {
                SearchPanel()
                    .frame(width: 400)
                    .padding(.leading, 16)
                    .padding(.vertical, 16)
                VStack(spacing: 14) {
                    topBar
                    Group {
                        switch page {
                        case "stats": StatsView().scrollContentBackground(.hidden)
                        case "settings": PadSettingsView().scrollContentBackground(.hidden)
                        default: StagePage()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.blurReplace)
                }
                .padding(16)
            }
        }
        .foregroundStyle(.white)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: page)
        .sheet(isPresented: $pickingSinger) { SingerPicker() }
        .task {
            try? await Task.sleep(for: .seconds(1))
            if model.currentSinger == nil { pickingSinger = true }
        }
        .alert(item: Binding(get: { model.upNextAlert.map { MainTabs.AlertItem(u: $0) } }, set: { _ in model.upNextAlert = nil })) { item in
            Alert(title: Text(item.u.songsAway == 1 ? "You're up next!" : "You're up in \(item.u.songsAway) songs"), message: Text("Get ready to sing."), dismissButton: .default(Text("OK")))
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 4) {
                    pageButton("stage", "Stage", "music.mic")
                    pageButton("stats", "Stats", "chart.bar.xaxis")
                    pageButton("settings", "Settings", "slider.horizontal.3")
                }
                .padding(4)
                .glassEffect(.regular, in: .capsule)
            }
            Spacer()
            if case .lost = model.connection {
                Label("Reconnecting…", systemImage: "wifi.exclamationmark").font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .glassEffect(.regular.tint(.orange.opacity(0.35)), in: .capsule)
            }
            Button { pickingSinger = true } label: {
                Group {
                    if let s = model.currentSinger { SingerChip(s) } else { Label("Who's singing?", systemImage: "person.crop.circle.badge.plus") }
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
    }

    private func pageButton(_ id: String, _ title: String, _ symbol: String) -> some View {
        Button { page = id } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .glassEffect(page == id ? .regular.tint(theme.accent.opacity(0.55)).interactive() : .identity, in: .capsule)
    }
}

struct StagePage: View {
    @Environment(PadModel.self) private var model
    @Environment(\.singTheme) private var theme

    var body: some View {
        let np = model.state.nowPlaying
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 24) {
                ArtworkView(songID: np.entry?.song.id, palette: np.entry?.song.paletteColors ?? theme.blobs)
                    .frame(width: 168, height: 168)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                    .id(np.entry?.song.id)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                VStack(alignment: .leading, spacing: 6) {
                    Text(stateLabel(np.state)).font(.caption.weight(.bold)).textCase(.uppercase).opacity(0.75)
                    Text(np.entry?.song.title ?? "Nothing playing").font(.system(size: 30, weight: .heavy)).lineLimit(2)
                    Text(np.entry?.song.artist ?? "Search on the left and queue a song").font(.title3).opacity(0.75).lineLimit(1)
                    HStack { ForEach(np.entry?.singers ?? []) { SingerChip($0) } }
                    if np.state == .preparing, let id = np.entry?.song.id {
                        ProgressView(value: model.state.preparing[id] ?? 0) { Text("Preparing the instrumental…").font(.caption) }
                            .tint(.white).frame(maxWidth: 280)
                    }
                }
                Spacer(minLength: 0)
                if model.isHost { CompactControls() }
            }
            .padding(18)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
            .animation(.spring(response: 0.6, dampingFraction: 0.85), value: np.entry?.id)

            if np.entry != nil {
                VStack(spacing: 10) {
                    LyricsCard()
                    ProgressBar()
                }
            }
            UpNextList()
                .frame(maxHeight: .infinity)
        }
    }

    private func stateLabel(_ s: PlaybackState) -> String {
        switch s {
        case .idle: "Waiting for a song"
        case .preparing: "Preparing"
        case .countdown: "Get ready"
        case .playing: "Now singing"
        case .paused: "Paused"
        case .finished: "Bravo!"
        }
    }
}

struct CompactControls: View {
    @Environment(PadModel.self) private var model
    @State private var guide: Double = 0
    @State private var editing = false

    var body: some View {
        let np = model.state.nowPlaying
        VStack(spacing: 14) {
            GlassEffectContainer(spacing: 16) {
                HStack(spacing: 14) {
                    round("backward.end.fill", 52, "Restart") { model.send(.transport(.restart)) }
                    round(np.state == .playing ? "pause.fill" : "play.fill", 70, np.state == .playing ? "Pause" : "Play") { model.send(.transport(.pause)) }
                    round("forward.end.fill", 52, "Next song") { model.send(.transport(.skip)) }
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "person.wave.2").help("Guide vocal")
                Slider(value: $guide, in: 0...1) { e in
                    editing = e
                    if !e { model.send(.setGuideVocal(guide)) }
                }
                .tint(.white)
                Text("\(Int(guide * 100))%").monospacedDigit().font(.caption).frame(width: 38, alignment: .trailing)
            }
            .frame(width: 250)
        }
        .onAppear { guide = np.guideVocal }
        .onChange(of: np.guideVocal) { _, v in if !editing { guide = v } }
    }

    private func round(_ symbol: String, _ size: CGFloat, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .bold))
                .frame(width: size, height: size)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

struct UpNextList: View {
    @Environment(PadModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Up next").font(.headline)
                Spacer()
                if !model.state.queue.isEmpty { Text("\(model.state.queue.count) songs").font(.caption).opacity(0.7) }
            }
            if model.state.queue.isEmpty {
                Text("Nobody is queued. Pick a song on the left!").opacity(0.7)
                Spacer(minLength: 0)
            } else {
                List {
                    ForEach(Array(model.state.queue.enumerated()), id: \.element.id) { i, e in
                        HStack(spacing: 12) {
                            Text("\(i + 1)").font(.headline.monospacedDigit()).opacity(0.6).frame(width: 22)
                            ArtworkView(songID: e.song.id, palette: e.song.paletteColors)
                                .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.song.title).fontWeight(.semibold).lineLimit(1)
                                Text(e.song.artist).font(.caption).opacity(0.7).lineLimit(1)
                            }
                            Spacer()
                            HStack(spacing: 4) { ForEach(e.singers) { SingerChip($0, compact: true) } }
                            if let t = e.estimatedStart { Text(t, style: .time).font(.caption.monospacedDigit()).opacity(0.7) }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(.white.opacity(0.12))
                        .swipeActions {
                            if model.isHost || e.addedBy == model.saved?.padID {
                                Button("Remove", role: .destructive) { model.send(.remove(entryID: e.id)) }
                            }
                        }
                    }
                    .onMove { from, to in
                        guard model.isHost, let f = from.first else { return }
                        model.send(.move(.init(entryID: model.state.queue[f].id, toIndex: to > f ? to - 1 : to)))
                    }
                    .moveDisabled(!model.isHost)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
    }
}

/// Search runs on the Mac: library first, then Apple Music and Deezer for songs the Mac does not have.
struct SearchPanel: View {
    @Environment(PadModel.self) private var model
    @State private var query = ""
    @State private var results = SearchResponse(songs: [], total: 0)
    @State private var suggestions: [Suggestion] = []
    @State private var filters = SearchFilters()
    @State private var selected: SongSummary?
    @State private var requesting: CatalogTrack?
    @State private var loading = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                TextField("Search any song or artist", text: $query)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if loading { ProgressView().controlSize(.small) }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).opacity(0.7)
                }
            }
            .padding(14)
            .glassEffect(.regular.interactive(), in: .capsule)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("Ready now", filters.readyOnly) { filters.readyOnly.toggle() }
                    chip("Duets", filters.duetOnly) { filters.duetOnly.toggle() }
                    ForEach([1980, 1990, 2000, 2010, 2020], id: \.self) { d in
                        chip("\(String(format: "%02d", d % 100))s", filters.decade == d) { filters.decade = filters.decade == d ? nil : d }
                    }
                }
            }

            List {
                if query.isEmpty {
                    Section(model.currentSinger.map { "For \($0.name)" } ?? "For you") {
                        ForEach(suggestions) { s in
                            Button { selected = s.song } label: { SongRow(song: s.song, detail: s.reason) }.buttonStyle(.plain)
                        }
                    }
                } else {
                    if !results.songs.isEmpty {
                        Section("In the library") {
                            ForEach(results.songs) { s in
                                Button { selected = s } label: { SongRow(song: s) }.buttonStyle(.plain)
                            }
                        }
                    }
                    if !results.catalog.isEmpty {
                        Section("Not in the library yet") {
                            ForEach(results.catalog) { t in
                                Button { requesting = t } label: { CatalogRow(track: t) }.buttonStyle(.plain)
                            }
                        }
                    }
                    if results.songs.isEmpty && results.catalog.isEmpty && !loading {
                        Text("Nothing found for “\(query)”").opacity(0.7)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .listRowBackground(Color.clear)
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30))
        .task(id: "\(query)|\(filters.readyOnly)|\(filters.duetOnly)|\(filters.decade ?? 0)") {
            try? await Task.sleep(for: .milliseconds(220))
            guard let client = model.client, !query.isEmpty else { return }
            loading = true
            if let r = try? await client.search(query, filters: filters) { results = r }
            loading = false
        }
        .task(id: model.currentSingerID) {
            suggestions = (try? await model.client?.suggestions(singer: model.currentSingerID)) ?? []
        }
        .sheet(item: $selected) { SongSheet(song: $0) }
        .sheet(item: $requesting) { RequestSheet(track: $0) }
    }

    private func chip(_ title: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy) { action() } } label: {
            Text(title).font(.subheadline.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .glassEffect(on ? .regular.tint(.accentColor.opacity(0.6)).interactive() : .regular.interactive(), in: .capsule)
    }
}

struct CatalogRow: View {
    var track: CatalogTrack

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: track.artworkURL.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { ArtworkPlaceholder(palette: []) }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .opacity(0.85)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).fontWeight(.semibold).lineLimit(1)
                Text(track.artist).font(.subheadline).opacity(0.7).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(track.durationText).font(.caption.monospacedDigit()).opacity(0.7)
                Label("Request", systemImage: "hand.raised.fill").font(.caption.weight(.semibold)).opacity(0.85)
            }
        }
        .contentShape(Rectangle())
    }
}

struct RequestSheet: View {
    var track: CatalogTrack
    @Environment(PadModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            AsyncImage(url: track.artworkURL.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { ArtworkPlaceholder(palette: []) }
                .frame(width: 180, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 24))
            VStack(spacing: 4) {
                Text(track.title).font(.title2.bold())
                Text(track.artist).foregroundStyle(.secondary)
                Text("Found on \(track.sources.joined(separator: " and "))").font(.caption).foregroundStyle(.secondary)
            }
            Text("This song is not on the Mac yet. Request it and the host sees it in the queue screen.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                model.send(.request(.init(track: track, singerIDs: model.currentSingerID.map { [$0] } ?? [])))
                model.toast = "Requested \(track.title)"
                dismiss()
            } label: {
                Label("Request this song", systemImage: "hand.raised.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(28)
        .presentationDetents([.medium, .large])
    }
}
