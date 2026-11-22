import SingClient
import SingCore
import SingDesign
import SwiftUI

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
                    Text(np.entry?.song.artist ?? "Open Search to queue a song").font(.title3).opacity(0.75).lineLimit(1)
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

            if let r = model.state.result, np.state == .finished {
                ResultCard(result: r).transition(.scale(scale: 0.95).combined(with: .opacity))
            } else if np.entry != nil {
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
    @State private var mixer = false
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
                    round("slider.vertical.3", 52, "Mixer") { mixer = true }
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
        .sheet(isPresented: $mixer) { MixerSheet() }
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
                Text("Nobody is queued. Open Search to pick a song!").opacity(0.7)
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
    @State private var humResults: [SongSummary]?
    @State private var askMode = false
    @State private var lineMode = false
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
                HumButton { found in humResults = found; query = "" }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).opacity(0.7)
                }
            }
            .padding(14)
            .glassEffect(.regular.interactive(), in: .capsule)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("Ready now", filters.readyOnly) { filters.readyOnly.toggle() }
                    chip("✨ Ask", askMode) { askMode.toggle(); lineMode = false }
                    chip("Lyric line", lineMode) { lineMode.toggle(); askMode = false }
                    chip("Favorites", filters.favoritesOf != nil) { filters.favoritesOf = filters.favoritesOf == nil ? model.currentSingerID : nil }
                    chip("Duets", filters.duetOnly) { filters.duetOnly.toggle() }
                    ForEach([1980, 1990, 2000, 2010, 2020], id: \.self) { d in
                        chip("\(String(format: "%02d", d % 100))s", filters.decade == d) { filters.decade = filters.decade == d ? nil : d }
                    }
                }
            }

            List {
                if let hum = humResults, query.isEmpty {
                    Section("Sounds like") {
                        ForEach(hum) { s in Button { selected = s } label: { SongRow(song: s) }.buttonStyle(.plain) }
                        if hum.isEmpty { Text("No match. Hum the chorus a bit longer, or only songs already prepared can be found.").opacity(0.7) }
                        Button("Clear") { humResults = nil }
                    }
                } else if query.isEmpty && filters.favoritesOf != nil {
                    Section("Favorites") {
                        ForEach(results.songs) { s in
                            Button { selected = s } label: { SongRow(song: s) }.buttonStyle(.plain)
                        }
                        if results.songs.isEmpty { Text("Tap the heart on a song to keep it here.").opacity(0.7) }
                    }
                } else if query.isEmpty {
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
        .task(id: "\(query)|\(filters.readyOnly)|\(filters.duetOnly)|\(filters.decade ?? 0)|\(filters.favoritesOf ?? 0)|\(model.ratings.count)|\(askMode)|\(lineMode)") {
            try? await Task.sleep(for: .milliseconds(220))
            guard let client = model.client, !query.isEmpty || filters.favoritesOf != nil else { return }
            loading = true
            if lineMode, !query.isEmpty {
                if let r = try? await client.searchLines(query) { results = r }
            } else if askMode, !query.isEmpty {
                if let r = try? await client.ask(query) { results = r }
            } else if let r = try? await client.search(query, filters: filters) { results = r }
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

struct ResultCard: View {
    var result: PerformanceResult

    var body: some View {
        HStack(spacing: 24) {
            VStack(spacing: 4) {
                Text(result.total.map(String.init) ?? "♪").font(.system(size: 64, weight: .black, design: .rounded))
                if let g = result.grade { Text("Grade \(g)").font(.headline).opacity(0.75) }
            }
            .frame(width: 140)
            VStack(alignment: .leading, spacing: 6) {
                Text(result.title).font(.title2.weight(.heavy))
                Text(result.comment).opacity(0.8)
                HStack(spacing: 14) {
                    ForEach(result.categories) { c in
                        VStack(spacing: 2) {
                            Text("\(c.value)").font(.headline.monospacedDigit())
                            Text(c.name).font(.caption).opacity(0.7)
                        }
                    }
                }
                .padding(.top, 4)
            }
            if result.applause != nil || (result.perSinger?.count ?? 0) > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(result.perSinger ?? []) { p in Text("\(p.name): \(p.count)").font(.headline) }
                    if let a = result.applause { Text("👏 \(a)").font(.headline) }
                }
            }
            Spacer(minLength: 0)
            if let url = result.shareURL {
                VStack(spacing: 6) {
                    QRCodeView(url).padding(8).background(.white, in: RoundedRectangle(cornerRadius: 12)).frame(width: 110, height: 110)
                    Text("Take it home").font(.caption).opacity(0.75)
                }
            }
        }
        .padding(20)
        .glassEffect(.regular.tint((result.singers.first?.color ?? .orange).opacity(0.25)), in: RoundedRectangle(cornerRadius: 28))
    }
}

/// Host mixer: every level the Mac exposes, applied live.
struct MixerSheet: View {
    @Environment(PadModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private func binding(_ get: @escaping (PlaybackSettings) -> Double, _ set: @escaping (inout PlaybackSettings, Double) -> Void) -> Binding<Double> {
        Binding(get: { get(model.state.settings.playback) }, set: { v in model.updateSettings { set(&$0.playback, v) } })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Music") {
                    slider("Guide vocal", "person.wave.2", Binding(get: { model.state.nowPlaying.guideVocal }, set: { model.send(.setGuideVocal($0)) }))
                    slider("Music volume", "speaker.wave.2", binding({ $0.musicVolume }) { $0.musicVolume = $1 })
                    let np = model.state.nowPlaying
                    Stepper(value: Binding(get: { np.keyShift }, set: { model.send(.setKey($0)) }), in: -6...6) {
                        LabeledContent { Text(np.keyShift == 0 ? "Original" : "\(np.keyShift > 0 ? "+" : "")\(np.keyShift)").monospacedDigit() } label: { Label("Key", systemImage: "music.note") }
                    }
                    Stepper(value: Binding(get: { np.lyricOffsetMs }, set: { model.send(.setLyricOffset(ms: $0)) }), in: -5000...5000, step: 100) {
                        LabeledContent { Text(np.lyricOffsetMs == 0 ? "As found" : "\(np.lyricOffsetMs > 0 ? "+" : "")\(np.lyricOffsetMs) ms").monospacedDigit() } label: { Label("Lyric timing", systemImage: "text.badge.checkmark") }
                    }
                    Stepper(value: Binding(get: { np.tempo }, set: { model.send(.setTempo($0)) }), in: 0.75...1.25, step: 0.05) {
                        LabeledContent { Text("\(Int((np.tempo * 100).rounded()))%").monospacedDigit() } label: { Label("Tempo", systemImage: "metronome") }
                    }
                }
                Section {
                    Toggle(isOn: Binding(get: { model.state.settings.playback.micEnabled }, set: { v in model.updateSettings { $0.playback.micEnabled = v } })) {
                        Label("Microphone", systemImage: "mic")
                    }
                    slider("Mic volume", "mic.fill", binding({ $0.micGain }) { $0.micGain = $1 })
                    Picker(selection: Binding(get: { model.state.settings.playback.micPreset }, set: { p in model.updateSettings { $0.playback.micPreset = p } })) {
                        ForEach(MicPreset.allCases, id: \.rawValue) { Text($0.name).tag($0.rawValue) }
                    } label: { Label("Effect", systemImage: "sparkles") }
                    slider("Reverb", "waveform.path", binding({ $0.micReverb }) { $0.micReverb = $1 })
                    slider("Echo", "dot.radiowaves.right", binding({ $0.micEcho }) { $0.micEcho = $1 })
                } header: {
                    Text("Microphone")
                } footer: {
                    if let mic = model.state.mic {
                        Text(mic.message ?? (mic.state == .running ? "Live on \(mic.deviceName ?? "the Mac's mic")" : mic.state.rawValue.capitalized))
                    }
                }
                Section {
                    let np = model.state.nowPlaying
                    if np.loopStartMs != nil {
                        Button { model.send(.setLoop(.init(startMs: nil, endMs: nil))) } label: { Label("Stop the loop", systemImage: "repeat.circle.fill") }
                    } else {
                        Button { loopLines(1) } label: { Label("Loop this line", systemImage: "repeat.1") }
                        Button { loopLines(4) } label: { Label("Loop the next four lines", systemImage: "repeat") }
                    }
                } header: { Text("Practice") } footer: { Text("A practice loop is not saved to the stats or recorded.") }
                Section {
                    Toggle(isOn: Binding(get: { model.phoneMicOn }, set: { _ in model.togglePhoneMic() })) {
                        Label("Use this device as a mic", systemImage: "iphone.radiowaves.left.and.right")
                    }
                } footer: { Text("Experimental: your voice goes to the Mac over Wi-Fi with a small delay. Use headphones off and keep away from the speakers.") }
                MicSettingsSection(playback: Binding(get: { model.state.settings.playback }, set: { v in model.updateSettings { $0.playback = v } }), channels: max(1, model.meters.count))
                Section("Next songs") {
                    slider("Default guide vocal", "person.wave.2.fill", binding({ $0.defaultGuideVocal }) { $0.defaultGuideVocal = $1 })
                }
            }
            .navigationTitle("Mixer")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func loopLines(_ count: Int) {
        guard let l = model.lyrics, !l.lines.isEmpty else { return }
        let t = model.position
        let i = l.lineIndex(at: t) ?? l.lines.firstIndex { $0.start > t } ?? 0
        let last = min(l.lines.count - 1, i + count - 1)
        let start = max(0, l.lines[i].start - 1.0), end = l.lines[last].end + 0.6
        model.send(.setLoop(.init(startMs: Int(start * 1000), endMs: Int(end * 1000))))
    }

    private func slider(_ title: String, _ symbol: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1)
        }
    }
}

import AVFoundation

/// Records eight seconds of humming and asks the Mac which song it is.
struct HumButton: View {
    var onResult: ([SongSummary]) -> Void
    @Environment(PadModel.self) private var model
    @State private var recorder: AVAudioRecorder?
    @State private var busy = false

    var body: some View {
        Button { Task { await hum() } } label: {
            Image(systemName: recorder != nil ? "waveform.circle.fill" : busy ? "ellipsis.circle" : "music.mic.circle")
                .font(.title2).symbolEffect(.pulse, isActive: recorder != nil)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel("Hum to search")
    }

    private func hum() async {
        guard await AVAudioApplication.requestRecordPermission() else { model.toast = "Allow the microphone in Settings to hum a song"; return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try? session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hum.m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48000]
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else { return }
        recorder = r
        model.toast = "Hum the chorus for 8 seconds…"
        r.record(forDuration: 8)
        try? await Task.sleep(for: .seconds(8.3))
        r.stop()
        recorder = nil
        busy = true
        defer { busy = false }
        guard let data = try? Data(contentsOf: url), let client = model.client else { return }
        do { onResult(try await client.humSearch(data)) } catch { model.toast = error.localizedDescription }
    }
}
