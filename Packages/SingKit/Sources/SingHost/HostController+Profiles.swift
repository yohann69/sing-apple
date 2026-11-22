#if os(macOS)
import Foundation
import GRDB
import SingCore

/// Singer profiles (prefs, PIN, range, merge), want-to-sing lists, settings profiles, locks and the audit log.
extension HostController {

    // MARK: Singer prefs

    func singerRecord(_ id: SingerID) async -> SingerRecord? {
        try? await database.writer.read { try SingerRecord.fetchOne($0, key: id) }
    }

    /// A singer with a PIN can only be changed or queued from a host pad or a pad that entered it.
    func mayActAs(_ id: SingerID, pad: PadIdentity) async -> Bool {
        guard pad.role != .host, let r = await singerRecord(id), r.pinHash != nil else { return true }
        return singerUnlocks[id, default: []].contains(pad.padID)
    }

    public func updateSingerPrefs(_ id: SingerID, _ p: SingerPrefs, pad: PadIdentity?) async throws {
        if let pad, !(await mayActAs(id, pad: pad)) { throw ErrorBody(code: "pin", message: "Enter this singer's PIN first.") }
        guard var r = await singerRecord(id) else { throw QueueError.notFound }
        let old = r.singer.prefs ?? SingerPrefs()
        var next = p
        next.rangeLow = old.rangeLow
        next.rangeHigh = old.rangeHigh
        next.hasPIN = r.pinHash != nil
        r.prefs = String(decoding: (try? JSONEncoder().encode(next)) ?? Data(), as: UTF8.self)
        let rec = r
        try await database.writer.write { db in try rec.update(db) }
        await reloadSingers()
        scheduleBroadcast()
    }

    public func renameSinger(_ id: SingerID, name: String, emoji: String?, colorHex: String?) async {
        guard var r = await singerRecord(id) else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { r.name = n }
        r.emoji = emoji
        if let colorHex { r.colorHex = colorHex }
        let rec = r
        try? await database.writer.write { db in try rec.update(db) }
        await reloadSingers()
        scheduleBroadcast()
    }

    public func setSingerPIN(_ id: SingerID, pin: String?, pad: PadIdentity?) async throws {
        if let pad, !(await mayActAs(id, pad: pad)) { throw ErrorBody(code: "pin", message: "Enter this singer's PIN first.") }
        guard var r = await singerRecord(id) else { throw QueueError.notFound }
        let p = pin?.trimmingCharacters(in: .whitespaces) ?? ""
        if p.isEmpty { r.pinHash = nil } else {
            guard p.count >= 4 else { throw ErrorBody(code: "pin", message: "Use at least 4 digits.") }
            let salt = UUID().uuidString
            r.pinHash = salt + ":" + Self.hashToken(salt + p)
        }
        let rec = r
        try await database.writer.write { db in try rec.update(db) }
        if let pad { singerUnlocks[id, default: []].insert(pad.padID) }
        audit(pad?.name ?? "Mac", p.isEmpty ? "removed the PIN of \(r.name)" : "set a PIN for \(r.name)")
        await reloadSingers()
        scheduleBroadcast()
    }

    public func verifySingerPIN(_ id: SingerID, pin: String, pad: PadIdentity) async throws {
        guard let r = await singerRecord(id), let stored = r.pinHash, let colon = stored.firstIndex(of: ":") else { return }
        var g = singerPinAttempts[id] ?? AttemptGuard()
        if let until = g.lockedUntil, until > .now { throw ErrorBody(code: "locked", message: "Too many wrong PINs. Try again in a moment.") }
        guard String(stored[stored.index(after: colon)...]) == Self.hashToken(String(stored[..<colon]) + pin) else {
            g.fail()
            singerPinAttempts[id] = g
            throw ErrorBody(code: "pin", message: "Wrong PIN for \(r.name).")
        }
        singerPinAttempts[id] = nil
        singerUnlocks[id, default: []].insert(pad.padID)
    }

    /// Adds what was just sung to the singer's learned range.
    func learnRange(_ singers: [Singer]) async {
        guard singers.count == 1, let s = singers.first, let r = scoreKeeper.sungRange, var rec = await singerRecord(s.id) else { return }
        var p = rec.singer.prefs ?? SingerPrefs()
        let k = 0.3
        p.rangeLow = p.rangeLow.map { $0 * (1 - k) + r.low * k } ?? r.low
        p.rangeHigh = p.rangeHigh.map { $0 * (1 - k) + r.high * k } ?? r.high
        p.hasPIN = rec.pinHash != nil
        rec.prefs = String(decoding: (try? JSONEncoder().encode(p)) ?? Data(), as: UTF8.self)
        let out = rec
        try? await database.writer.write { db in try out.update(db) }
        await reloadSingers()
    }

