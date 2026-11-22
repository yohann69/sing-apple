import Foundation

public enum SingProtocol {
    public static let version = 1
    public static let minimumSupportedVersion = 1
    public static let bonjourType = "_sing._tcp"
    public static let defaultPort = 47800

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }
}

public enum PadRole: String, Codable, Sendable {
    case host
    case guest
}

// MARK: HTTP bodies

public struct ServerInfo: Codable, Sendable, Hashable {
    public var name: String
    public var protocolVersion: Int
    public var minimumProtocolVersion: Int
    public var appVersion: String
    public var livePort: Int?

    public init(name: String, protocolVersion: Int = SingProtocol.version, minimumProtocolVersion: Int = SingProtocol.minimumSupportedVersion, appVersion: String, livePort: Int? = nil) {
        self.name = name
        self.livePort = livePort
        self.protocolVersion = protocolVersion
        self.minimumProtocolVersion = minimumProtocolVersion
        self.appVersion = appVersion
    }
}

public struct PairRequest: Codable, Sendable {
    public var code: String
    public var deviceName: String
    public var deviceModel: String
    public var protocolVersion: Int

    public init(code: String, deviceName: String, deviceModel: String, protocolVersion: Int = SingProtocol.version) {
        self.code = code
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.protocolVersion = protocolVersion
    }
}

public struct PairResponse: Codable, Sendable {
    public var token: String
    public var padID: String
    public var role: PadRole
    public var server: ServerInfo

    public init(token: String, padID: String, role: PadRole, server: ServerInfo) {
        self.token = token
        self.padID = padID
        self.role = role
        self.server = server
    }
}

public struct SearchResponse: Codable, Sendable {
    public var songs: [SongSummary]
    public var total: Int
    /// Songs found in public catalogs that are not in the library yet.
    public var catalog: [CatalogTrack]

    public init(songs: [SongSummary], total: Int, catalog: [CatalogTrack] = []) {
        self.songs = songs
        self.total = total
        self.catalog = catalog
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        songs = try c.decode([SongSummary].self, forKey: .songs)
        total = try c.decode(Int.self, forKey: .total)
        catalog = (try? c.decode([CatalogTrack].self, forKey: .catalog)) ?? []
    }
}

public struct SearchFilters: Codable, Sendable, Hashable {
    public var readyOnly = false
    public var duetOnly = false
    public var decade: Int?
    public var genre: String?
    public var language: String?
    /// Only songs this singer marked as favorite.
    public var favoritesOf: SingerID?

    public init(readyOnly: Bool = false, duetOnly: Bool = false, decade: Int? = nil, genre: String? = nil, language: String? = nil, favoritesOf: SingerID? = nil) {
        self.favoritesOf = favoritesOf
        self.readyOnly = readyOnly
        self.duetOnly = duetOnly
        self.decade = decade
        self.genre = genre
        self.language = language
    }
}

public struct ErrorBody: Codable, Sendable, Error {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: Live state over WebSocket

/// Everything a pad needs to render, sent in full on connect and on each change.
public struct LiveState: Codable, Sendable, Hashable {
    public var nowPlaying: NowPlaying
    public var queue: [QueueEntry]
    public var settings: SingSettings
    public var singers: [Singer]
    public var session: SessionInfo?
    public var requests: [SongRequest] = []
    public var mic: MicStatus? = nil
    public var result: PerformanceResult? = nil
    /// Tonight's best scores, for the TV between songs.
    public var leaderboard: [RankedName]? = nil
    /// Set for a while after the host ends the party.
    public var recap: PartyRecap? = nil
    /// Separation progress keyed by song id as a string, so JSON keeps an object.
    public var preparingByID: [String: Double]

    public var preparing: [SongID: Double] {
        Dictionary(uniqueKeysWithValues: preparingByID.compactMap { k, v in SongID(k).map { ($0, v) } })
    }

    public init(nowPlaying: NowPlaying = NowPlaying(), queue: [QueueEntry] = [], settings: SingSettings = SingSettings(), singers: [Singer] = [], session: SessionInfo? = nil, preparing: [SongID: Double] = [:], requests: [SongRequest] = [], mic: MicStatus? = nil, result: PerformanceResult? = nil) {
        self.result = result
        self.requests = requests
        self.mic = mic
        self.nowPlaying = nowPlaying
        self.queue = queue
        self.settings = settings
        self.singers = singers
        self.session = session
        self.preparingByID = Dictionary(uniqueKeysWithValues: preparing.map { (String($0.key), $0.value) })
    }
}

public struct SessionInfo: Codable, Sendable, Hashable {
    public var id: Int64
    public var name: String?
    public var startedAt: Date
    public var playCount: Int

