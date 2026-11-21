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
                NavigationStack { NowPlayingView().toolbar { singerButton } }
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
                NavigationStack { SearchView().toolbar { singerButton } }
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Pick your profile so your songs, stats and suggestions follow you.").foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(model.state.singers) { s in
                            Button {
                                model.currentSingerID = s.id
                                dismiss()
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
