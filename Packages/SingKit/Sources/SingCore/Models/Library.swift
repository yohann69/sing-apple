import Foundation

public typealias SongID = Int64
public typealias SingerID = Int64

public enum Readiness: String, Codable, Sendable, CaseIterable {
    case new
    case queuedForProcessing
    case processing
    case ready
    case failed
    case missingFile
}

public struct SongSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: SongID
    public var title: String
    public var artist: String
    public var album: String?
    public var durationMs: Int
    public var year: Int?
    public var genre: String?
    public var language: String?
    public var isrc: String?
    public var hasArtwork: Bool
    public var readiness: Readiness
    public var progress: Double?
    public var lyricsKind: LyricsKind?
    public var isDuet: Bool
    public var playCount: Int
    public var palette: [String]?

    public init(
        id: SongID, title: String, artist: String, album: String? = nil, durationMs: Int,
        year: Int? = nil, genre: String? = nil, language: String? = nil, isrc: String? = nil,
        hasArtwork: Bool = false, readiness: Readiness = .new, progress: Double? = nil,
        lyricsKind: LyricsKind? = nil, isDuet: Bool = false, playCount: Int = 0, palette: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.year = year
        self.genre = genre
        self.language = language
        self.isrc = isrc
        self.hasArtwork = hasArtwork
        self.readiness = readiness
        self.progress = progress
        self.lyricsKind = lyricsKind
        self.isDuet = isDuet
        self.playCount = playCount
        self.palette = palette
    }
}

public struct Singer: Codable, Sendable, Hashable, Identifiable {
    public var id: SingerID
    public var name: String
    public var emoji: String?
    public var colorHex: String
    public var prefs: SingerPrefs?
    /// Made on the fly by a guest; the host can merge it into a real profile later.
    public var isGuest: Bool?

    public init(id: SingerID, name: String, emoji: String? = nil, colorHex: String) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.colorHex = colorHex
    }

    public static let palette = ["#FF8A3D", "#7BE07B", "#FFC145", "#B28DFF", "#FF5E3A", "#C6F06B", "#E8D44D", "#C08A5E"]
}

public struct QueueEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var song: SongSummary
    public var singers: [Singer]
    public var addedBy: String?
    public var addedAt: Date
    public var estimatedStart: Date?
    /// Singers take turns line by line and the best one wins.
    public var battle: Bool?

    public init(id: String = UUID().uuidString, song: SongSummary, singers: [Singer], addedBy: String? = nil, addedAt: Date = .now, estimatedStart: Date? = nil) {
        self.id = id
        self.song = song
        self.singers = singers
        self.addedBy = addedBy
        self.addedAt = addedAt
        self.estimatedStart = estimatedStart
    }
}

public enum PlaybackState: String, Codable, Sendable {
    case idle
    case preparing
    case countdown
    case playing
    case paused
    case finished
}

public struct NowPlaying: Codable, Sendable, Hashable {
    public var entry: QueueEntry?
    public var state: PlaybackState
    public var positionMs: Int
    public var positionAt: Date
    public var guideVocal: Double
    public var currentLine: String?
    public var nextLine: String?
    /// Semitones up or down from the original key.
    public var keyShift: Int = 0
    /// Playback speed, 1 is the original tempo.
    public var tempo: Double = 1
    /// The current song's own lyric timing correction.
    public var lyricOffsetMs: Int = 0
    /// Practice loop in song time; playback jumps back to the start when it reaches the end.
    public var loopStartMs: Int?
    public var loopEndMs: Int?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entry = try c.decodeIfPresent(QueueEntry.self, forKey: .entry)
        state = try c.decode(PlaybackState.self, forKey: .state)
        positionMs = try c.decode(Int.self, forKey: .positionMs)
        positionAt = try c.decode(Date.self, forKey: .positionAt)
        guideVocal = (try? c.decode(Double.self, forKey: .guideVocal)) ?? 0
        currentLine = try c.decodeIfPresent(String.self, forKey: .currentLine)
        nextLine = try c.decodeIfPresent(String.self, forKey: .nextLine)
        keyShift = (try? c.decode(Int.self, forKey: .keyShift)) ?? 0
        tempo = (try? c.decode(Double.self, forKey: .tempo)) ?? 1
        lyricOffsetMs = (try? c.decode(Int.self, forKey: .lyricOffsetMs)) ?? 0
        loopStartMs = try? c.decodeIfPresent(Int.self, forKey: .loopStartMs)
        loopEndMs = try? c.decodeIfPresent(Int.self, forKey: .loopEndMs)
    }

    public init(entry: QueueEntry? = nil, state: PlaybackState = .idle, positionMs: Int = 0, positionAt: Date = .now, guideVocal: Double = 0, currentLine: String? = nil, nextLine: String? = nil) {
        self.entry = entry
        self.state = state
        self.positionMs = positionMs
        self.positionAt = positionAt
        self.guideVocal = guideVocal
        self.currentLine = currentLine
        self.nextLine = nextLine
    }

    public func estimatedPosition(at date: Date = .now) -> Int {
        guard state == .playing else { return positionMs }
        return positionMs + Int(date.timeIntervalSince(positionAt) * 1000 * tempo)
    }
}
