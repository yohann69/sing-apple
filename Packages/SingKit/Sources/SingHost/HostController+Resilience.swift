#if os(macOS)
import AVFoundation
import Foundation
import GRDB
import SingCore

/// Upkeep and recovery: integrity checks, relinking, metadata, crash recovery, logs, maintenance and device changes.
extension HostController {

    // MARK: Integrity

    /// Re-checks every Ready song's stems and lyrics; broken ones go back to processing.
    @discardableResult
    public func integrityCheck() async -> Int {
        let records = (try? await library.all()) ?? []
        let paths = self.paths
        let broken: [SongID] = await Task.detached(priority: .utility) {
            records.compactMap { r -> SongID? in
                guard r.readiness == .ready, let id = r.id else { return nil }
                for url in [paths.vocals(r.audioHash), paths.instrumental(r.audioHash)] {
                    guard let f = try? AVAudioFile(forReading: url), f.length > 1000 else { return id }
                }
                if let d = try? Data(contentsOf: paths.lyrics(r.audioHash)), (try? JSONDecoder().decode(Lyrics.self, from: d)) == nil {
                    try? FileManager.default.removeItem(at: paths.lyrics(r.audioHash))
                    return id
                }
                return nil
            }
        }.value
        for id in broken { try? await library.update(id) { $0.readiness = .new } }
        if !broken.isEmpty {
            await reloadLibrary()
            await separation.enqueueBackground(broken)
            audit("Mac", "found \(broken.count) damaged song cache(s) and is rebuilding them")
        }
        _ = try? await database.writer.read { try String.fetchAll($0, sql: "PRAGMA quick_check") }
        return broken.count
    }

    /// Finds moved music: any file in the folder with the same audio as a missing song takes its place.
    public func relink(folder: URL) async -> Int {
        let before = songs.filter { $0.readiness == .missingFile }.count
        await importFiles([folder])
        await reloadLibrary()
        return max(0, before - songs.filter { $0.readiness == .missingFile }.count)
    }

    func checkMissingFiles() async {
        let records = (try? await library.all()) ?? []
        for r in records {
            guard let id = r.id else { continue }
            let exists = FileManager.default.fileExists(atPath: r.filePath)
            if exists == r.missing { try? await library.update(id) { $0.missing = !exists } }
        }
        await reloadLibrary()
    }

    // MARK: Maintenance window

    /// Once a night at the chosen hour: process the library, check caches, clean up, vacuum and back up.
    func maintenanceIfDue() async {
        guard let hour = settings.system.maintenanceHour, Calendar.current.component(.hour, from: .now) == hour,
              nowPlaying.state == .idle || nowPlaying.state == .finished, session == nil else { return }
        let today = Calendar.current.startOfDay(for: .now)
        if let last = UserDefaults.standard.object(forKey: "lastMaintenance") as? Date, last >= today { return }
        UserDefaults.standard.set(Date.now, forKey: "lastMaintenance")
        inMaintenance = true
        defer { inMaintenance = false }
        await checkMissingFiles()
        await integrityCheck()
        await enforceStorageLimits()
        try? await database.writer.vacuum()
        dailyBackup()
        await enrichMetadata(limit: 200)
        let pending = songs.filter { $0.readiness != .ready && $0.readiness != .missingFile && !evicted.contains($0.id) }.map(\.id)
        await separation.enqueueBackground(pending)
        audit("Mac", "ran the nightly upkeep")
    }

    // MARK: MusicBrainz

    struct MBSearch: Decodable {
        struct Rec: Decodable {
            struct Rel: Decodable { var id: String; var date: String? }
            struct Tag: Decodable { var name: String; var count: Int? }
            var id: String
            var score: Int?
            var isrcs: [String]?
            var releases: [Rel]?
            var tags: [Tag]?
            var firstReleaseDate: String?
            enum CodingKeys: String, CodingKey { case id, score, isrcs, releases, tags; case firstReleaseDate = "first-release-date" }
        }
        var recordings: [Rec]
    }

