import Foundation
import GRDB
import SingCore

public struct SongRecord: Codable, Sendable, Hashable, FetchableRecord, MutablePersistableRecord, TableRecord {
    public static let databaseTableName = "song"

    public var id: Int64?
    public var title: String
    public var artist: String
    public var album: String?
    public var durationMs: Int
    public var year: Int?
    public var genre: String?
    public var language: String?
    public var isrc: String?
    public var filePath: String
    public var audioHash: String
    public var hasArtwork: Bool = false
    public var palette: String?
    public var readiness: Readiness = .new
    public var lyricsKind: LyricsKind?
    public var isDuet: Bool = false
    public var missing: Bool = false
    public var lyricOffsetMs: Int = 0
    public var defaultGuideVocal: Double?
    public var pinned: Bool = false
    public var addedAt: Date = .now
    public var lastPlayedAt: Date?

    public init(title: String, artist: String, album: String? = nil, durationMs: Int, year: Int? = nil, genre: String? = nil, language: String? = nil, isrc: String? = nil, filePath: String, audioHash: String) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.year = year
        self.genre = genre
        self.language = language
        self.isrc = isrc
        self.filePath = filePath
        self.audioHash = audioHash
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var paletteColors: [String]? {
        palette.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }
    }

    public func summary(playCount: Int = 0, progress: Double? = nil) -> SongSummary {
        SongSummary(
            id: id ?? 0, title: title, artist: artist, album: album, durationMs: durationMs, year: year,
            genre: genre, language: language, isrc: isrc, hasArtwork: hasArtwork,
            readiness: missing ? .missingFile : readiness, progress: progress, lyricsKind: lyricsKind,
            isDuet: isDuet, playCount: playCount, palette: paletteColors
        )
    }
}

public struct SingerRecord: Codable, Sendable, FetchableRecord, MutablePersistableRecord, TableRecord {
    public static let databaseTableName = "singer"
    public var id: Int64?
    public var name: String
    public var emoji: String?
    public var colorHex: String
    public var createdAt: Date = .now
    public var createdByPad: String?

    public init(name: String, emoji: String?, colorHex: String, createdByPad: String?) {
        self.name = name
        self.emoji = emoji
        self.colorHex = colorHex
        self.createdByPad = createdByPad
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var singer: Singer { Singer(id: id ?? 0, name: name, emoji: emoji, colorHex: colorHex) }
}

public struct SessionRecord: Codable, Sendable, FetchableRecord, MutablePersistableRecord, TableRecord {
    public static let databaseTableName = "session"
    public var id: Int64?
    public var name: String?
    public var startedAt: Date
    public var endedAt: Date?

    public init(name: String?, startedAt: Date = .now) {
        self.name = name
        self.startedAt = startedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct PlayRecord: Codable, Sendable, FetchableRecord, MutablePersistableRecord, TableRecord {
    public static let databaseTableName = "play"
    public var id: Int64?
    public var songId: Int64?
    public var sessionId: Int64?
    public var startedAt: Date
    public var endedAt: Date?
    public var percentCompleted: Double = 0
    public var guideVocal: Double = 0
    public var keyShift: Int = 0
    public var tempo: Double = 1
    public var score: Double?
    public var skipped: Bool = false

    public init(songId: Int64, sessionId: Int64?, startedAt: Date = .now, guideVocal: Double) {
        self.songId = songId
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.guideVocal = guideVocal
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct PlaySingerRecord: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "playSinger"
    public var playId: Int64
    public var singerId: Int64
}

public struct QueueEventRecord: Codable, Sendable, FetchableRecord, MutablePersistableRecord, TableRecord {
    public static let databaseTableName = "queueEvent"
    public var id: Int64?
    public var sessionId: Int64?
    public var type: String
    public var songId: Int64?
    public var singerIds: String?
    public var padId: String?
    public var at: Date = .now

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct QueueEntryRecord: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "queueEntry"
    public var id: String
    public var position: Int
    public var songId: Int64
    public var singerIds: String
    public var addedBy: String?
    public var addedAt: Date
}

public struct RatingRecord: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "rating"
    public var songId: Int64
    public var singerId: Int64
    public var value: Int = 0
    public var favorite = false
    public var neverSuggest = false
}

public struct PadRecord: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "pad"
    public var id: String
    public var name: String
    public var model: String?
    public var tokenHash: String
    public var role: PadRole
    public var pairedAt: Date
    public var lastSeenAt: Date?
    public var revoked: Bool = false
}

public struct SettingRecord: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "setting"
    public var key: String
    public var json: String
}

public struct RecordingRecord: Codable, Sendable, FetchableRecord, MutablePersistableRecord, TableRecord {
    public static let databaseTableName = "recording"
    public var id: Int64?
    public var playId: Int64
    public var dryPath: String?
    public var wetPath: String?
    public var mixPath: String?
    public var createdAt: Date?
    public var durationMs: Int = 0
    public var shareToken: String?
    public var kept = false

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
