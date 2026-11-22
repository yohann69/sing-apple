import Foundation

/// A singer's opinion of a song: thumbs, favorite, never suggest.
public struct SongRating: Codable, Sendable, Hashable {
    public var songID: SongID
    public var singerID: SingerID
    /// -1 thumbs down, 0 none, 1 thumbs up.
    public var value: Int
    public var favorite: Bool
    public var neverSuggest: Bool

    public init(songID: SongID, singerID: SingerID, value: Int = 0, favorite: Bool = false, neverSuggest: Bool = false) {
        self.songID = songID
        self.singerID = singerID
        self.value = value
        self.favorite = favorite
        self.neverSuggest = neverSuggest
    }
}

public struct StorageCategory: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var bytes: Int64
    public var items: Int
    /// Whether the files can be rebuilt, so clearing them only costs processing time.
    public var clearable: Bool

    public init(id: String, name: String, bytes: Int64, items: Int, clearable: Bool) {
        self.id = id
        self.name = name
        self.bytes = bytes
        self.items = items
        self.clearable = clearable
    }
}

public struct StorageReport: Codable, Sendable, Hashable {
    public var categories: [StorageCategory]
    public var totalBytes: Int64
    public var diskFreeBytes: Int64
    public var diskTotalBytes: Int64
    public var limitBytes: Int64?
    public var lowDisk: Bool
    public var biggestSongs: [SongUsage]

    public init(categories: [StorageCategory], totalBytes: Int64, diskFreeBytes: Int64, diskTotalBytes: Int64, limitBytes: Int64?, lowDisk: Bool, biggestSongs: [SongUsage]) {
        self.categories = categories
        self.totalBytes = totalBytes
        self.diskFreeBytes = diskFreeBytes
        self.diskTotalBytes = diskTotalBytes
        self.limitBytes = limitBytes
        self.lowDisk = lowDisk
        self.biggestSongs = biggestSongs
    }
}

public struct SongUsage: Codable, Sendable, Hashable, Identifiable {
    public var id: SongID
    public var title: String
    public var artist: String
    public var bytes: Int64
    public var lastPlayedAt: Date?
    public var pinned: Bool

    public init(id: SongID, title: String, artist: String, bytes: Int64, lastPlayedAt: Date?, pinned: Bool) {
        self.id = id
        self.title = title
        self.artist = artist
        self.bytes = bytes
        self.lastPlayedAt = lastPlayedAt
        self.pinned = pinned
    }
}

/// What to clear. Empty category means every rebuildable cache.
public struct ClearCacheRequest: Codable, Sendable, Hashable {
    public var category: String?
    public var songID: SongID?
    public var notPlayedForDays: Int?
    /// Only report what would be freed.
    public var dryRun: Bool

    public init(category: String? = nil, songID: SongID? = nil, notPlayedForDays: Int? = nil, dryRun: Bool = false) {
        self.category = category
        self.songID = songID
        self.notPlayedForDays = notPlayedForDays
        self.dryRun = dryRun
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        songID = try c.decodeIfPresent(SongID.self, forKey: .songID)
        notPlayedForDays = try c.decodeIfPresent(Int.self, forKey: .notPlayedForDays)
        dryRun = (try? c.decode(Bool.self, forKey: .dryRun)) ?? false
    }
}

public struct ClearCacheResult: Codable, Sendable, Hashable {
    public var freedBytes: Int64
    public var songs: Int

    public init(freedBytes: Int64, songs: Int) {
        self.freedBytes = freedBytes
        self.songs = songs
    }
}

public struct PadInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var model: String?
    public var role: PadRole
    public var pairedAt: Date
    public var lastSeenAt: Date?
    public var connected: Bool
    public var battery: Double?

    public init(id: String, name: String, model: String?, role: PadRole, pairedAt: Date, lastSeenAt: Date?, connected: Bool) {
        self.id = id
        self.name = name
        self.model = model
        self.role = role
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.connected = connected
    }
}

public struct ModelInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var task: String
    public var bytes: Int64
    public init(name: String, task: String, bytes: Int64) { self.name = name; self.task = task; self.bytes = bytes }
}

public struct OwnerUnlock: Codable, Sendable {
    public var pin: String
    public init(pin: String) { self.pin = pin }
}

public struct OwnerSession: Codable, Sendable {
    public var ownerToken: String
    public var expiresAt: Date
    public init(ownerToken: String, expiresAt: Date) {
        self.ownerToken = ownerToken
        self.expiresAt = expiresAt
    }
}

/// Owner-only data a host pad sees after entering the PIN.
public struct OwnerOverview: Codable, Sendable {
    public var pinRequired: Bool
    public var services: ServiceSettings
    public var storage: StorageReport
    public var pads: [PadInfo]
    public var processingPaused: Bool

    public init(pinRequired: Bool, services: ServiceSettings, storage: StorageReport, pads: [PadInfo], processingPaused: Bool) {
        self.pinRequired = pinRequired
        self.services = services
        self.storage = storage
        self.pads = pads
        self.processingPaused = processingPaused
    }
}

public struct RecordingInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: Int64
    public var songID: SongID?
    public var songTitle: String
    public var artist: String
    public var singers: [Singer]
    public var recordedAt: Date
    public var durationMs: Int
    public var score: Int?
    public var kept: Bool
    public var shareToken: String

    public init(id: Int64, songID: SongID?, songTitle: String, artist: String, singers: [Singer], recordedAt: Date, durationMs: Int, score: Int?, kept: Bool, shareToken: String) {
        self.id = id
        self.songID = songID
        self.songTitle = songTitle
        self.artist = artist
        self.singers = singers
        self.recordedAt = recordedAt
        self.durationMs = durationMs
        self.score = score
        self.kept = kept
        self.shareToken = shareToken
    }
}