    public init(id: Int64, name: String?, startedAt: Date, playCount: Int) {
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.playCount = playCount
    }
}

public enum ServerMessage: Sendable {
    case hello(Hello)
    case state(LiveState)
    case position(Position)
    case progress(Progress)
    case youreUp(YoureUp)
    case toast(Toast)
    case error(ErrorBody)

    public struct Hello: Codable, Sendable { public var server: ServerInfo; public var role: PadRole; public var padID: String
        public init(server: ServerInfo, role: PadRole, padID: String) { self.server = server; self.role = role; self.padID = padID } }
    public struct Position: Codable, Sendable { public var positionMs: Int; public var at: Date; public var lineIndex: Int?
        public init(positionMs: Int, at: Date, lineIndex: Int?) { self.positionMs = positionMs; self.at = at; self.lineIndex = lineIndex } }
    public struct Progress: Codable, Sendable { public var songID: SongID; public var progress: Double; public var readiness: Readiness
        public init(songID: SongID, progress: Double, readiness: Readiness) { self.songID = songID; self.progress = progress; self.readiness = readiness } }
    public struct YoureUp: Codable, Sendable { public var songsAway: Int; public var entryID: String; public var singerID: SingerID
        public init(songsAway: Int, entryID: String, singerID: SingerID) { self.songsAway = songsAway; self.entryID = entryID; self.singerID = singerID } }
    public struct Toast: Codable, Sendable { public var message: String
        public init(message: String) { self.message = message } }
}

extension ServerMessage: Codable {
    private enum Keys: String, CodingKey { case type, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "hello": self = .hello(try c.decode(Hello.self, forKey: .data))
        case "state": self = .state(try c.decode(LiveState.self, forKey: .data))
        case "position": self = .position(try c.decode(Position.self, forKey: .data))
        case "progress": self = .progress(try c.decode(Progress.self, forKey: .data))
        case "youreUp": self = .youreUp(try c.decode(YoureUp.self, forKey: .data))
        case "toast": self = .toast(try c.decode(Toast.self, forKey: .data))
        case "error": self = .error(try c.decode(ErrorBody.self, forKey: .data))
        case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown type \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .hello(let v): try c.encode("hello", forKey: .type); try c.encode(v, forKey: .data)
        case .state(let v): try c.encode("state", forKey: .type); try c.encode(v, forKey: .data)
        case .position(let v): try c.encode("position", forKey: .type); try c.encode(v, forKey: .data)
        case .progress(let v): try c.encode("progress", forKey: .type); try c.encode(v, forKey: .data)
        case .youreUp(let v): try c.encode("youreUp", forKey: .type); try c.encode(v, forKey: .data)
        case .toast(let v): try c.encode("toast", forKey: .type); try c.encode(v, forKey: .data)
        case .error(let v): try c.encode("error", forKey: .type); try c.encode(v, forKey: .data)
        }
    }
}

public enum TransportCommand: String, Codable, Sendable {
    case play
    case pause
    case skip
    case restart
    case stop
}

public enum ClientMessage: Sendable {
    case auth(token: String)
    case enqueue(Enqueue)
    case remove(entryID: String)
    case move(Move)
    case transport(TransportCommand)
    case seek(positionMs: Int)
    case setGuideVocal(Double)
    case updateSettings(SingSettings)
    case request(Request)
    case dismissRequest(id: String)
    case setKey(Int)
    case setTempo(Double)
    case setMicPreset(String)
    /// Moves the current song's lyrics earlier (negative) or later, and remembers it for the song.
    case setLyricOffset(ms: Int)
    case ping

