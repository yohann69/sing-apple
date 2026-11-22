import Foundation
import Testing
@testable import SingHost
import SingClient
import SingCore

@MainActor
@Suite(.serialized, .enabled(if: FileManager.default.fileExists(atPath: sampleFolder.path)))
struct OwnerTests {
    @Test func pinRatingsStorageAndPads() async throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let port = Int.random(in: 50000..<51000)
        let host = try HostController(paths: paths, modelURL: paths.models.appendingPathComponent("none.mlmodelc"), port: port, advertise: false)
        host.settings.playback.micEnabled = false
        host.settings.services = { var s = host.settings.services; s.singAPIEnabled = false; s.lrclibEnabled = false; s.neteaseEnabled = false; s.kugouEnabled = false; return s }()
        await host.start()
        await host.importFiles([sampleFolder])

        let endpoint = ServerEndpoint(name: "test", host: "127.0.0.1", port: port)
        var hostPad = SingAPIClient(endpoint: endpoint)
        hostPad.token = try await hostPad.pair(code: host.hostCode, deviceName: "Host", deviceModel: "t").token
        var guest = SingAPIClient(endpoint: endpoint)
        let guestPair = try await guest.pair(code: host.guestCode, deviceName: "Guest", deviceModel: "t")
        guest.token = guestPair.token

        // No PIN: a host pad is the owner, a guest is not.
        _ = try await hostPad.ownerOverview()
        await #expect(throws: ClientError.self) { try await guest.ownerOverview() }

        host.setOwnerPIN("4321")
        await #expect(throws: ClientError.self) { try await hostPad.ownerOverview() }
        for _ in 0..<5 { _ = try? await hostPad.unlockOwner(pin: "0000") }
        do {
            _ = try await hostPad.unlockOwner(pin: "4321")
            Issue.record("unlocked while locked out")
        } catch let e as ClientError {
            #expect(e.code == "locked")
        }
        host.pinAttempts.removeAll()
        hostPad.ownerToken = try await hostPad.unlockOwner(pin: "4321").ownerToken
        let overview = try await hostPad.ownerOverview()
        #expect(overview.pinRequired)
        #expect(overview.pads.count == 2)
        #expect(overview.storage.categories.contains { $0.id == "stems" })

        let singer = try await guest.createSinger(name: "Léa", emoji: nil)
        let song = try #require(host.songs.first)
        try await guest.rate(SongRating(songID: song.id, singerID: singer.id, favorite: true))
        #expect(try await guest.ratings(singer: singer.id).first?.favorite == true)
        let favs = try await guest.search("", filters: SearchFilters(favoritesOf: singer.id))
        #expect(favs.songs.map(\.id) == [song.id])

        let dry = try await hostPad.clearCache(ClearCacheRequest(dryRun: true))
        #expect(dry.freedBytes >= 0)

        try await hostPad.unpair(padID: guestPair.padID)
        await #expect(throws: ClientError.self) { try await guest.singers() }

        host.settings.network.maxPads = 1
        await #expect(throws: ClientError.self) { try await SingAPIClient(endpoint: endpoint).pair(code: host.guestCode, deviceName: "x", deviceModel: "t") }
    }
}
