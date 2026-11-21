import Foundation
import Testing
@testable import SingHost
@testable import SingCore

let sampleFolder: URL = {
    if let env = ProcessInfo.processInfo.environment["SING_SAMPLES"] { return URL(fileURLWithPath: env) }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../../SongDataExample").standardized
}()

func tempPaths() -> SingPaths {
    SingPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("sing-tests-\(UUID().uuidString)"))
}

@Suite struct DatabaseTests {
    @Test func migratesAndSearches() async throws {
        let db = try SingDatabase.inMemory()
        let store = LibraryStore(db: db, paths: tempPaths())
        try await db.writer.write { db in
            var a = SongRecord(title: "Désolé", artist: "Sexion d'Assaut", durationMs: 1000, filePath: "/a", audioHash: "a")
            try a.insert(db)
            var b = SongRecord(title: "Beat It", artist: "Michael Jackson", durationMs: 1000, filePath: "/b", audioHash: "b")
            try b.insert(db)
            var c = SongRecord(title: "Firework", artist: "Katy Perry", durationMs: 1000, year: 2010, filePath: "/c", audioHash: "c")
            try c.insert(db)
        }
        #expect(try await store.search("desole").first?.title == "Désolé")
        #expect(try await store.search("mich").first?.title == "Beat It")
        #expect(try await store.search("firewrk").first?.title == "Firework")
        #expect(try await store.search("katy", filters: SearchFilters(decade: 2010)).count == 1)
        #expect(try await store.search("katy", filters: SearchFilters(decade: 1980)).isEmpty)
        #expect(try await store.search("").count == 3)
    }

    @Test func filenameParsing() {
        #expect(AudioMetadataReader.parseFilename("04 - Firework") == (nil, "Firework"))
        let p = AudioMetadataReader.parseFilename("Katy Perry - Firework")
        #expect(p.artist == "Katy Perry" && p.title == "Firework")
    }
}

@Suite(.enabled(if: FileManager.default.fileExists(atPath: sampleFolder.path)))
struct SampleImportTests {
    @Test func importsFLACFolder() async throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let db = try SingDatabase.inMemory()
        let store = LibraryStore(db: db, paths: paths)
        let result = await store.importFiles([sampleFolder])
        #expect(result.added == LibraryStore.audioFiles(in: [sampleFolder]).count, "\(result)")
        #expect(result.failed.isEmpty)
        let songs = try await store.all()
        let firework = try #require(songs.first { $0.title == "Firework" })
        #expect(firework.artist.contains("Katy Perry"))
        #expect(firework.isrc != nil)
        #expect(firework.durationMs > 200_000)
        #expect(firework.hasArtwork)
        #expect(firework.paletteColors?.count == 4)
        #expect(FileManager.default.fileExists(atPath: paths.songCache(firework.audioHash).appendingPathComponent("embedded.lrc").path))
        let again = await store.importFiles([sampleFolder])
        #expect(again.skipped == result.added)
        for s in songs { print("IMPORTED", s.title, "|", s.artist, "|", s.isrc ?? "-", s.durationMs, s.paletteColors ?? []) }
    }
}
