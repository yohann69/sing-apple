#if os(macOS)
import Foundation
import GRDB
import SingCore

/// A performance being recorded: the music as heard and the voice with its effects, in two files.
struct RecordingTake {
    var dir: URL
    var entryID: String
    var startedAt: Date
}

extension HostController {
    func startTake(_ entry: QueueEntry) {
        discardTake()
        guard settings.playback.recordPerformances, mic.isRunning else { return }
        let dir = paths.recordings.appendingPathComponent(".take-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        playback.startRecording(to: dir.appendingPathComponent("music.caf"))
        mic.startRecording(to: dir.appendingPathComponent("voice.caf"))
        take = RecordingTake(dir: dir, entryID: entry.id, startedAt: .now)
    }

    func discardTake() {
        guard let t = take else { return }
        playback.stopRecording()
        mic.stopRecording()
        try? FileManager.default.removeItem(at: t.dir)
        take = nil
    }

    /// Stops the take and mixes it into one AAC file in the background, then attaches it to the result.
    func finishTake(playID: Int64?, score: Int?) {
        guard let t = take else { return }
        take = nil
        playback.stopRecording()
        mic.stopRecording()
        guard let playID, Date.now.timeIntervalSince(t.startedAt) > 20 else {
            try? FileManager.default.removeItem(at: t.dir)
            return
        }
        let delay = playback.outputLatency + mic.inputLatency
        let out = paths.recordings.appendingPathComponent("\(UUID().uuidString).m4a")
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
        Task {
            let duration = await Task.detached(priority: .utility) { () -> TimeInterval? in
                defer { try? FileManager.default.removeItem(at: t.dir) }
                return try? RecordingMixer.mix(music: t.dir.appendingPathComponent("music.caf"), voice: t.dir.appendingPathComponent("voice.caf"), to: out, voiceDelay: delay)
            }.value
            guard let duration else { return }
            let rec = RecordingRecord(playId: playID, mixPath: out.path, createdAt: .now, durationMs: Int(duration * 1000), shareToken: String(token))
            let newID = try? await database.writer.write { db -> Int64? in var r = rec; try r.insert(db); return r.id }
            if self.lastResult?.entryID == t.entryID, let id = newID ?? nil {
                self.lastResult?.recordingID = id
                self.lastResult?.shareURL = self.shareURL(String(token))
                self.scheduleBroadcast()
            }
        }
    }

    public func shareURL(_ token: String) -> String {
        "http://\(Self.localIPv4() ?? "localhost"):\(port)/r/\(token)"
    }

    public func recordings(singerID: SingerID?) async -> [RecordingInfo] {
        struct Item: Sendable { var info: RecordingInfo; var singerIDs: [SingerID] }
        let items: [Item] = (try? await database.writer.read { db in
            var byPlay: [Int64: [SingerID]] = [:]
            for l in try Row.fetchAll(db, sql: "SELECT playId, singerId FROM playSinger") { byPlay[l["playId"], default: []].append(l["singerId"]) }
            return try Row.fetchAll(db, sql: """
                SELECT r.id, r.createdAt, r.durationMs, r.kept, r.shareToken, p.id AS playId, p.score, s.id AS songId, s.title, s.artist
                FROM recording r JOIN play p ON p.id = r.playId LEFT JOIN song s ON s.id = p.songId
                WHERE r.mixPath IS NOT NULL AND (? IS NULL OR p.id IN (SELECT playId FROM playSinger WHERE singerId = ?))
                ORDER BY r.createdAt DESC LIMIT 200
                """, arguments: [singerID, singerID]).map { r in
                Item(info: RecordingInfo(
                    id: r["id"], songID: r["songId"], songTitle: r["title"] ?? "Unknown song", artist: r["artist"] ?? "",
                    singers: [], recordedAt: r["createdAt"] ?? .now, durationMs: r["durationMs"],
                    score: (r["score"] as Double?).map { Int($0) }, kept: r["kept"], shareToken: r["shareToken"] ?? ""
                ), singerIDs: byPlay[r["playId"]] ?? [])
            }
        }) ?? []
        return items.map { item in
            var info = item.info
            info.singers = singers.filter { item.singerIDs.contains($0.id) }
            return info
        }
    }

    func recordingFile(id: Int64? = nil, token: String? = nil) async -> URL? {
        let rec = try? await database.writer.read { db -> RecordingRecord? in
            if let id { return try RecordingRecord.fetchOne(db, key: id) }
            return try RecordingRecord.filter(Column("shareToken") == token).fetchOne(db)
        }
        return rec?.mixPath.map { URL(fileURLWithPath: $0) }
    }

    public func recordingAudio(id: Int64) async -> Data? {
        guard let url = await recordingFile(id: id) else { return nil }
        return try? Data(contentsOf: url)
    }

    public func sharedRecording(token: String) async -> (info: RecordingInfo, audio: URL)? {
        guard token.count >= 12, let url = await recordingFile(token: token) else { return nil }
        guard let info = await recordings(singerID: nil).first(where: { $0.shareToken == token }) else { return nil }
        return (info, url)
    }

    public func keepRecording(_ id: Int64, _ keep: Bool) async {
        try? await database.writer.write { db in try db.execute(sql: "UPDATE recording SET kept = ? WHERE id = ?", arguments: [keep, id]) }
    }

    public func deleteRecording(_ id: Int64) async {
        if let url = await recordingFile(id: id) { try? FileManager.default.removeItem(at: url) }
        try? await database.writer.write { db in _ = try RecordingRecord.deleteOne(db, key: id) }
    }

    /// Plays a recording on the TV with the song's lyrics, then returns to the results.
    public func replay(_ id: Int64) async throws {
        guard nowPlaying.state == .finished || nowPlaying.state == .idle else { throw ErrorBody(code: "busy", message: "Replay works between songs.") }
        guard let url = await recordingFile(id: id) else { throw QueueError.notFound }
        try playback.load(instrumental: url, vocals: nil)
        playback.keyShift = 0
        playback.tempo = 1
        playback.normalization = 1
        try playback.play(from: 0)
        isReplaying = true
        nowPlaying.state = .playing
        nowPlaying.positionMs = 0
        nowPlaying.positionAt = .now
        scheduleBroadcast()
    }

    func replayFinished() {
        isReplaying = false
        nowPlaying.state = .finished
        scheduleBroadcast()
        let id = nowPlaying.entry?.id
        guard settings.playback.autoAdvance else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            if self.nowPlaying.state == .finished, self.nowPlaying.entry?.id == id, !self.isReplaying { await self.playNext() }
        }
    }

