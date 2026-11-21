import Foundation
import Testing
@testable import SingHost
import SingClient
import SingCore

final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ServerMessage] = []
    func add(_ m: ServerMessage) { lock.withLock { items.append(m) } }
    var all: [ServerMessage] { lock.withLock { items } }
    var lastState: LiveState? {
        all.reversed().compactMap { if case .state(let s) = $0 { s } else { nil } }.first
    }
}

@MainActor
@Suite(.serialized, .enabled(if: FileManager.default.fileExists(atPath: sampleFolder.path)))
struct EndToEndTests {
    @Test func padFlowAgainstRealHost() async throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let port = Int.random(in: 48000..<49000)
        let host = try HostController(paths: paths, modelURL: paths.models.appendingPathComponent("none.mlmodelc"), port: port, advertise: false)
        host.settings.playback.countdownBetweenSongs = false
        host.settings.playback.micEnabled = false
        host.settings.services.singAPIEnabled = false
        host.settings.services.lrclibEnabled = false
        await host.start()
        await host.importFiles([sampleFolder])
        #expect(host.songs.count == 6)
        try await Task.sleep(for: .milliseconds(300))

        let endpoint = ServerEndpoint(name: "test", host: "127.0.0.1", port: port)
        var client = SingAPIClient(endpoint: endpoint)
        let info = try await client.info()
        #expect(info.protocolVersion == SingProtocol.version)
        await #expect(throws: ClientError.self) { try await client.pair(code: "000000x", deviceName: "iPad", deviceModel: "test") }
        let paired = try await client.pair(code: host.hostCode, deviceName: "Test iPad", deviceModel: "test")
        #expect(paired.role == .host)
        client.token = paired.token

        let results = try await client.search("firewrk")
        let firework = try #require(results.songs.first)
        #expect(firework.title == "Firework")
        let singer = try await client.createSinger(name: "Léa", emoji: "🎤")
        #expect(singer.name == "Léa")

        let inbox = Inbox()
        let live = LiveConnection(url: try #require(client.liveURL), onMessage: { inbox.add($0) }, onStatus: { _ in })
        live.start()
        try await Task.sleep(for: .milliseconds(500))
        #expect(inbox.all.contains { if case .hello = $0 { true } else { false } })

        live.send(.enqueue(.init(songID: firework.id, singerIDs: [singer.id])))
        try await Task.sleep(for: .seconds(2))
        let state = try await client.state()
        #expect(state.nowPlaying.entry?.song.title == "Firework")
        #expect(state.nowPlaying.state == .playing)
        #expect(state.nowPlaying.entry?.singers.first?.name == "Léa")
        let lyrics = try await client.lyrics(firework.id)
        #expect(lyrics.kind == .line)
        #expect(lyrics.lines.count > 20)
        #expect(inbox.lastState?.nowPlaying.entry?.song.id == firework.id)

        let beatIt = try #require(try await client.search("beat it").songs.first)
        live.send(.enqueue(.init(songID: beatIt.id, singerIDs: [singer.id])))
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await client.state().queue.first?.song.title == "Beat It")

        live.send(.transport(.skip))
        try await Task.sleep(for: .seconds(1.5))
        #expect(try await client.state().nowPlaying.entry?.song.title == "Beat It")

        let stats = try await client.stats(.tonight)
        #expect(stats.totalPlays >= 1)
        #expect(stats.topSingers.first?.name == "Léa")
        let suggestions = try await client.suggestions(singer: singer.id)
        #expect(!suggestions.isEmpty)
        host.stopPlayback()
        live.stop()
    }
}