    /// Two profiles that are the same person: plays, ratings and wishes move to `into`.
    public func mergeSingers(from: SingerID, into: SingerID, by who: String) async throws {
        guard from != into, let a = await singerRecord(from), await singerRecord(into) != nil else { throw QueueError.notFound }
        try await database.writer.write { db in
            for table in ["playSinger", "rating", "wish"] {
                try db.execute(sql: "UPDATE OR IGNORE \(table) SET singerId = ? WHERE singerId = ?", arguments: [into, from])
                try db.execute(sql: "DELETE FROM \(table) WHERE singerId = ?", arguments: [from])
            }
            _ = try SingerRecord.deleteOne(db, key: from)
        }
        audit(who, "merged \(a.name) into another profile")
        await reloadSingers()
        scheduleBroadcast()
    }

    public func deleteSinger(_ id: SingerID, by who: String) async {
        let name = await singerRecord(id)?.name ?? "a singer"
        try? await database.writer.write { db in _ = try SingerRecord.deleteOne(db, key: id) }
        audit(who, "deleted \(name)")
        await reloadSingers()
        scheduleBroadcast()
    }

    /// Applies the first singer's own choices when their song starts.
    func applySingerPrefs(_ entry: QueueEntry, songHasGuide: Bool) {
        guard let p = entry.singers.first.flatMap({ s in singers.first { $0.id == s.id } })?.prefs else {
            mic.preset = MicPreset(rawValue: settings.playback.micPreset) ?? .hall
            return
        }
        if !songHasGuide, let g = p.guideVocal { playback.guideVocal = g; nowPlaying.guideVocal = g }
        mic.preset = p.micPreset.flatMap(MicPreset.init(rawValue:)) ?? MicPreset(rawValue: settings.playback.micPreset) ?? .hall
        if p.keyOffset != 0, nowPlaying.keyShift == 0 {
            let k = max(-6, min(6, p.keyOffset))
            playback.keyShift = k
            nowPlaying.keyShift = k
        }
    }

    /// Older profiles could get pink or blue; give them colors from the current palette.
    func recolorSingers() async {
        let old: Set<String> = ["#4CC9F0", "#FF6B9A", "#5EEAD4", "#F472B6"]
        let records = (try? await database.writer.read { try SingerRecord.fetchAll($0) }) ?? []
        var changed = false
        for (i, r) in records.enumerated() where old.contains(r.colorHex.uppercased()) {
            var rec = r
            rec.colorHex = Singer.palette[i % Singer.palette.count]
            let out = rec
            try? await database.writer.write { db in try out.update(db) }
            changed = true
        }
        if changed { await reloadSingers() }
    }

    // MARK: Smart key

    /// Moves the song's melody into the singer's comfortable range, by the smallest step.
    public func smartKey(songID: SongID, singerID: SingerID) async -> SmartKey? {
        guard let p = singers.first(where: { $0.id == singerID })?.prefs, let lo = p.rangeLow, let hi = p.rangeHigh,
              let track = await displayPitch(songID: songID), !track.notes.isEmpty else { return nil }
        let m = track.notes.map { Double($0.midi) }.sorted()
        let songMid = (m[m.count / 10] + m[m.count * 9 / 10]) / 2
        var shift = Int(((lo + hi) / 2 - songMid).rounded())
        while shift > 6 { shift -= 12 }
        while shift < -6 { shift += 12 }
        let name = singers.first { $0.id == singerID }?.name ?? "this singer"
        if abs(shift) <= 1 { return SmartKey(semitones: 0, reason: "Already in \(name)'s range") }
        return SmartKey(semitones: shift, reason: "\(shift > 0 ? "Up" : "Down") \(abs(shift)) to fit \(name)'s range")
    }

    // MARK: Want-to-sing lists

    public func wishes(_ singerID: SingerID) async -> [SongSummary] {
        let ids = (try? await database.writer.read { try Int64.fetchAll($0, sql: "SELECT songId FROM wish WHERE singerId = ? ORDER BY addedAt", arguments: [singerID]) }) ?? []
        return ids.compactMap { id in songs.first { $0.id == id } }
    }

    public func setWish(_ singerID: SingerID, songID: SongID, on: Bool, pad: PadIdentity?) async throws {
        if let pad, !(await mayActAs(singerID, pad: pad)) { throw ErrorBody(code: "pin", message: "Enter this singer's PIN first.") }
        try await database.writer.write { db in
            if on { try db.execute(sql: "INSERT OR IGNORE INTO wish (singerId, songId, addedAt) VALUES (?, ?, ?)", arguments: [singerID, songID, Date.now]) }
            else { try db.execute(sql: "DELETE FROM wish WHERE singerId = ? AND songId = ?", arguments: [singerID, songID]) }
        }
    }

    /// Queues the singer's next wish and takes it off the list.
    public func queueWish(_ singerID: SingerID, pad: PadIdentity) async throws -> SongSummary? {
        guard let next = await wishes(singerID).first else { return nil }
        try await enqueue(songID: next.id, singerIDs: [singerID], playNext: false, by: pad.padID)
        try await setWish(singerID, songID: next.id, on: false, pad: nil)
        return next
    }

    // MARK: Settings profiles

