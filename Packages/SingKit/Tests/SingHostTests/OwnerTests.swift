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

@MainActor
@Suite(.serialized, .enabled(if: FileManager.default.fileExists(atPath: sampleFolder.path)))
struct ProfileTests {
    @Test func profilesWishesLocksAndLineSearch() async throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let port = Int.random(in: 51000..<52000)
        let host = try HostController(paths: paths, modelURL: paths.models.appendingPathComponent("none.mlmodelc"), port: port, advertise: false)
        host.settings.playback.micEnabled = false
        host.settings.services = { var s = host.settings.services; s.lrclibEnabled = false; s.neteaseEnabled = false; s.kugouEnabled = false; s.qqEnabled = false; return s }()
        await host.start()
        await host.importFiles([sampleFolder])
        let ep = ServerEndpoint(name: "t", host: "127.0.0.1", port: port)
        var hostPad = SingAPIClient(endpoint: ep)
        hostPad.token = try await hostPad.pair(code: host.hostCode, deviceName: "Host", deviceModel: "t").token
        var guest = SingAPIClient(endpoint: ep)
        guest.token = try await guest.pair(code: host.guestCode, deviceName: "Guest", deviceModel: "t").token

        let lea = try await guest.createSinger(name: "Léa", emoji: nil)
        var prefs = SingerPrefs()
        prefs.hideFromLeaderboard = true
        prefs.keyOffset = 2
        try await guest.updateSingerPrefs(lea.id, prefs)
        try await guest.setSingerPIN(lea.id, pin: "1234")
        var other = SingAPIClient(endpoint: ep)
        other.token = try await other.pair(code: host.guestCode, deviceName: "Other", deviceModel: "t").token
        await #expect(throws: ClientError.self) { try await other.updateSingerPrefs(lea.id, SingerPrefs()) }
        try await other.unlockSinger(lea.id, pin: "1234")
        try await other.updateSingerPrefs(lea.id, prefs)
        #expect(host.singers.first { $0.id == lea.id }?.prefs?.keyOffset == 2)
        #expect(host.singers.first { $0.id == lea.id }?.prefs?.hasPIN == true)

        let song = try #require(host.songs.first)
        try await guest.setWish(lea.id, song: song.id, on: true)
        #expect(try await guest.wishes(lea.id).map(\.id) == [song.id])

        let profiles = try await hostPad.settingsProfiles()
        #expect(profiles.contains { $0.name == "Family" })
        try await hostPad.applySettingsProfile("Family")
        #expect(host.settings.privacy.familyMode)

        host.settings.locks["tv"] = "mac"
        var s = host.settings
        s.tv.showConfetti.toggle()
        let before = host.settings.tv.showConfetti
        let live = LiveConnection(url: try #require(hostPad.liveURL), token: hostPad.token!, onMessage: { _ in }, onStatus: { _ in })
        live.start()
        try await Task.sleep(for: .milliseconds(500))
        live.send(.updateSettings(s))
        try await Task.sleep(for: .milliseconds(500))
        #expect(host.settings.tv.showConfetti == before)
        live.stop()

        let guestSinger = try await guest.createSinger(name: "Guest Léa", emoji: nil)
        try await hostPad.mergeSingers(from: guestSinger.id, into: lea.id)
        #expect(!host.singers.contains { $0.id == guestSinger.id })
        #expect(try await hostPad.auditLog().contains { $0.action.contains("merged") })

        let r = try await guest.searchLines("zzzz unlikely line qqq")
        #expect(r.songs.isEmpty)
        for candidate in host.songs.prefix(12) {
            await host.refreshLyrics(candidate.id)
            guard let rec = try await host.library.song(candidate.id), let l = host.lyricsService.cached(rec), l.lines.count > 6 else { continue }
            let line = l.lines[5].text
            guard line.split(separator: " ").count >= 4 else { continue }
            let found = try await guest.searchLines(line)
            #expect(found.songs.contains { $0.id == candidate.id }, "line search finds \(candidate.title)")
            break
        }
    }
}