    /// Builds the night's highlight reel from its recordings; returns its share link.
    func buildReel(sessionID: Int64) async -> String? {
        let files: [String] = (try? await database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT r.mixPath FROM recording r JOIN play p ON p.id = r.playId WHERE p.sessionId = ? AND r.mixPath IS NOT NULL ORDER BY r.createdAt", arguments: [sessionID])
        }) ?? []
        guard files.count >= 2 else { return nil }
        let token = "reel" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let out = paths.recordings.appendingPathComponent("\(token).m4a")
        let ok = await Task.detached(priority: .utility) { (try? HighlightReel.make(from: files.map { URL(fileURLWithPath: $0) }, to: out)) ?? false }.value
        return ok ? shareURL(token) : nil
    }

    /// Reels are plain files named by their token; recordings are looked up in the database.
    public func reelFile(token: String) -> URL? {
        guard token.hasPrefix("reel"), token.count == 16, token.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        let url = paths.recordings.appendingPathComponent("\(token).m4a")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func pruneRecordings() async {
        let days = settings.playback.keepRecordingsDays
        guard days > 0 else { return }
        let cutoff = Date.now.addingTimeInterval(-days * 86400)
        let old = (try? await database.writer.read { try RecordingRecord.filter(Column("kept") == false && Column("createdAt") < cutoff).fetchAll($0) }) ?? []
        for r in old { if let id = r.id { await deleteRecording(id) } }
    }
}
#endif
