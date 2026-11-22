import SingClient
import SingCore
import SingDesign
import SwiftUI

struct MainTabs: View {
    @Environment(PadModel.self) private var model
    @State private var tab = "now"
    @State private var pickingSinger = false

    var body: some View {
        TabView(selection: $tab) {
            Tab("Now Playing", systemImage: "music.mic", value: "now") {
                NavigationStack {
                    Group {
                        if UIDevice.current.userInterfaceIdiom == .pad { PadStage() } else { NowPlayingView() }
                    }
                    .toolbar { singerButton }
                }
            }
            Tab("Queue", systemImage: "list.number", value: "queue") {
                NavigationStack { QueueView().toolbar { singerButton } }
            }
            .badge(model.state.queue.count)
            Tab("For You", systemImage: "sparkles", value: "foryou") {
                NavigationStack { SuggestionsView().toolbar { singerButton } }
            }
            Tab("Stats", systemImage: "chart.bar.xaxis", value: "stats") {
                NavigationStack { StatsView() }
            }
            Tab("Settings", systemImage: "slider.horizontal.3", value: "settings") {
                NavigationStack { PadSettingsView() }
            }
            Tab(value: "search", role: .search) {
                NavigationStack { PadSearch().toolbar { singerButton } }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .sheet(isPresented: $pickingSinger) { SingerPicker() }
        .task {
            if model.currentSinger == nil {
                try? await Task.sleep(for: .seconds(1))
                if model.currentSinger == nil { pickingSinger = true }
            }
        }
        .alert(item: Binding(get: { model.upNextAlert.map { AlertItem(u: $0) } }, set: { _ in model.upNextAlert = nil })) { item in
            Alert(title: Text(item.u.songsAway == 1 ? "You're up next!" : "You're up in \(item.u.songsAway) songs"), message: Text("Get ready to sing."), dismissButton: .default(Text("OK")))
        }
    }

    struct AlertItem: Identifiable {
        var u: ServerMessage.YoureUp
        var id: String { u.entryID + "\(u.songsAway)" }
    }

    private var singerButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { pickingSinger = true } label: {
                if let s = model.currentSinger {
                    SingerChip(s)
                } else {
                    Label("Who's singing?", systemImage: "person.crop.circle.badge.plus")
                }
            }
        }
    }
}

struct MiniPlayer: View {
    @Environment(PadModel.self) private var model

    var body: some View {
        let np = model.state.nowPlaying
        HStack(spacing: 12) {
            ArtworkView(songID: np.entry?.song.id, palette: np.entry?.song.paletteColors ?? [])
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 0) {
                Text(np.entry?.song.title ?? "Nothing playing").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(np.currentLine ?? np.entry?.song.artist ?? "Queue a song").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.isHost {
                Button { model.send(.transport(.pause)) } label: {
                    Image(systemName: np.state == .playing ? "pause.fill" : "play.fill").contentTransition(.symbolEffect(.replace))
                }
                Button { model.send(.transport(.skip)) } label: { Image(systemName: "forward.fill") }
            }
        }
        .padding(.horizontal, 14)
    }
}

struct ArtworkView: View {
    var songID: SongID?
    var palette: [Color]
    @Environment(PadModel.self) private var model
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { ArtworkPlaceholder(palette: palette) }
        }
        .task(id: songID) {
            image = nil
            if let songID { image = await model.artwork(songID) }
        }
    }
}

