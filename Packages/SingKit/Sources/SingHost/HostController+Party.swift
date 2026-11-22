#if os(macOS)
import Foundation
import GRDB
import SingCore

/// Between-song leaderboard, party recap, duet part scores, difficulty and queue auto-fill.
extension HostController {
    var scoreTolerance: Float {
        switch settings.playback.difficulty {
        case "easy": 1.6
        case "hard": 0.6
        default: 1.0
        }
    }

    func refreshLeaderboard() async {
        tonightBoard = (try? await leaderboard()) ?? []
        scheduleBroadcast()
    }

    /// Splits a duet by the lyrics' singer parts: the first singer takes the first voice, and so on.
    func duetScores(_ entry: QueueEntry) -> [RankedName]? {
        guard entry.singers.count >= 2, let l = lyrics, l.isDuet else { return nil }
        let voices = l.agents.filter { !$0.isGroup }.map(\.id)
        guard voices.count >= 2 else { return nil }
        var out: [RankedName] = []
        for (i, singer) in entry.singers.prefix(voices.count).enumerated() {
            let voice = voices[i]
            let ranges = l.lines.filter { $0.agent == voice || ($0.agent.map { a in l.agents.first { $0.id == a }?.isGroup ?? false } ?? false) }.map { ($0.start, $0.end) }
            let r = scoreKeeper.result(track: pitchTrack, upTo: playback.duration, tolerance: scoreTolerance) { t in ranges.contains { t >= $0.0 - 0.2 && t <= $0.1 + 0.2 } }
            if let r { out.append(RankedName(name: singer.name, count: r.total, colorHex: singer.colorHex)) }
        }
        return out.isEmpty ? nil : out
    }

    public func partyRecap(sessionID: Int64) async -> PartyRecap? {
        let singers = self.singers
        return try? await database.writer.read { db -> PartyRecap? in
            guard let s = try SessionRecord.fetchOne(db, key: sessionID) else { return nil }
            let plays = try Row.fetchAll(db, sql: """
                SELECT p.id, p.score, p.startedAt, p.endedAt, s.title, s.artist, s.durationMs, p.percentCompleted FROM play p
                LEFT JOIN song s ON s.id = p.songId WHERE p.sessionId = ? AND p.skipped = 0
                """, arguments: [sessionID])
            guard !plays.isEmpty else { return nil }
            let minutes = plays.reduce(0.0) { $0 + Double(($1["durationMs"] as Int?) ?? 0) / 60000 * (($1["percentCompleted"] as Double?) ?? 1) }
            let bySinger = try Row.fetchAll(db, sql: """
                SELECT ps.singerId sid, COUNT(*) n, MAX(p.score) best FROM play p JOIN playSinger ps ON ps.playId = p.id
                WHERE p.sessionId = ? AND p.skipped = 0 GROUP BY ps.singerId ORDER BY n DESC
                """, arguments: [sessionID])
            func singer(_ id: Int64?) -> Singer? { singers.first { $0.id == id } }
            let top = bySinger.first.flatMap { r in singer(r["sid"]).map { RankedName(name: $0.name, count: r["n"], colorHex: $0.colorHex) } }
            let bestRow = try Row.fetchOne(db, sql: """
                SELECT ps.singerId sid, p.score, s.title FROM play p JOIN playSinger ps ON ps.playId = p.id LEFT JOIN song s ON s.id = p.songId
                WHERE p.sessionId = ? AND p.score IS NOT NULL ORDER BY p.score DESC LIMIT 1
                """, arguments: [sessionID])
            let best = bestRow.flatMap { r in singer(r["sid"]).map { RankedName(name: $0.name, count: Int((r["score"] as Double?) ?? 0), colorHex: $0.colorHex) } }
            var artists: [String: Int] = [:]
            for p in plays { if let a: String = p["artist"] { artists[a, default: 0] += 1 } }
            let topArtist = artists.max { $0.value < $1.value }?.key
            var highlights: [String] = []
            if let top { highlights.append("\(top.name) sang \(top.count) song\(top.count == 1 ? "" : "s")") }
            if let best, let t: String = bestRow?["title"] { highlights.append("Best score: \(best.count) by \(best.name) on \(t)") }
            if let topArtist, (artists[topArtist] ?? 0) > 1 { highlights.append("\(topArtist) came up \(artists[topArtist]!) times") }
            let duets = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM (SELECT playId FROM playSinger ps JOIN play p ON p.id = ps.playId WHERE p.sessionId = ? GROUP BY playId HAVING COUNT(*) > 1)", arguments: [sessionID]) ?? 0
            if duets > 0 { highlights.append("\(duets) duet\(duets == 1 ? "" : "s")") }
            return PartyRecap(
                name: s.name, startedAt: s.startedAt, endedAt: s.endedAt ?? .now, songs: plays.count, minutes: Int(minutes.rounded()),
                singers: bySinger.count, topSinger: top, bestScore: best, bestSong: bestRow?["title"], topArtist: topArtist, highlights: highlights
            )
        }.flatMap { $0 }
    }

