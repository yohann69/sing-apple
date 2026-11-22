import Foundation

public enum StatsPeriod: String, Codable, Sendable, CaseIterable {
    case tonight
    case year
    case allTime
}

public struct RankedSong: Codable, Sendable, Hashable, Identifiable {
    public var song: SongSummary
    public var count: Int
    public var id: SongID { song.id }

    public init(song: SongSummary, count: Int) {
        self.song = song
        self.count = count
    }
}

public struct RankedName: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var count: Int
    public var colorHex: String?
    public var id: String { name }

    public init(name: String, count: Int, colorHex: String? = nil) {
        self.name = name
        self.count = count
        self.colorHex = colorHex
    }
}

public struct NightSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: Int64
    public var startedAt: Date
    public var plays: Int
    public var singers: Int

    public init(id: Int64, startedAt: Date, plays: Int, singers: Int) {
        self.id = id
        self.startedAt = startedAt
        self.plays = plays
        self.singers = singers
    }
}

public struct StatsResponse: Codable, Sendable, Hashable {
    public var period: StatsPeriod
    public var totalPlays: Int
    public var totalMinutes: Int
    public var distinctSongs: Int
    public var topSongs: [RankedSong]
    public var topArtists: [RankedName]
    public var topSingers: [RankedName]
    public var mostSkipped: [RankedSong]
    public var busiestNights: [NightSummary]
    public var decades: [RankedName]

    public init(period: StatsPeriod, totalPlays: Int = 0, totalMinutes: Int = 0, distinctSongs: Int = 0, topSongs: [RankedSong] = [], topArtists: [RankedName] = [], topSingers: [RankedName] = [], mostSkipped: [RankedSong] = [], busiestNights: [NightSummary] = [], decades: [RankedName] = []) {
        self.period = period
        self.totalPlays = totalPlays
        self.totalMinutes = totalMinutes
        self.distinctSongs = distinctSongs
        self.topSongs = topSongs
        self.topArtists = topArtists
        self.topSingers = topSingers
        self.mostSkipped = mostSkipped
        self.busiestNights = busiestNights
        self.decades = decades
    }
}

public struct Suggestion: Codable, Sendable, Hashable, Identifiable {
    public var song: SongSummary
    public var reason: String
    public var id: SongID { song.id }

    public init(song: SongSummary, reason: String) {
        self.song = song
        self.reason = reason
    }
}

public struct SingerStats: Codable, Sendable, Hashable {
    public var singer: Singer
    public var plays: Int
    public var topSongs: [RankedSong]
    public var recent: [RankedSong]

    public init(singer: Singer, plays: Int, topSongs: [RankedSong], recent: [RankedSong]) {
        self.singer = singer
        self.plays = plays
        self.topSongs = topSongs
        self.recent = recent
    }
}

/// End-of-party summary shown on the TV and the pads.
public struct PartyRecap: Codable, Sendable, Hashable {
    public var name: String?
    public var startedAt: Date
    public var endedAt: Date
    public var songs: Int
    public var minutes: Int
    public var singers: Int
    public var topSinger: RankedName?
    public var bestScore: RankedName?
    public var bestSong: String?
    public var topArtist: String?
    public var highlights: [String]
    /// A short mix of every recorded performance of the night, when recording was on.
    public var reelURL: String?

    public init(name: String?, startedAt: Date, endedAt: Date, songs: Int, minutes: Int, singers: Int, topSinger: RankedName?, bestScore: RankedName?, bestSong: String?, topArtist: String?, highlights: [String]) {
        self.name = name
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.songs = songs
        self.minutes = minutes
        self.singers = singers
        self.topSinger = topSinger
        self.bestScore = bestScore
        self.bestSong = bestSong
        self.topArtist = topArtist
        self.highlights = highlights
    }
}
