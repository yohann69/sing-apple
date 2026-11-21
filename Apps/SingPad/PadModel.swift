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
        didSet { UserDefaults.standard.set(currentSingerID, forKey: "currentSinger") }
    }
    var upNextAlert: ServerMessage.YoureUp?

    @ObservationIgnored private var live: LiveConnection?
    @ObservationIgnored private var browser: ServerBrowser?
    @ObservationIgnored private var artworkCache: [SongID: UIImage] = [:]

    var client: SingAPIClient? { saved.map { SingAPIClient(endpoint: $0.endpoint, token: $0.token) } }
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
            if var s = saved, s.role != h.role { s.role = h.role; saved = s }
        case .state(let s):
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { state = s }
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
        case .error(let e):
            toast = e.message
            if e.code == "unauthorized" { disconnect() }
        }
    }

    private func refreshLyricsIfNeeded() {
        let id = state.nowPlaying.entry?.song.id
        guard id != lyricsSongID else { return }
        lyricsSongID = id
        lyrics = nil
        guard let id, let client else { return }
        Task { lyrics = try? await client.lyrics(id) }
    }

    // MARK: Actions

    func enqueue(_ song: SongSummary, singers: [SingerID], playNext: Bool) {
        send(.enqueue(.init(songID: song.id, singerIDs: singers, playNext: playNext)))
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
        Double(state.nowPlaying.estimatedPosition()) / 1000
    }
}
