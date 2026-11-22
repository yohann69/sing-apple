#if os(macOS)
import Foundation
import GRDB
import IOKit.pwr_mgt
import SingCore

/// Per-song settings, the lyric sync editor, privacy rules, backups, keep-awake and reset.
extension HostController {

    // MARK: Per-song settings

    public func songSettings(_ id: SongID) async -> SongSettings? {
        guard let r = try? await library.song(id) else { return nil }
        let p = songPrefs[id] ?? SongPrefs()
        return SongSettings(lyricOffsetMs: r.lyricOffsetMs, defaultGuideVocal: r.defaultGuideVocal, keyShift: p.keyShift, tempo: p.tempo, hiddenInFamilyMode: p.hiddenInFamilyMode, pinned: r.pinned)
    }

    public func updateSongSettings(_ id: SongID, _ s: SongSettings) async {
        try? await library.update(id) { r in
            r.lyricOffsetMs = max(-5000, min(5000, s.lyricOffsetMs))
            r.defaultGuideVocal = s.defaultGuideVocal.map { max(0, min(1, $0)) }
            r.pinned = s.pinned
        }
        let p = SongPrefs(keyShift: max(-6, min(6, s.keyShift)), tempo: max(0.75, min(1.25, s.tempo)), hiddenInFamilyMode: s.hiddenInFamilyMode)
        songPrefs[id] = p == SongPrefs() ? nil : p
        saveSongPrefs()
        if nowPlaying.entry?.song.id == id {
            applyLyricOffset(s.lyricOffsetMs)
            playback.keyShift = p.keyShift
            playback.tempo = p.tempo
            nowPlaying.keyShift = p.keyShift
            nowPlaying.tempo = p.tempo
            scheduleBroadcast()
        }
    }

    /// Shifts the lyrics now on screen and stores the offset on the song.
    public func setLyricOffset(_ ms: Int) {
        guard let id = nowPlaying.entry?.song.id else { return }
        let clamped = max(-5000, min(5000, ms))
        applyLyricOffset(clamped)
        Task { try? await library.update(id) { $0.lyricOffsetMs = clamped } }
        scheduleBroadcast()
    }

    func applyLyricOffset(_ ms: Int) {
        let delta = Double(ms - nowPlaying.lyricOffsetMs) / 1000
        nowPlaying.lyricOffsetMs = ms
        if delta != 0 { lyrics = lyrics?.shifted(by: delta) }
    }

    /// Saves lyrics fixed in the sync editor (times are song time, without the per-song offset).
    public func saveSyncedLyrics(_ id: SongID, _ l: Lyrics) async throws {
        guard let r = try await library.song(id) else { throw QueueError.notFound }
        try lyricsService.saveManual(r, l)
        try? FileManager.default.removeItem(at: paths.songCache(r.audioHash).appendingPathComponent("uploaded"))
        defer { Task { await considerUpload(id) } }
        try? await library.update(id) { $0.lyricOffsetMs = 0; $0.lyricsKind = l.kind }
        if nowPlaying.entry?.song.id == id {
            nowPlaying.lyricOffsetMs = 0
            lyrics = l
            scheduleBroadcast()
        }
        await reloadLibrary()
    }

    public func songFileURL(_ id: SongID) async -> URL? {
        (try? await library.song(id)).flatMap { $0 }.map { URL(fileURLWithPath: $0.filePath) }
    }

    public func rawLyrics(_ id: SongID) async -> Lyrics? {
        guard let r = try? await library.song(id) else { return nil }
        return await lyricsService.resolve(r)
    }

    // MARK: Privacy

    func familyHidden(_ s: SongSummary) -> Bool {
        guard settings.privacy.familyMode else { return false }
        if songPrefs[s.id]?.hiddenInFamilyMode == true { return true }
        let t = s.title.lowercased()
        return t.contains("explicit") || t.contains("[e]")
    }

    public func canSeeStats(_ pad: PadIdentity) -> Bool { pad.role == .host || settings.privacy.guestsSeeStats }

    func requireGuestPermission(_ pad: PadIdentity, _ allowed: Bool, _ message: String) throws {
        if pad.role != .host && !allowed { throw ErrorBody(code: "notAllowed", message: message) }
    }

    // MARK: Backups

    var backupsFolder: URL { paths.root.appendingPathComponent("Backups", isDirectory: true) }

    /// A consistent copy of the database (history, singers, ratings, settings) as one SQLite file.
    public func backupDatabase(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let target = try DatabaseQueue(path: url.path)
        try database.writer.backup(to: target)
    }

    public func exportDatabase() throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sing-export-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try backupDatabase(to: url)
        return try Data(contentsOf: url)
    }

    /// One backup a day, the last seven kept.
    func dailyBackup() {
        let fm = FileManager.default
        let stamp = Date.now.formatted(.iso8601.year().month().day())
        let url = backupsFolder.appendingPathComponent("sing-daily-\(stamp).sqlite")
        guard !fm.fileExists(atPath: url.path) else { return }
        try? backupDatabase(to: url)
        let daily = ((try? fm.contentsOfDirectory(at: backupsFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("sing-daily-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in daily.dropFirst(7) { try? fm.removeItem(at: old) }
    }

    public var lastBackupDate: Date? {
        ((try? FileManager.default.contentsOfDirectory(at: backupsFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    // MARK: Keep awake

    /// Holds off sleep while a party is on, so the TV and pads never lose the Mac.
    func updateKeepAwake() {
        let want = session != nil || nowPlaying.state == .playing || !preparing.isEmpty
        if want, sleepAssertion == 0 {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Sing! party in progress" as CFString, &id) == kIOReturnSuccess {
                sleepAssertion = id
            }
        } else if !want, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }

    // MARK: Factory reset

    /// Deletes history, singers, pads, settings and every cache. Music files are never touched.
    public func factoryReset() async {
        stopPlayback()
        await revokeAllPads()
        try? backupDatabase(to: backupsFolder.appendingPathComponent("sing-before-reset-\(Int(Date.now.timeIntervalSince1970)).sqlite"))
        try? await database.writer.write { db in
            for t in ["playSinger", "recording", "play", "queueEvent", "queueEntry", "rating", "session", "singer", "pad", "setting"] {
                try db.execute(sql: "DELETE FROM \(t)")
            }
        }
        try? FileManager.default.removeItem(at: paths.cache)
        try? FileManager.default.removeItem(at: paths.recordings)
        try? paths.ensure()
        try? await database.writer.write { db in try db.execute(sql: "UPDATE song SET readiness = ?, lyricsKind = NULL, lyricOffsetMs = 0, defaultGuideVocal = NULL, pinned = 0", arguments: [Readiness.new.rawValue]) }
        settings = SingSettings()
        ownerPINHash = nil
        songPrefs = [:]
        evicted = []
        queue = QueueModel()
        session = nil
        await reloadSingers()
        await reloadLibrary()
        await loadRequests()
        let pending = songs.map(\.id)
        if modelAvailable { await separation.enqueueBackground(pending) }
        scheduleBroadcast()
    }
}
#endif
