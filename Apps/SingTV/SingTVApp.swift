import Observation
import SingClient
import SingCore
import SingDesign
import SwiftUI

/// Apple TV screen for a Sing! Mac: the same stage as the Mac's TV window, fed over the network.
@main
struct SingTVApp: App {
    @State private var model = TVModel()

    var body: some Scene {
        WindowGroup {
            TVRoot()
                .environment(model)
                .environment(\.singTheme, SingTheme(id: model.state.settings.theme.preset))
                .preferredColorScheme(.dark)
        }
    }
}

struct SavedMac: Codable { var endpoint: ServerEndpoint; var token: String }

@MainActor
@Observable
final class TVModel {
    var saved: SavedMac? { didSet { UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: "mac") } }
    var discovered: [ServerEndpoint] = []
    var state = LiveState()
    var lyrics: Lyrics?
    var pitch: PitchTrack?
    var artwork: Image?
    var connected = false
    var error: String?
    /// Delay to line the words up with the sound when the Mac plays through AirPlay to this TV.
    var offset: Double = UserDefaults.standard.double(forKey: "offset") { didSet { UserDefaults.standard.set(offset, forKey: "offset") } }
    @ObservationIgnored private var live: LiveConnection?
    @ObservationIgnored private var browser: ServerBrowser?
    @ObservationIgnored private var loadedFor: SongID?

    init() {
        if let d = UserDefaults.standard.data(forKey: "mac") { saved = try? JSONDecoder().decode(SavedMac.self, from: d) }
    }

    var client: SingAPIClient? { saved.map { SingAPIClient(endpoint: $0.endpoint, token: $0.token) } }

    func browse() {
        let b = ServerBrowser { [weak self] list in Task { @MainActor in self?.discovered = list } }
        b.start()
        browser = b
    }

    func pair(_ ep: ServerEndpoint, code: String) async {
        do {
            let r = try await SingAPIClient(endpoint: ep).pair(code: code, deviceName: "Apple TV", deviceModel: "tvOS")
            var e = ep
            e.name = r.server.name
            saved = SavedMac(endpoint: e, token: r.token)
            error = nil
            connect()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func connect() {
        guard let saved, let url = client?.liveURL else { return }
        live?.stop()
        let c = LiveConnection(url: url, token: saved.token) { [weak self] m in
            Task { @MainActor in self?.receive(m) }
        } onStatus: { [weak self] s in
            Task { @MainActor in self?.connected = s == .connected }
        }
        live = c
        c.start()
    }

    func forget() {
        live?.stop()
        saved = nil
        state = LiveState()
    }

    private func receive(_ m: ServerMessage) {
        switch m {
        case .state(let s):
            withAnimation(.smooth) { state = s }
            refreshSong()
        case .position(let p):
            state.nowPlaying.positionMs = p.positionMs
            state.nowPlaying.positionAt = p.at
        case .error(let e) where e.code == "unauthorized":
            forget()
        default:
            break
        }
    }

    private func refreshSong() {
        let id = state.nowPlaying.entry?.song.id
        guard id != loadedFor else { return }
        loadedFor = id
        lyrics = nil
        pitch = nil
        artwork = nil
        guard let id, let client else { return }
        let lang = state.settings.tv.showTranslation ? state.settings.tv.translationLanguage : nil
        Task {
            lyrics = try? await client.lyrics(id, translateTo: lang)
            pitch = try? await client.displayPitch(id)
            if let d = try? await client.artwork(id), let ui = UIImage(data: d) { artwork = Image(uiImage: ui) }
        }
    }

    var time: TimeInterval { Double(state.nowPlaying.estimatedPosition()) / 1000 - offset }

    var stage: TVStageModel {
        let np = state.nowPlaying
        let code = state.joinURL.flatMap { URLComponents(string: $0)?.queryItems?.first { $0.name == "code" }?.value } ?? ""
        var m = TVStageModel(
            nowPlaying: np, lyrics: lyrics, upNext: state.queue.first, settings: state.settings.tv, artwork: artwork,
            joinURL: state.joinURL ?? "", guestCode: code, preparingProgress: np.entry.flatMap { state.preparing[$0.song.id] },
            countdownEnd: np.state == .countdown ? np.positionAt.addingTimeInterval(3) : nil,
            duration: Double(np.entry?.song.durationMs ?? 0) / 1000, queuePreview: state.queue
        )
        m.pitch = pitch
        m.result = state.result
        m.leaderboard = state.leaderboard ?? []
        m.recap = state.recap
        return m
    }
}

struct TVRoot: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        Group {
            if model.saved == nil { PairView() } else {
                TVStageView(model: model.stage) { model.time }
                    .ignoresSafeArea()
                    .overlay(alignment: .topTrailing) {
                        if !model.connected { Label("Reconnecting to the Mac…", systemImage: "wifi.exclamationmark").padding(30) }
                    }
                    .contextMenu {
                        Button("Words earlier") { model.offset -= 0.1 }
                        Button("Words later") { model.offset += 0.1 }
                        Button("Forget this Mac", role: .destructive) { model.forget() }
                    }
            }
        }
        .task { if model.saved != nil { model.connect() } }
    }
}

struct PairView: View {
    @Environment(TVModel.self) private var model
    @State private var picked: ServerEndpoint?
    @State private var code = ""

    var body: some View {
        VStack(spacing: 40) {
            Text("Sing!").font(.system(size: 120, weight: .black, design: .rounded))
            if let picked {
                Text("Enter the guest code shown on \(picked.name)").font(.title2)
                TextField("Code", text: $code).keyboardType(.numberPad).frame(width: 500)
                Button("Connect") { Task { await model.pair(picked, code: code) } }
                if let e = model.error { Text(e).foregroundStyle(.red) }
                Button("Back") { self.picked = nil }
            } else {
                Text("Choose your karaoke Mac").font(.title2)
                if model.discovered.isEmpty { ProgressView("Looking on the network…") }
                ForEach(model.discovered) { ep in
                    Button(ep.name) { picked = ep }
                }
            }
        }
        .padding(80)
        .task { model.browse() }
    }
}