    /// Fills missing year, genre, ISRC and artwork from MusicBrainz and the Cover Art Archive, one request a second.
    public func enrichMetadata(limit: Int = 50) async {
        guard settings.system.musicBrainz else { return }
        let todo = ((try? await library.all()) ?? []).filter { $0.year == nil || $0.genre == nil || !$0.hasArtwork }.prefix(limit)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config)
        for r in todo {
            guard let id = r.id else { continue }
            var c = URLComponents(string: "https://musicbrainz.org/ws/2/recording")!
            c.queryItems = [URLQueryItem(name: "query", value: "recording:\"\(r.title)\" AND artist:\"\(r.artist)\""), URLQueryItem(name: "fmt", value: "json"), URLQueryItem(name: "limit", value: "3")]
            var req = URLRequest(url: c.url!)
            req.setValue("Sing/0.2 (https://github.com/yohann69/sing-apple)", forHTTPHeaderField: "User-Agent")
            try? await Task.sleep(for: .seconds(1.1))
            guard let (d, _) = try? await session.data(for: req), let found = try? JSONDecoder().decode(MBSearch.self, from: d),
                  let best = found.recordings.first(where: { ($0.score ?? 0) >= 90 }) else { continue }
            let year = best.firstReleaseDate.flatMap { Int($0.prefix(4)) }
            let genre = best.tags?.max { ($0.count ?? 0) < ($1.count ?? 0) }?.name.capitalized
            var art: Data?
            if !r.hasArtwork, let rel = best.releases?.first?.id, let url = URL(string: "https://coverartarchive.org/release/\(rel)/front-500") {
                let fetched: (Data, URLResponse)? = try? await session.data(from: url)
                let ok = (fetched?.1 as? HTTPURLResponse)?.statusCode == 200
                if ok, let a = fetched?.0, a.count > 1000 {
                    art = a
                    try? a.write(to: paths.artwork(r.audioHash))
                }
            }
            let palette = art.flatMap { PaletteExtractor.palette(from: $0) }.flatMap { try? String(decoding: JSONEncoder().encode($0), as: UTF8.self) }
            let gotArt = art != nil
            try? await library.update(id) { s in
                if s.year == nil { s.year = year }
                if s.genre == nil { s.genre = genre }
                if s.isrc == nil { s.isrc = best.isrcs?.first }
                if gotArt { s.hasArtwork = true; s.palette = palette ?? s.palette }
            }
        }
        await reloadLibrary()
    }

    // MARK: Duplicates

    /// Songs that sound the same though their files differ (another rip, another format).
    public func findDuplicates() async -> [[SongSummary]] {
        let records = (try? await library.all()) ?? []
        let paths = self.paths
        let prints: [(SongID, [UInt32])] = await Task.detached(priority: .utility) {
            records.compactMap { r in
                guard let id = r.id else { return nil }
                let cache = paths.songCache(r.audioHash).appendingPathComponent("fingerprint.bin")
                if let d = try? Data(contentsOf: cache) { return (id, d.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }) }
                guard let fp = try? AudioFingerprint.compute(URL(fileURLWithPath: r.filePath)) else { return nil }
                try? fp.withUnsafeBytes { Data($0) }.write(to: cache)
                return (id, fp)
            }
        }.value
        var groups: [[SongID]] = []
        var used = Set<SongID>()
        for (i, a) in prints.enumerated() where !used.contains(a.0) {
            var g = [a.0]
            for b in prints[(i + 1)...] where !used.contains(b.0) && AudioFingerprint.similarity(a.1, b.1) > 0.8 {
                g.append(b.0)
                used.insert(b.0)
            }
            if g.count > 1 { groups.append(g); used.insert(a.0) }
        }
        return groups.map { $0.compactMap { id in songs.first { $0.id == id } } }
    }

    // MARK: Crash recovery

    /// Remembers what is playing so a relaunch after a crash picks the song up where it was.
    func saveResumePoint() {
        guard nowPlaying.state == .playing, let e = nowPlaying.entry else { return }
        UserDefaults.standard.set(["song": e.song.id, "position": playback.position, "singers": e.singers.map(\.id)] as [String: Any], forKey: "resumePoint")
    }

    public func clearResumePoint() { UserDefaults.standard.removeObject(forKey: "resumePoint") }

    func restoreResumePoint() async {
        guard let r = UserDefaults.standard.dictionary(forKey: "resumePoint"), let song = r["song"] as? Int64,
              let pos = r["position"] as? Double, pos > 5 else { return }
        clearResumePoint()
        let singerIDs = (r["singers"] as? [Int64]) ?? []
        resumeAt = (song, pos)
        try? await enqueue(songID: song, singerIDs: singerIDs, playNext: true, by: "resume")
    }

    // MARK: Bad lyrics

    /// A pad says the words are wrong: keep the bad version aside and look again, with AI timing if needed.
    public func reportBadLyrics(_ id: SongID, by who: String) async {
        guard let r = try? await library.song(id) else { return }
        let url = paths.lyrics(r.audioHash)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent("lyrics-reported.json"))
        try? FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent("lyrics-reported.json"))
        try? FileManager.default.removeItem(at: paths.songCache(r.audioHash).appendingPathComponent("align-failed"))
        audit(who, "reported bad lyrics for \(r.title)")
        await refreshLyrics(id, force: true)
        await server?.broadcast(.toast(.init(message: "Looking for better lyrics for \(r.title)")))
    }

    // MARK: Logs

    public static var logsFolder: URL { FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Sing", isDirectory: true) }

    /// Writes uncaught exceptions to ~/Library/Logs/Sing; nothing leaves the Mac.
    public static func installCrashLogging() {
        try? FileManager.default.createDirectory(at: logsFolder, withIntermediateDirectories: true)
        NSSetUncaughtExceptionHandler { e in
            let text = "\(Date.now)\n\(e.name.rawValue): \(e.reason ?? "")\n\(e.callStackSymbols.joined(separator: "\n"))\n"
            try? text.write(to: HostController.logsFolder.appendingPathComponent("crash-\(Int(Date.now.timeIntervalSince1970)).log"), atomically: true, encoding: .utf8)
        }
    }

    func logError(_ message: String) {
        let line = "\(Date.now.ISO8601Format()) \(message)\n"
        let url = Self.logsFolder.appendingPathComponent("errors.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? FileManager.default.createDirectory(at: Self.logsFolder, withIntermediateDirectories: true)
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Thermal

    var thermalHold: Bool {
        let s = ProcessInfo.processInfo.thermalState
        return s == .serious || s == .critical
    }

    // MARK: Pads status

    func recordStatus(_ pad: PadIdentity, battery: Double?) {
        padBattery[pad.padID] = battery
        padLastActive[pad.padID] = .now
    }
}

/// A compact acoustic fingerprint: band-energy changes over time, robust to format and volume.
enum AudioFingerprint {
    static func compute(_ url: URL) throws -> [UInt32] {
        let audio = try StereoAudio.load(url, sampleRate: 11025)
        let mono = zip(audio.left, audio.right).map { ($0 + $1) / 2 }
        let frame = 2048, hop = 1024, bands = 33
        let maxFrames = min((mono.count - frame) / hop, 11025 * 90 / hop)
        guard maxFrames > 4 else { return [] }
        var energies: [[Float]] = []
        for f in 0..<maxFrames {
            let start = f * hop
            var e = [Float](repeating: 0, count: bands)
            let size = frame / bands
            for b in 0..<bands {
                var s: Float = 0
                for i in 0..<size { let x = mono[start + b * size + i]; s += x * x }
                e[b] = s
            }
            energies.append(e)
        }
        var out: [UInt32] = []
        for f in 1..<energies.count {
            var bits: UInt32 = 0
            for b in 0..<32 {
                let d = (energies[f][b] - energies[f][b + 1]) - (energies[f - 1][b] - energies[f - 1][b + 1])
                if d > 0 { bits |= 1 << UInt32(b) }
            }
            out.append(bits)
        }
        return out
    }

    /// Best match over small time shifts, as the share of equal bits.
    static func similarity(_ a: [UInt32], _ b: [UInt32]) -> Double {
        guard a.count > 20, b.count > 20 else { return 0 }
        var best = 0.0
        for shift in -8...8 {
            var same = 0, total = 0
            for i in 0..<min(a.count, b.count) {
                let j = i + shift
                guard j >= 0, j < b.count else { continue }
                same += 32 - (a[i] ^ b[j]).nonzeroBitCount
                total += 32
            }
            if total > 0 { best = max(best, Double(same) / Double(total)) }
        }
        return best
    }
}
#endif