struct SingerPicker: View {
    @Environment(PadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var emoji = ""
    @State private var error: String?
    @State private var pin = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Pick your profile so your songs, stats and suggestions follow you.").foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(model.state.singers) { s in
                            Button {
                                model.choose(s)
                                if model.pinFor == nil { dismiss() }
                            } label: {
                                SingerChip(s).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(model.currentSingerID == s.id ? .regular.tint(s.color.opacity(0.5)).interactive() : .regular.interactive(), in: RoundedRectangle(cornerRadius: 18))
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("New singer").font(.headline)
                        HStack {
                            TextField("🎤", text: $emoji).frame(width: 50).multilineTextAlignment(.center)
                                .padding(12).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
                            TextField("Name", text: $name).padding(12).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
                            Button("Create") { create() }.buttonStyle(.glassProminent).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        if let error { Text(error).foregroundStyle(.red) }
                    }
                }
                .padding(24)
            }
            .navigationTitle("Who's singing?")
            .alert("PIN for \(model.pinFor?.name ?? "")", isPresented: Binding(get: { model.pinFor != nil }, set: { if !$0 { model.pinFor = nil } })) {
                SecureField("PIN", text: $pin).keyboardType(.numberPad)
                Button("Unlock") { if let s = model.pinFor { Task { await model.unlock(s, pin: pin); pin = ""; if model.currentSingerID == s.id { dismiss() } } } }
                Button("Cancel", role: .cancel) { model.pinFor = nil }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func create() {
        Task {
            do {
                let s = try await model.createSinger(name: name, emoji: emoji.isEmpty ? nil : String(emoji.prefix(2)))
                model.currentSingerID = s.id
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Landscape iPad stage: everything on one screen, no scrolling.
struct PadStage: View {
    @Environment(PadModel.self) private var model
    @Environment(\.singTheme) private var theme
    @State private var teleprompter = false

    var body: some View {
        let np = model.state.nowPlaying
        ZStack {
            BlobBackground(colors: (np.entry?.song.paletteColors ?? theme.blobs).vivid(with: theme), base: theme.background, period: 34, dim: 0.42)
            StagePage().padding(.horizontal, 24).padding(.bottom, 16)
        }
        .foregroundStyle(.white)
        .navigationTitle("Now Playing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { teleprompter = true } label: { Label("Teleprompter", systemImage: "text.viewfinder") } } }
        .fullScreenCover(isPresented: $teleprompter) { Teleprompter() }
    }
}

/// Search tab: the Mac searches the library, then Apple Music and Deezer.
struct PadSearch: View {
    @Environment(\.singTheme) private var theme

    var body: some View {
        ZStack {
            BlobBackground(colors: theme.blobs, base: theme.background, period: 40, dim: 0.5)
            SearchPanel().padding(.horizontal, 20).padding(.bottom, 12)
        }
        .foregroundStyle(.white)
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The TV's lyrics full screen on this device, for whoever is holding it while they sing.
struct Teleprompter: View {
    @Environment(PadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pitch: PitchTrack?
    @State private var art: Image?

    var body: some View {
        let s = model.state
        var m = TVStageModel(
            nowPlaying: s.nowPlaying, lyrics: model.lyrics, upNext: s.queue.first, settings: s.settings.tv, artwork: art,
            joinURL: s.joinURL ?? "", guestCode: "", preparingProgress: s.nowPlaying.entry.flatMap { s.preparing[$0.song.id] },
            countdownEnd: s.nowPlaying.state == .countdown ? s.nowPlaying.positionAt.addingTimeInterval(3) : nil,
            duration: Double(s.nowPlaying.entry?.song.durationMs ?? 0) / 1000, queuePreview: s.queue
        )
        m.pitch = pitch
        m.result = s.result
        m.leaderboard = s.leaderboard ?? []
        m.meters = { [model] in model.meters }
        return TVStageView(model: m) { model.position }
            .overlay(alignment: .topTrailing) {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.title2.bold()).padding(14) }
                    .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle).padding(24)
            }
            .persistentSystemOverlays(.hidden)
            .statusBarHidden()
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            .task(id: s.nowPlaying.entry?.song.id) {
                guard let id = s.nowPlaying.entry?.song.id else { return }
                pitch = try? await model.client?.displayPitch(id)
                art = await model.artwork(id).map { Image(uiImage: $0) }
            }
    }
}
