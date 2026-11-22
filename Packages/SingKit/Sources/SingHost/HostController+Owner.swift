#if os(macOS)
import CryptoKit
import Foundation
import GRDB
import SingCore

/// Owner area: PIN, storage, pads, processing limits and ratings.
extension HostController {

    // MARK: Owner PIN

    public var ownerPINSet: Bool { ownerPINHash != nil }

    public func setOwnerPIN(_ pin: String?) {
        let trimmed = pin?.trimmingCharacters(in: .whitespaces) ?? ""
        if trimmed.isEmpty {
            ownerPINHash = nil
            Task { try? await database.writer.write { db in _ = try SettingRecord.deleteOne(db, key: "ownerPIN") } }
        } else {
            let salt = UUID().uuidString
            let hash = salt + ":" + Self.hashToken(salt + trimmed)
            ownerPINHash = hash
            Task { try? await database.writer.write { db in try SettingRecord(key: "ownerPIN", json: hash).save(db) } }
        }
        ownerTokens.removeAll()
    }

    func loadOwnerPIN() async {
        ownerPINHash = try? await database.writer.read { try SettingRecord.fetchOne($0, key: "ownerPIN")?.json }
    }

    func checkPIN(_ pin: String) -> Bool {
        guard let stored = ownerPINHash, let colon = stored.firstIndex(of: ":") else { return true }
        let salt = String(stored[..<colon])
        return String(stored[stored.index(after: colon)...]) == Self.hashToken(salt + pin)
    }

    /// Five wrong tries lock that pad out for 30 s, doubling after each further miss.
    public func unlockOwner(pin: String, pad: PadIdentity) throws -> OwnerSession {
        guard pad.role == .host else { throw QueueError.notAllowed }
        var guardState = pinAttempts[pad.padID] ?? AttemptGuard()
        if let until = guardState.lockedUntil, until > .now {
            throw ErrorBody(code: "locked", message: "Too many wrong PINs. Try again in \(Int(until.timeIntervalSinceNow.rounded(.up))) s.")
        }
        guard checkPIN(pin) else {
            guardState.fail()
            pinAttempts[pad.padID] = guardState
            throw ErrorBody(code: "pin", message: "Wrong owner PIN.")
        }
        pinAttempts[pad.padID] = nil
        let token = UUID().uuidString
        let expiry = Date.now.addingTimeInterval(15 * 60)
        ownerTokens[token] = expiry
        return OwnerSession(ownerToken: token, expiresAt: expiry)
    }

    /// A host pad without a PIN set is the owner; with a PIN it needs a fresh unlock.
    public func isOwner(_ pad: PadIdentity, token: String?) -> Bool {
        guard pad.role == .host else { return false }
        guard ownerPINSet else { return true }
        guard let token, let expiry = ownerTokens[token], expiry > .now else { return false }
        ownerTokens[token] = Date.now.addingTimeInterval(15 * 60)
        return true
    }

    func checkPairAttempt() throws {
        if let until = pairGuard.lockedUntil, until > .now {
            throw ErrorBody(code: "locked", message: "Too many wrong codes. Try again in \(Int(until.timeIntervalSinceNow.rounded(.up))) s.")
        }
    }

    func pairFailed() { pairGuard.fail() }
    func pairSucceeded() { pairGuard = AttemptGuard() }

    // MARK: Pads

    public func padList() async -> [PadInfo] {
        let rows = (try? await database.writer.read { try PadRecord.filter(Column("revoked") == false).order(Column("pairedAt").desc).fetchAll($0) }) ?? []
        let live = Set(connectedPads.map(\.padID))
        return rows.map { PadInfo(id: $0.id, name: $0.name, model: $0.model, role: $0.role, pairedAt: $0.pairedAt, lastSeenAt: $0.lastSeenAt, connected: live.contains($0.id)) }
    }

    /// Unpairs a pad: its token stops working and it is disconnected now.
    public func revokePad(_ id: String) async {
        try? await database.writer.write { db in try db.execute(sql: "UPDATE pad SET revoked = 1 WHERE id = ?", arguments: [id]) }
        await server?.disconnect(padID: id)
        connectedPads = await server?.connectedPads() ?? []
    }

