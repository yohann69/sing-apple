import ActivityKit
import AVFoundation
import Foundation
import Observation
import SingClient
import SingCore
import SwiftUI
import UIKit

struct SavedServer: Codable, Equatable {
    var endpoint: ServerEndpoint
    var token: String
    var role: PadRole
    var padID: String
}

@MainActor
@Observable
final class PadModel {
    enum Connection: Equatable { case none, connecting, connected, lost(String) }

    var saved: SavedServer? { didSet { persist() } }
    var discovered: [ServerEndpoint] = []
    var connection: Connection = .none
    var state = LiveState()
    var lyrics: Lyrics?
    var lyricsSongID: SongID?
    var toast: String?
    var currentSingerID: SingerID? {
        didSet {
            UserDefaults.standard.set(currentSingerID, forKey: "currentSinger")
            Task { await loadRatings(); await loadWishes() }
        }
    }
    /// The current singer's thumbs, favorites and never-suggest marks, by song.
    var ratings: [SongID: SongRating] = [:]
    /// Granted by the owner PIN; kept in memory only.
    var ownerToken: String?
    var meters: [Float] = []
    @ObservationIgnored private var turnActivity: Activity<TurnAttributes>?

    /// Keeps the lock-screen "you're up" activity in step with the queue.
    func updateTurnActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, let me = currentSinger else { return }
        let nowIsMe = state.nowPlaying.entry?.singers.contains { $0.id == me.id } == true && state.nowPlaying.state != .finished
        let idx = state.queue.firstIndex { $0.singers.contains { $0.id == me.id } }
        guard nowIsMe || idx != nil else {
            if turnActivity != nil {
                turnActivity = nil
                Task { for a in Activity<TurnAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) } }
            }
            return
        }
        let entry = nowIsMe ? state.nowPlaying.entry! : state.queue[idx!]
        let content = TurnAttributes.ContentState(songsAway: nowIsMe ? 0 : idx! + 1, songTitle: entry.song.title, artist: entry.song.artist,
                                                  nowPlaying: nowIsMe ? nil : state.nowPlaying.entry?.song.title)
        if turnActivity != nil {
            Task { for a in Activity<TurnAttributes>.activities { await a.update(ActivityContent(state: content, staleDate: nil)) } }
        } else {
            turnActivity = try? Activity.request(attributes: TurnAttributes(singerName: me.name, colorHex: me.colorHex), content: ActivityContent(state: content, staleDate: nil))
        }
    }
    @ObservationIgnored let phoneMic = PhoneMicSender()
    var phoneMicOn = false

    /// Uses this device as a wireless mic through the Mac's speakers.
    func togglePhoneMic() {
        if phoneMicOn {
            phoneMic.stop()
            phoneMicOn = false
            Task { try? await client?.stopPhoneMic() }
            return
        }
        Task {
            guard await AVAudioApplication.requestRecordPermission() else { toast = "Allow the microphone in Settings first"; return }
            do {
                guard let client, let host = saved?.endpoint.host else { return }
                let session = try await client.startPhoneMic()
                try phoneMic.start(host: host, session: session)
                phoneMicOn = true
                toast = "This device is now a mic. Hold it close and away from the speakers."
            } catch {
                toast = error.localizedDescription
            }
        }
    }
    var wishIDs = Set<SongID>()
    var pinFor: Singer?

    func loadWishes() async {
        guard let id = currentSingerID, let list = try? await client?.wishes(id) else { wishIDs = []; return }
        wishIDs = Set(list.map(\.id))
    }

    func toggleWish(_ song: SongID) {
        guard let singer = currentSingerID else { toast = "Pick who you are first"; return }
        let on = !wishIDs.contains(song)
        if on { wishIDs.insert(song) } else { wishIDs.remove(song) }
        Task { try? await client?.setWish(singer, song: song, on: on) }
    }

    /// Picks a profile, asking for its PIN first when it has one.
    func choose(_ s: Singer) {
        if s.prefs?.hasPIN == true, !isHost { pinFor = s } else { currentSingerID = s.id }
    }

    func unlock(_ s: Singer, pin: String) async {
        do {
            try await client?.unlockSinger(s.id, pin: pin)
            currentSingerID = s.id
            pinFor = nil
        } catch {
            toast = error.localizedDescription
        }
    }
    var upNextAlert: ServerMessage.YoureUp?
    /// This pad's own translation language for the lyrics shown on it.
    var translationLanguage: String? = UserDefaults.standard.string(forKey: "translationLanguage") {
        didSet {
            UserDefaults.standard.set(translationLanguage, forKey: "translationLanguage")
            lyricsSongID = nil
            refreshLyricsIfNeeded()
        }
    }
    var languages: [SingAPIClient.Language] = []

    func loadLanguages() async {
        if languages.isEmpty, let l = try? await client?.translationLanguages() { languages = l }
    }

    @ObservationIgnored private var live: LiveConnection?
    @ObservationIgnored private var browser: ServerBrowser?
    @ObservationIgnored private var artworkCache: [SongID: UIImage] = [:]

    var client: SingAPIClient? {
        saved.map { var c = SingAPIClient(endpoint: $0.endpoint, token: $0.token); c.ownerToken = ownerToken; return c }
    }

    func loadRatings() async {
        guard let id = currentSingerID, let list = try? await client?.ratings(singer: id) else { ratings = [:]; return }
        ratings = Dictionary(uniqueKeysWithValues: list.map { ($0.songID, $0) })
    }

    func isFavorite(_ id: SongID) -> Bool { ratings[id]?.favorite ?? false }

    func rate(_ song: SongID, _ change: (inout SongRating) -> Void) {
        guard let singer = currentSingerID else { toast = "Pick who you are first"; return }
        var r = ratings[song] ?? SongRating(songID: song, singerID: singer)
        change(&r)
        ratings[song] = r
        Task { try? await client?.rate(r) }
    }

    func unlockOwner(pin: String) async throws {
        guard let client else { throw ClientError("Not connected") }
        ownerToken = try await client.unlockOwner(pin: pin).ownerToken
    }
    var isHost: Bool { saved?.role == .host }
    var currentSinger: Singer? { state.singers.first { $0.id == currentSingerID } }

    init() {
        if let data = UserDefaults.standard.data(forKey: "savedServer") {
            saved = try? JSONDecoder().decode(SavedServer.self, from: data)
        }
        let s = UserDefaults.standard.object(forKey: "currentSinger") as? Int64
        currentSingerID = s
        if ProcessInfo.processInfo.environment["SING_RESET"] != nil { saved = nil }
    }

    private func persist() {
        if let saved, let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: "savedServer")
        } else {
            UserDefaults.standard.removeObject(forKey: "savedServer")
        }
    }

    // MARK: Discovery and pairing

    func startBrowsing() {
        guard browser == nil else { return }
        let b = ServerBrowser { [weak self] list in
            Task { @MainActor in self?.discovered = list }
        }
        b.start()
        browser = b
    }

    func stopBrowsing() {
        browser?.stop()
        browser = nil
    }

    func pair(_ endpoint: ServerEndpoint, code: String) async throws {
        let c = SingAPIClient(endpoint: endpoint)
        let device = UIDevice.current
        let resp = try await c.pair(code: code.trimmingCharacters(in: .whitespaces), deviceName: device.name, deviceModel: device.model)
        var ep = endpoint
        ep.name = resp.server.name
        saved = SavedServer(endpoint: ep, token: resp.token, role: resp.role, padID: resp.padID)
        connect()
    }

    func handleJoinURL(_ url: URL) {
        guard let (ep, code) = ServerEndpoint.parse(joinURL: url) else { return }
        Task {
            do { try await pair(ep, code: code) } catch { toast = error.localizedDescription }
        }
    }

    func disconnect() {
        live?.stop()
        live = nil
        saved = nil
        connection = .none
        state = LiveState()
    }

    // MARK: Live

    func connect() {
        guard let saved, let url = client?.liveURL else { return }
        Task { await loadRatings() }
        live?.stop()
        connection = .connecting
        let conn = LiveConnection(url: url, token: saved.token) { [weak self] msg in
            Task { @MainActor in self?.receive(msg) }
        } onStatus: { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .connecting: if self.connection != .connected { self.connection = .connecting }
                case .connected: self.connection = .connected
                case .disconnected(let reason): self.connection = .lost(reason ?? "Connection lost")
                }
            }
        }
        live = conn
        conn.start()
    }

    func send(_ m: ClientMessage) { live?.send(m) }

    private func receive(_ msg: ServerMessage) {
        switch msg {
        case .hello(let h):
            connection = .connected
            afterConnect()
            if var s = saved, s.role != h.role { s.role = h.role; saved = s }
        case .state(let s):
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { state = s }
            updateTurnActivity()
            refreshLyricsIfNeeded()
        case .position(let p):
            state.nowPlaying.positionMs = p.positionMs
            state.nowPlaying.positionAt = p.at
        case .progress(let p):
            state.preparingByID[String(p.songID)] = p.readiness == .ready ? nil : p.progress
            for i in state.queue.indices where state.queue[i].song.id == p.songID {
                state.queue[i].song.readiness = p.readiness
            }
        case .youreUp(let u):
            if u.singerID == currentSingerID, u.songsAway <= 2 { upNextAlert = u }
        case .toast(let t):
            toast = t.message
        case .meter(let m):
            meters = m.levels
        case .error(let e):
            toast = e.message
            if e.code == "unauthorized" { disconnect() }
        }
    }

    func refreshLyricsIfNeeded() {
        let id = state.nowPlaying.entry?.song.id
        guard id != lyricsSongID else { return }
        lyricsSongID = id
        lyrics = nil
        guard let id, let client else { return }
        let lang = translationLanguage
        Task { lyrics = try? await client.lyrics(id, translateTo: lang) }
    }

    // MARK: Actions

    func enqueue(_ song: SongSummary, singers: [SingerID], playNext: Bool, battle: Bool = false) {
        send(.enqueue(.init(songID: song.id, singerIDs: singers, playNext: playNext, battle: battle && singers.count >= 2 ? true : nil)))
        toast = playNext ? "\(song.title) plays next" : "\(song.title) added to the queue"
    }

    func createSinger(name: String, emoji: String?) async throws -> Singer {
        guard let client else { throw ClientError("Not connected") }
        let s = try await client.createSinger(name: name, emoji: emoji)
        if !state.singers.contains(s) { state.singers.append(s) }
        return s
    }

    func updateSettings(_ change: (inout SingSettings) -> Void) {
        var s = state.settings
        change(&s)
        state.settings = s
        send(.updateSettings(s))
    }

    func artwork(_ id: SongID) async -> UIImage? {
        if let i = artworkCache[id] { return i }
        guard let client, let data = try? await client.artwork(id), let img = UIImage(data: data) else { return nil }
        artworkCache[id] = img
        return img
    }

    var position: TimeInterval {
        Double(state.nowPlaying.estimatedPosition(at: Date.now.addingTimeInterval(clockOffset))) / 1000
    }

    /// How far the Mac's clock is ahead of this device's, measured on each connection.
    var clockOffset: TimeInterval = 0
    var updateAvailable: String?
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    /// Clock sync, update check and a battery report every minute while connected.
    func afterConnect() {
        guard let client else { return }
        Task {
            let t0 = Date.now
            if let info = try? await client.info(), let server = info.time {
                let t1 = Date.now
                clockOffset = server.timeIntervalSince(t0.addingTimeInterval(t1.timeIntervalSince(t0) / 2))
                let mine = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                if info.appVersion.compare(mine, options: .numeric) == .orderedDescending {
                    updateAvailable = "The Mac runs Sing! \(info.appVersion). Update this app to get the newest features."
                }
            }
        }
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            UIDevice.current.isBatteryMonitoringEnabled = true
            while !Task.isCancelled {
                let level = UIDevice.current.batteryLevel
                self?.send(.deviceStatus(battery: level >= 0 ? Double(level) : nil))
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}
