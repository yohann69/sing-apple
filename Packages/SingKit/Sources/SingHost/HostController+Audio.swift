#if os(macOS)
import Foundation
import GRDB
import SingCore

/// Key and tempo remembered per song, so a singer's favourite key comes back next time.
struct SongPrefs: Codable, Sendable, Hashable {
    var keyShift = 0
    var tempo = 1.0
    var hiddenInFamilyMode = false

    init(keyShift: Int = 0, tempo: Double = 1, hiddenInFamilyMode: Bool = false) {
        self.keyShift = keyShift
        self.tempo = tempo
        self.hiddenInFamilyMode = hiddenInFamilyMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyShift = (try? c.decode(Int.self, forKey: .keyShift)) ?? 0
        tempo = (try? c.decode(Double.self, forKey: .tempo)) ?? 1
        hiddenInFamilyMode = (try? c.decode(Bool.self, forKey: .hiddenInFamilyMode)) ?? false
    }
}

extension HostController {
    func loadSongPrefs() async {
        let stored = try? await database.writer.read { try SettingRecord.fetchOne($0, key: "songPrefs") }
        let decoded = stored.flatMap { try? JSONDecoder().decode([String: SongPrefs].self, from: Data($0.json.utf8)) } ?? [:]
        songPrefs = Dictionary(uniqueKeysWithValues: decoded.compactMap { k, v in SongID(k).map { ($0, v) } })
    }

    func rememberSongPrefs() {
        guard let id = nowPlaying.entry?.song.id else { return }
        let p = SongPrefs(keyShift: playback.keyShift, tempo: playback.tempo, hiddenInFamilyMode: songPrefs[id]?.hiddenInFamilyMode ?? false)
        songPrefs[id] = p == SongPrefs() ? nil : p
        saveSongPrefs()
    }

    func saveSongPrefs() {        let map = Dictionary(uniqueKeysWithValues: songPrefs.map { (String($0.key), $0.value) })
        let json = String(decoding: (try? JSONEncoder().encode(map)) ?? Data("{}".utf8), as: UTF8.self)
        Task { try? await database.writer.write { db in try SettingRecord(key: "songPrefs", json: json).save(db) } }
    }

    /// Gain that brings this song to the common loudness target; measured once and cached next to the stems.
    func loudnessGain(_ record: SongRecord, stems: Bool) async -> Double {
        let cache = paths.songCache(record.audioHash).appendingPathComponent(stems ? "loudness.json" : "loudness-original.json")
        if let d = try? Data(contentsOf: cache), let db = try? JSONDecoder().decode(Double.self, from: d) { return Loudness.gain(forDB: db) }
        let urls = stems ? [paths.instrumental(record.audioHash), paths.vocals(record.audioHash)] : [URL(fileURLWithPath: record.filePath)]
        let measured = await Task.detached(priority: .userInitiated) { Loudness.measure(urls) }.value
        guard let db = measured else { return 1 }
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(db).write(to: cache)
        return Loudness.gain(forDB: db)
    }

    /// A howl is a loud, unchanging pitch held for over a second; the mics dip for a few seconds when one builds up.
    func guardFeedback() {
        let now = Date.now
        if let until = duckUntil {
            if until <= now { duckUntil = nil; mic.duck = 1 }
            return
        }
        guard settings.playback.feedbackProtection, mic.level > 0.7, let m = mic.livePitch.midi else {
            howlSince = nil
            return
        }
        if let prev = howlMidi, abs(prev - m) < 0.25, let since = howlSince {
            if now.timeIntervalSince(since) > 1.2 {
                mic.duck = 0.35
                duckUntil = now.addingTimeInterval(4)
                howlSince = nil
                lastError = "Feedback detected: the microphones were turned down for a moment. Move the mic away from the speakers."
                Task { await server?.broadcast(.toast(.init(message: "Feedback: mics turned down for a moment"))) }
            }
        } else {
            howlSince = now
        }
        howlMidi = m
    }
}
#endif