    public func setPadRole(_ id: String, role: PadRole) async {
        try? await database.writer.write { db in try db.execute(sql: "UPDATE pad SET role = ? WHERE id = ?", arguments: [role.rawValue, id]) }
        await server?.disconnect(padID: id)
    }

    var activePadCount: Int {
        get async { (try? await database.writer.read { try PadRecord.filter(Column("revoked") == false).fetchCount($0) }) ?? 0 }
    }

    public var advertisedName: String {
        let n = settings.network.bonjourName.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? serverName : n
    }

    func readvertise() {
        guard advertise, serverRunning else { return }
        bonjour.start(name: advertisedName, port: port)
    }

    // MARK: Ratings

    public func rate(_ r: SongRating) async throws {
        let record = RatingRecord(songId: r.songID, singerId: r.singerID, value: max(-1, min(1, r.value)), favorite: r.favorite, neverSuggest: r.neverSuggest)
        try await database.writer.write { db in
            if record.value == 0 && !record.favorite && !record.neverSuggest {
                _ = try RatingRecord.deleteOne(db, key: ["songId": record.songId, "singerId": record.singerId])
            } else {
                try record.save(db)
            }
        }
        if r.favorite { evicted.remove(r.songID); saveEvicted() }
    }

    public func ratings(singerID: SingerID) async throws -> [SongRating] {
        try await database.writer.read { db in
            try RatingRecord.filter(Column("singerId") == singerID).fetchAll(db)
                .map { SongRating(songID: $0.songId, singerID: $0.singerId, value: $0.value, favorite: $0.favorite, neverSuggest: $0.neverSuggest) }
        }
    }

    public func setPinned(_ id: SongID, _ pinned: Bool) async {
        try? await library.update(id) { $0.pinned = pinned }
    }

    // MARK: Storage