    public struct Enqueue: Codable, Sendable { public var songID: SongID; public var singerIDs: [SingerID]; public var playNext: Bool
        public init(songID: SongID, singerIDs: [SingerID], playNext: Bool = false) { self.songID = songID; self.singerIDs = singerIDs; self.playNext = playNext } }
    public struct Request: Codable, Sendable { public var track: CatalogTrack; public var singerIDs: [SingerID]
        public init(track: CatalogTrack, singerIDs: [SingerID]) { self.track = track; self.singerIDs = singerIDs } }
    public struct Move: Codable, Sendable { public var entryID: String; public var toIndex: Int
        public init(entryID: String, toIndex: Int) { self.entryID = entryID; self.toIndex = toIndex } }
    private struct EntryRef: Codable { var entryID: String }
    private struct Auth: Codable { var token: String }
    private struct Seek: Codable { var positionMs: Int }
    private struct Value: Codable { var value: Double }
    private struct Command: Codable { var command: TransportCommand }
    private struct Semitones: Codable { var semitones: Int }
    private struct Preset: Codable { var preset: String }
    private struct Offset: Codable { var ms: Int }
}

extension ClientMessage: Codable {
    private enum Keys: String, CodingKey { case type, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "auth": self = .auth(token: try c.decode(Auth.self, forKey: .data).token)
        case "enqueue": self = .enqueue(try c.decode(Enqueue.self, forKey: .data))
        case "remove": self = .remove(entryID: try c.decode(EntryRef.self, forKey: .data).entryID)
        case "move": self = .move(try c.decode(Move.self, forKey: .data))
        case "transport": self = .transport(try c.decode(Command.self, forKey: .data).command)
        case "seek": self = .seek(positionMs: try c.decode(Seek.self, forKey: .data).positionMs)
        case "setGuideVocal": self = .setGuideVocal(try c.decode(Value.self, forKey: .data).value)
        case "updateSettings": self = .updateSettings(try c.decode(SingSettings.self, forKey: .data))
        case "request": self = .request(try c.decode(Request.self, forKey: .data))
        case "dismissRequest": self = .dismissRequest(id: try c.decode(EntryRef.self, forKey: .data).entryID)
        case "setKey": self = .setKey(try c.decode(Semitones.self, forKey: .data).semitones)
        case "setTempo": self = .setTempo(try c.decode(Value.self, forKey: .data).value)
        case "setMicPreset": self = .setMicPreset(try c.decode(Preset.self, forKey: .data).preset)
        case "setLyricOffset": self = .setLyricOffset(ms: try c.decode(Offset.self, forKey: .data).ms)
        case "ping": self = .ping
        case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown type \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .auth(let t): try c.encode("auth", forKey: .type); try c.encode(Auth(token: t), forKey: .data)
        case .enqueue(let v): try c.encode("enqueue", forKey: .type); try c.encode(v, forKey: .data)
        case .remove(let id): try c.encode("remove", forKey: .type); try c.encode(EntryRef(entryID: id), forKey: .data)
        case .move(let v): try c.encode("move", forKey: .type); try c.encode(v, forKey: .data)
        case .transport(let v): try c.encode("transport", forKey: .type); try c.encode(Command(command: v), forKey: .data)
        case .seek(let v): try c.encode("seek", forKey: .type); try c.encode(Seek(positionMs: v), forKey: .data)
        case .setGuideVocal(let v): try c.encode("setGuideVocal", forKey: .type); try c.encode(Value(value: v), forKey: .data)
        case .updateSettings(let v): try c.encode("updateSettings", forKey: .type); try c.encode(v, forKey: .data)
        case .request(let v): try c.encode("request", forKey: .type); try c.encode(v, forKey: .data)
        case .dismissRequest(let id): try c.encode("dismissRequest", forKey: .type); try c.encode(EntryRef(entryID: id), forKey: .data)
        case .setKey(let v): try c.encode("setKey", forKey: .type); try c.encode(Semitones(semitones: v), forKey: .data)
        case .setTempo(let v): try c.encode("setTempo", forKey: .type); try c.encode(Value(value: v), forKey: .data)
        case .setMicPreset(let v): try c.encode("setMicPreset", forKey: .type); try c.encode(Preset(preset: v), forKey: .data)
        case .setLyricOffset(let v): try c.encode("setLyricOffset", forKey: .type); try c.encode(Offset(ms: v), forKey: .data)
        case .ping: try c.encode("ping", forKey: .type)
        }
    }
}

public struct MicStatus: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable { case off, needsPermission, denied, silent, running, failed }
    public var state: State
    public var deviceName: String?
    public var level: Float
    public var message: String?

    public init(state: State, deviceName: String? = nil, level: Float = 0, message: String? = nil) {
        self.state = state
        self.deviceName = deviceName
        self.level = level
        self.message = message
    }
}