    static let builtInProfiles: [SettingsProfile] = {
        var party = SingSettings()
        party.playback.recordPerformances = true
        var family = SingSettings()
        family.privacy.familyMode = true
        family.privacy.guestsCanCreateSingers = true
        family.playback.difficulty = "easy"
        var practice = SingSettings()
        practice.playback.countdownBetweenSongs = false
        practice.playback.defaultGuideVocal = 0.5
        practice.tv.justForFun = true
        practice.privacy.keepHistory = false
        return [SettingsProfile(name: "Party", settings: party), SettingsProfile(name: "Family", settings: family), SettingsProfile(name: "Practice", settings: practice)]
    }()

    public func settingsProfiles() async -> [SettingsProfile] {
        let stored = try? await database.writer.read { try SettingRecord.fetchOne($0, key: "settingsProfiles") }
        let saved = stored.flatMap { try? SingProtocol.decoder().decode([SettingsProfile].self, from: Data($0.json.utf8)) } ?? []
        return saved + Self.builtInProfiles.filter { b in !saved.contains { $0.name == b.name } }
    }

    public func saveSettingsProfile(_ name: String) async {
        var list = await settingsProfiles().filter { $0.name != name }
        list.insert(SettingsProfile(name: name, settings: settings), at: 0)
        let json = String(decoding: (try? SingProtocol.encoder().encode(list)) ?? Data(), as: UTF8.self)
        try? await database.writer.write { db in try SettingRecord(key: "settingsProfiles", json: json).save(db) }
    }

    /// The built-in profiles change only what makes them different; mics, volumes and devices stay.
    static func applyBuiltIn(_ name: String, to s: inout SingSettings) -> Bool {
        switch name {
        case "Party":
            s.playback.recordPerformances = true
            s.privacy.familyMode = false
            s.privacy.keepHistory = true
            s.tv.justForFun = false
            s.playback.difficulty = "normal"
        case "Family":
            s.privacy.familyMode = true
            s.privacy.guestsCanCreateSingers = true
            s.playback.difficulty = "easy"
            s.tv.justForFun = false
        case "Practice":
            s.playback.countdownBetweenSongs = false
            s.playback.defaultGuideVocal = 0.5
            s.tv.justForFun = true
            s.privacy.keepHistory = false
            s.playback.recordPerformances = false
        default:
            return false
        }
        return true
    }

    /// Party-facing parts only; services, storage, network and locks stay as the owner set them.
    public func applySettingsProfile(_ name: String, by who: String) async {
        guard let p = await settingsProfiles().first(where: { $0.name == name }) else { return }
        var next = settings
        let saved = try? await database.writer.read { try SettingRecord.fetchOne($0, key: "settingsProfiles") }
        let isCustom = saved.flatMap { try? SingProtocol.decoder().decode([SettingsProfile].self, from: Data($0.json.utf8)) }?.contains { $0.name == name } ?? false
        if !isCustom, Self.applyBuiltIn(name, to: &next) {
            settings = next
            audit(who, "switched to the \(name) settings")
            return
        }
        next.tv = p.settings.tv
        next.playback = p.settings.playback
        next.queue = p.settings.queue
        next.theme = p.settings.theme
        next.privacy = p.settings.privacy
        settings = next
        audit(who, "switched to the \(name) settings")
    }

    // MARK: Locks

    /// Merges settings from a pad, section by section, honoring the owner's locks.
    func mergeSettings(_ incoming: SingSettings, from pad: PadIdentity) throws -> SingSettings {
        func allowed(_ section: String) -> Bool {
            switch settings.locks[section] ?? "hosts" {
            case "guests": true
            case "mac": false
            default: pad.role == .host
            }
        }
        var next = settings
        var changed: [String] = []
        if allowed("tv"), incoming.tv != settings.tv { next.tv = incoming.tv; changed.append("TV display") }
        if allowed("playback"), incoming.playback != settings.playback { next.playback = incoming.playback; changed.append("playback") }
        if allowed("queue"), incoming.queue != settings.queue { next.queue = incoming.queue; changed.append("queue") }
        if allowed("theme"), incoming.theme != settings.theme { next.theme = incoming.theme; changed.append("theme") }
        if changed.isEmpty, next == settings, incoming.tv != settings.tv || incoming.playback != settings.playback || incoming.queue != settings.queue || incoming.theme != settings.theme {
            throw ErrorBody(code: "locked", message: "The owner locked these settings.")
        }
        if !changed.isEmpty { audit(pad.name, "changed \(changed.joined(separator: ", ")) settings") }
        return next
    }

    // MARK: Audit log

    func audit(_ who: String, _ action: String) {
        let at = Date.now
        Task { try? await database.writer.write { db in try db.execute(sql: "INSERT INTO auditLog (at, who, action) VALUES (?, ?, ?)", arguments: [at, who, action]) } }
    }

    public func auditLog(limit: Int = 300) async -> [AuditEntry] {
        (try? await database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT at, who, action FROM auditLog ORDER BY id DESC LIMIT ?", arguments: [limit]).map { AuditEntry(at: $0["at"], who: $0["who"], action: $0["action"]) }
        }) ?? []
    }
}
#endif