    public func latestRecap() async -> PartyRecap? {
        if let id = session?.id { return await partyRecap(sessionID: id) }
        let last = try? await database.writer.read { try Int64.fetchOne($0, sql: "SELECT id FROM session ORDER BY startedAt DESC LIMIT 1") }
        guard let id = last ?? nil else { return nil }
        return await partyRecap(sessionID: id)
    }

    /// With auto-fill on, an empty queue after a song gets a ready crowd favourite nobody has sung tonight.
    func autoFillIfNeeded() async -> Bool {
        guard settings.queue.autoFill, queue.entries.isEmpty, session != nil else { return false }
        let sid = session?.id
        let tonight = Set((try? await database.writer.read { db in
            try Int64.fetchAll(db, sql: "SELECT songId FROM play WHERE sessionId = ? AND songId IS NOT NULL", arguments: [sid])
        }) ?? [])
        let picks = ((try? await stats.suggestions(for: nil)) ?? []).map(\.song).filter { s in
            !tonight.contains(s.id) && songs.first { $0.id == s.id }?.readiness == .ready && !familyHidden(s)
        }
        guard let pick = picks.randomElement() ?? songs.filter({ $0.readiness == .ready && !tonight.contains($0.id) && !familyHidden($0) }).randomElement() else { return false }
        guard let record = try? await library.song(pick.id) else { return false }
        try? queue.add(QueueEntry(song: summary(record), singers: [], addedBy: "auto"))
        await server?.broadcast(.toast(.init(message: "Open mic: \(pick.title). Grab the mic!")))
        return true
    }
}
#endif

#if os(macOS)
extension HostController {
    /// Battle: singers alternate line by line (or take their duet part), each scored on their own lines.
    func battleScores(_ entry: QueueEntry) -> [RankedName]? {
        if let duet = duetScores(entry) { return duet }
        guard let l = lyrics, entry.singers.count >= 2 else { return nil }
        let n = entry.singers.count
        var out: [RankedName] = []
        for (i, singer) in entry.singers.enumerated() {
            let ranges = l.lines.enumerated().filter { $0.offset % n == i }.map { ($0.element.start, $0.element.end) }
            if let r = scoreKeeper.result(track: pitchTrack, upTo: playback.duration, tolerance: scoreTolerance, during: { t in ranges.contains { t >= $0.0 - 0.2 && t <= $0.1 + 0.2 } }) {
                out.append(RankedName(name: singer.name, count: r.total, colorHex: singer.colorHex))
            }
        }
        return out.isEmpty ? nil : out
    }

    public func setLoop(start: Int?, end: Int?) {
        guard let s = start, let e = end, e > s + 1000 else {
            nowPlaying.loopStartMs = nil
            nowPlaying.loopEndMs = nil
            scheduleBroadcast()
            return
        }
        nowPlaying.loopStartMs = max(0, s)
        nowPlaying.loopEndMs = e
        usedLoop = true
        if take != nil { discardTake() }
        scheduleBroadcast()
    }

    func checkLoop() {
        guard let s = nowPlaying.loopStartMs, let e = nowPlaying.loopEndMs else { return }
        if playback.position * 1000 >= Double(e) {
            seek(to: Double(s) / 1000)
        }
    }

    /// Listens to the room for five seconds after the song and turns the cheering into a 0 to 100 score.
    func measureApplause(entryID: String) {
        guard settings.tv.showApplause, mic.isRunning else { return }
        Task {
            var levels: [Float] = []
            for _ in 0..<100 {
                try? await Task.sleep(for: .milliseconds(50))
                levels.append(mic.level)
            }
            let top = levels.sorted(by: >).prefix(20)
            let avg = top.reduce(0, +) / Float(max(1, top.count))
            let score = Int(max(0, min(100, (avg - 0.02) / 0.5 * 100)).rounded())
            guard lastResult?.entryID == entryID else { return }
            lastResult?.applause = score
            scheduleBroadcast()
        }
    }
}
#endif

#if os(macOS)
extension HostController {
    /// Matches a hummed recording against every song whose melody has been analysed.
    public func humSearch(_ audio: Data) async throws -> [SongSummary] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hum-\(UUID().uuidString).m4a")
        try audio.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let records = (try? await library.all()) ?? []
        let paths = self.paths
        let ranked = try await Task.detached(priority: .userInitiated) { () -> [(SongID, Float)] in
            let hum = try MelodyExtractor.extract(vocals: tmp)
            let tracks: [(SongID, PitchTrack)] = records.compactMap { r in
                guard let id = r.id, let d = try? Data(contentsOf: paths.pitch(r.audioHash)), let t = try? JSONDecoder().decode(PitchTrack.self, from: d) else { return nil }
                return (id, t)
            }
            return HumSearch.rank(hum: hum, songs: tracks)
        }.value
        return ranked.filter { $0.1 < 2.2 }.compactMap { r in songs.first { $0.id == r.0 } }
    }
}
#endif