    nonisolated static func size(of url: URL) -> (bytes: Int64, files: Int) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return (0, 0) }
        if !isDir.boolValue {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            return (Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0), 1)
        }
        var total: Int64 = 0, n = 0
        let e = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
        while let f = e?.nextObject() as? URL {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0); n += 1 }
        }
        return (total, n)
    }

    nonisolated static func category(ofCacheFile name: String) -> String {
        switch name {
        case "vocals.caf", "instrumental.caf": "stems"
        case "artwork.jpg": "artwork"
        case _ where name.hasPrefix("translation-"): "translations"
        default: "analysis"
        }
    }

    nonisolated static let categoryNames: [String: String] = [
        "stems": "Separated stems", "analysis": "Lyrics and pitch", "translations": "Translations",
        "artwork": "Artwork", "models": "AI models", "database": "History database",
        "backups": "Backups", "recordings": "Recordings",
    ]

    public func storageReport() async -> StorageReport {
        let paths = self.paths
        let records = (try? await library.all()) ?? []
        let limit = settings.storage.limitGB > 0 ? Int64(settings.storage.limitGB * 1e9) : nil
        let warn = Int64(settings.storage.lowDiskWarningGB * 1e9)
        return await Task.detached(priority: .utility) {
            var bytes: [String: Int64] = [:], items: [String: Int] = [:]
            var perSong: [SongUsage] = []
            for r in records {
                let dir = paths.songCache(r.audioHash)
                guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { continue }
                var songBytes: Int64 = 0
                var counted = Set<String>()
                for f in files {
                    let s = Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
                    let c = Self.category(ofCacheFile: f.lastPathComponent)
                    bytes[c, default: 0] += s
                    if counted.insert(c).inserted { items[c, default: 0] += 1 }
                    songBytes += s
                }
                perSong.append(SongUsage(id: r.id ?? 0, title: r.title, artist: r.artist, bytes: songBytes, lastPlayedAt: r.lastPlayedAt, pinned: r.pinned))
            }
            for (key, url) in [("models", paths.models), ("recordings", paths.recordings), ("backups", paths.root.appendingPathComponent("Backups"))] {
                let s = Self.size(of: url)
                bytes[key] = s.bytes
                items[key] = s.files
            }
            let db = ["sing.sqlite", "sing.sqlite-wal", "sing.sqlite-shm"].map { Self.size(of: paths.root.appendingPathComponent($0)).bytes }.reduce(0, +)
            bytes["database"] = db
            items["database"] = 1
            let order = ["stems", "analysis", "translations", "artwork", "recordings", "models", "database", "backups"]
            let cats = order.map { StorageCategory(id: $0, name: Self.categoryNames[$0] ?? $0, bytes: bytes[$0] ?? 0, items: items[$0] ?? 0, clearable: ["stems", "analysis", "translations", "backups"].contains($0)) }
            let vol = try? paths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            let free = vol?.volumeAvailableCapacityForImportantUsage ?? 0
            let total = cats.map(\.bytes).reduce(0, +)
            return StorageReport(
                categories: cats, totalBytes: total, diskFreeBytes: free, diskTotalBytes: Int64(vol?.volumeTotalCapacity ?? 0),
                limitBytes: limit, lowDisk: free < warn, biggestSongs: Array(perSong.sorted { $0.bytes > $1.bytes }.prefix(30))
            )
        }.value
    }

    /// Deletes rebuildable caches. Songs whose stems or analysis go are no longer Ready and are not re-processed until queued.
    public func clearCache(_ req: ClearCacheRequest) async -> ClearCacheResult {
        let records = (try? await library.all()) ?? []
        let now = Date.now
        let playing = nowPlaying.entry?.song.id
        let queued = Set(queue.entries.map(\.song.id))
        let favorites = Set((try? await database.writer.read { try Int64.fetchAll($0, sql: "SELECT songId FROM rating WHERE favorite = 1") }) ?? [])
        if req.category == "backups" {
            let dir = paths.root.appendingPathComponent("Backups")
            let s = Self.size(of: dir)
            if !req.dryRun { try? FileManager.default.removeItem(at: dir) }
            return ClearCacheResult(freedBytes: s.bytes, songs: 0)
        }
        let cats: Set<String> = req.category.map { [$0] } ?? ["stems", "analysis", "translations"]
        var freed: Int64 = 0, touched = 0
        var invalidated: [SongID] = []
        for r in records {
            guard let id = r.id, id != playing else { continue }
            if let only = req.songID, only != id { continue }
            if req.songID == nil {
                if queued.contains(id) { continue }
                if let days = req.notPlayedForDays {
                    if r.pinned || favorites.contains(id) { continue }
                    let last = r.lastPlayedAt ?? r.addedAt
                    if now.timeIntervalSince(last) < Double(days) * 86400 { continue }
                }
            }
            let dir = paths.songCache(r.audioHash)
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            var hit = false
            for f in files where cats.contains(Self.category(ofCacheFile: f.lastPathComponent)) {
                if f.lastPathComponent.hasPrefix("embedded") { continue }
                freed += Self.size(of: f).bytes
                hit = true
                if !req.dryRun { try? FileManager.default.removeItem(at: f) }
            }
            if hit {
                touched += 1
                if cats.contains("stems") || cats.contains("analysis") { invalidated.append(id) }
            }
        }
        if !req.dryRun, !invalidated.isEmpty {
            for id in invalidated {
                try? await library.update(id) { $0.readiness = .new }
                evicted.insert(id)
            }
            saveEvicted()
            await reloadLibrary()
        }
        return ClearCacheResult(freedBytes: freed, songs: touched)
    }

    func loadEvicted() async {
        let stored = try? await database.writer.read { try SettingRecord.fetchOne($0, key: "evicted") }
        evicted = Set(stored.flatMap { try? JSONDecoder().decode([SongID].self, from: Data($0.json.utf8)) } ?? [])
    }

    func saveEvicted() {
        let json = String(decoding: (try? JSONEncoder().encode(Array(evicted))) ?? Data("[]".utf8), as: UTF8.self)
        Task { try? await database.writer.write { db in try SettingRecord(key: "evicted", json: json).save(db) } }
    }

    /// Over the cap, removes the stems of the songs not played for the longest time; pinned, favorite and queued songs stay.
    func enforceStorageLimits() async {
        await pruneRecordings()
        let s = settings.storage
        let report = await storageReport()
        if report.lowDisk, !lowDiskWarned {
            lowDiskWarned = true
            lastError = "Your Mac is low on space (\(Self.gb(report.diskFreeBytes)) free). Clear some cache in Settings, Storage."
            await server?.broadcast(.toast(.init(message: "The Mac is low on disk space")))
        } else if !report.lowDisk {
            lowDiskWarned = false
        }
        guard s.autoFree else { return }
        let stems = report.categories.first { $0.id == "stems" }?.bytes ?? 0
        var overBy: Int64 = 0
        if s.limitGB > 0 { overBy = max(overBy, report.totalBytes - Int64(s.limitGB * 1e9)) }
        if s.stemsLimitGB > 0 { overBy = max(overBy, stems - Int64(s.stemsLimitGB * 1e9)) }
        guard overBy > 0 else { return }
        let favorites = Set((try? await database.writer.read { try Int64.fetchAll($0, sql: "SELECT songId FROM rating WHERE favorite = 1") }) ?? [])
        let queued = Set(queue.entries.map(\.song.id)).union([nowPlaying.entry?.song.id].compactMap { $0 })
        let records = ((try? await library.all()) ?? []).filter { r in
            guard let id = r.id else { return false }
            return !r.pinned && !favorites.contains(id) && !queued.contains(id)
                && FileManager.default.fileExists(atPath: paths.vocals(r.audioHash).path)
        }.sorted { ($0.lastPlayedAt ?? $0.addedAt) < ($1.lastPlayedAt ?? $1.addedAt) }
        var freed: Int64 = 0
        for r in records where freed < overBy {
            let res = await clearCache(ClearCacheRequest(category: "stems", songID: r.id))
            freed += res.freedBytes
        }
    }

    static func gb(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    // MARK: Processing limits

    /// Background separation waits while someone sings, when turned off, or during a rest period.
    func updateProcessingHold() {
        let sys = settings.system
        let singing = nowPlaying.state == .playing || nowPlaying.state == .countdown
        var hold = !sys.processLibraryInBackground || (sys.pauseProcessingWhileSinging && singing)
        if sys.restAfterMinutes > 0 {
            if let start = processingStartedAt, Date.now.timeIntervalSince(start) > sys.restAfterMinutes * 60 {
                restUntil = .now.addingTimeInterval(10 * 60)
                processingStartedAt = nil
            }
            if let r = restUntil, r > .now { hold = true } else { restUntil = nil }
        }
        if hold != processingHeld {
            processingHeld = hold
            let sep = separation
            Task { await sep.setHoldBackground(hold) }
        }
    }

    public var processingStatus: String {
        if !settings.system.processLibraryInBackground { return "Only songs in the queue are processed." }
        if let r = restUntil, r > .now { return "Resting until \(r.formatted(date: .omitted, time: .shortened))." }
        if processingHeld { return "Paused while someone sings." }
        return "Processing the library in the background."
    }

    // MARK: Owner overview

    public func ownerOverview() async -> OwnerOverview {
        OwnerOverview(pinRequired: ownerPINSet, services: settings.services, storage: await storageReport(), pads: await padList(), processingPaused: processingHeld)
    }

    /// Settings only the owner may change: services, storage, system and network.
    public func applyOwnerSettings(_ s: SingSettings) {
        var next = settings
        next.services = s.services
        next.storage = s.storage
        next.system = s.system
        next.network = s.network
        next.privacy = s.privacy
        settings = next
    }
}

struct AttemptGuard {
    var failures = 0
    var lockedUntil: Date?

    mutating func fail() {
        failures += 1
        if failures >= 5 {
            lockedUntil = .now.addingTimeInterval(30 * pow(2, Double(failures - 5)))
        }
    }
}
#endif
