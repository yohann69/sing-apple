import SingCore
import SingDesign
import SingHost
import SwiftUI
import UniformTypeIdentifiers

struct LibraryPane: View {
    var host: HostController
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var results: [SongSummary]?
    @State private var selection = Set<SongID>()
    @State private var importing = false
    @State private var dropTargeted = false
    @State private var queueFor: SongSummary?
    @State private var editing: SongSummary?
    @State private var syncing: SongSummary?
    @State private var genre = ""

    private var shown: [SongSummary] {
        let base = (results.flatMap { r in query.isEmpty ? nil : r.compactMap { x in host.songs.first { $0.id == x.id } ?? x } }) ?? host.songs
        return genre.isEmpty ? base : base.filter { $0.genre == genre || $0.language == genre }
    }

    var body: some View {
        Table(shown, selection: $selection) {
            TableColumn("") { s in
                Group {
                    if let img = app.artwork.image(s.id, host: host) { img.resizable().scaledToFill() } else { ArtworkPlaceholder(palette: s.paletteColors) }
                }
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .width(40)
            TableColumn("Title") { s in Text(s.title).fontWeight(.medium) }
            TableColumn("Artist", value: \.artist)
            TableColumn("Time") { s in Text(s.durationText).monospacedDigit().foregroundStyle(.secondary) }.width(60)
            TableColumn("Lyrics") { s in
                Text(s.lyricsKind.map { $0.rawValue.capitalized } ?? "–").foregroundStyle(.secondary)
            }
            .width(70)
            TableColumn("Status") { s in ReadinessBadge(s.readiness, progress: host.preparing[s.id]) }.width(140)
            TableColumn("Plays") { s in Text("\(s.playCount)").monospacedDigit().foregroundStyle(.secondary) }.width(50)
        }
        .contextMenu(forSelectionType: SongID.self) { ids in
            if let id = ids.first, let song = host.songs.first(where: { $0.id == id }) {
                Button("Queue…") { queueFor = song }
                Button("Play Next") { Task { try? await host.enqueue(songID: id, singerIDs: [], playNext: true, by: nil) } }
                Divider()
                Button("Song Settings…") { editing = song }
                Button("Edit Lyric Timing…") { syncing = song }
                Button("Find Lyrics Again (providers, then AI timing)") { Task { await host.refreshLyrics(id, force: true) } }
                Button("Keep Stems (never auto-delete)") { Task { await host.setPinned(id, true) } }
                Button("Allow Auto-Delete of Stems") { Task { await host.setPinned(id, false) } }
                Button("Clear This Song's Cache") { Task { _ = await host.clearCache(ClearCacheRequest(songID: id)) } }
            }
        } primaryAction: { ids in
            if let id = ids.first, let song = host.songs.first(where: { $0.id == id }) { queueFor = song }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search title, artist, album")
        .task(id: query) {
            guard !query.isEmpty else { results = nil; return }
            try? await Task.sleep(for: .milliseconds(120))
            results = try? await host.search(query, filters: SearchFilters()).songs
        }
        .overlay {
            if host.songs.isEmpty {
                ContentUnavailableView {
                    Label("Your library is empty", systemImage: "music.note.list")
                } description: {
                    Text("Drop audio files or folders here (MP3, FLAC, WAV, AAC, ALAC).")
                } actions: {
                    Button("Add Music…") { importing = true }.buttonStyle(.glassProminent)
                }
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 20).strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [10, 6])).padding(12)
            }
        }
        .overlay(alignment: .bottom) {
            if let p = host.importProgress {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1))) { Text("Importing \(p.done) of \(p.total)") }
                    .padding(16)
                    .frame(width: 360)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
                    .padding(20)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data, let u = URL(dataRepresentation: url, relativeTo: nil) { urls.append(u) }
                }
                await host.importFiles(urls)
            }
            return true
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await host.importFiles(urls) } }
        }
        .toolbar {
            ToolbarItem {
                Button { importing = true } label: { Label("Add Music", systemImage: "plus") }
            }
        }
        .sheet(item: $editing) { SongSettingsSheet(host: host, song: $0) }
        .sheet(item: $syncing) { s in NavigationStack { SyncEditorView(host: host, song: s) } }
        .toolbar {
            Picker("Filter", selection: $genre) {
                Text("All songs").tag("")
                let genres = Set(host.songs.compactMap(\.genre)).sorted()
                if !genres.isEmpty { Section("Genre") { ForEach(genres, id: \.self) { Text($0).tag($0) } } }
                let langs = Set(host.songs.compactMap(\.language)).sorted()
                if !langs.isEmpty { Section("Language") { ForEach(langs, id: \.self) { Text(Locale.current.localizedString(forLanguageCode: $0) ?? $0).tag($0) } } }
            }
        }
        .sheet(item: $queueFor) { song in
            QueueSheet(host: host, song: song)
        }
        .navigationTitle("Library")
        .navigationSubtitle("\(host.songs.count) songs")
    }
}

struct QueueSheet: View {
    var host: HostController
    var song: SongSummary
    @Environment(\.dismiss) private var dismiss
    @State private var chosen = Set<SingerID>()
    @State private var newName = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Who sings \(song.title)?").font(.title2.bold())
            if song.isDuet { Label("Duet: pick two singers", systemImage: "person.2.wave.2").foregroundStyle(.secondary) }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 10) {
                    ForEach(host.singers) { s in
                        Button {
                            if chosen.contains(s.id) { chosen.remove(s.id) } else { chosen.insert(s.id) }
                        } label: {
                            SingerChip(s).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                        .buttonStyle(.glass)
                        .tint(chosen.contains(s.id) ? s.color : nil)
                    }
                }
            }
            .frame(maxHeight: 220)
            HStack {
                TextField("New singer", text: $newName).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Play Next") { queue(next: true) }
                Button("Add to Queue") { queue(next: false) }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func add() {
        let name = newName
        Task {
            if let s = try? await host.addSinger(name: name, emoji: nil, padID: nil) { chosen.insert(s.id) }
            newName = ""
        }
    }

    private func queue(next: Bool) {
        Task {
            do {
                try await host.enqueue(songID: song.id, singerIDs: Array(chosen), playNext: next, by: nil)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
