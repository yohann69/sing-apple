import Foundation

/// Every user-facing toggle lives here. The Mac owns it and pushes it to every pad.
public struct SingSettings: Codable, Sendable, Hashable {
    public var tv = TVDisplaySettings()
    public var playback = PlaybackSettings()
    public var queue = QueueSettings()
    public var theme = ThemeSettings()
    public var services = ServiceSettings()
    public var storage = StorageSettings()
    public var system = SystemSettings()
    public var network = NetworkSettings()
    public var privacy = PrivacySettings()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tv = (try? c.decode(TVDisplaySettings.self, forKey: .tv)) ?? TVDisplaySettings()
        playback = (try? c.decode(PlaybackSettings.self, forKey: .playback)) ?? PlaybackSettings()
        queue = (try? c.decode(QueueSettings.self, forKey: .queue)) ?? QueueSettings()
        theme = (try? c.decode(ThemeSettings.self, forKey: .theme)) ?? ThemeSettings()
        services = (try? c.decode(ServiceSettings.self, forKey: .services)) ?? ServiceSettings()
        storage = (try? c.decode(StorageSettings.self, forKey: .storage)) ?? StorageSettings()
        system = (try? c.decode(SystemSettings.self, forKey: .system)) ?? SystemSettings()
        network = (try? c.decode(NetworkSettings.self, forKey: .network)) ?? NetworkSettings()
        privacy = (try? c.decode(PrivacySettings.self, forKey: .privacy)) ?? PrivacySettings()
    }
}

public struct TVDisplaySettings: Codable, Sendable, Hashable {
    public var showPreviousLine = true
    public var showNextLine = true
    public var showBackingVocals = true
    public var showSingerNames = true
    public var showSongInfo = true
    public var showUpNext = true
    public var showProgress = true
    public var showPitchGuide = true
    public var showLiveScore = true
    public var showCountdown = true
    public var showJoinQR = true
    public var showTranslation = false
    /// Language the TV translates lyrics into, as an ISO code ("fr", "en"…); nil means off.
    public var translationLanguage: String?
    public var showScoreReveal = true
    public var showScoreDetails = true
    public var showConfetti = true
    /// Tonight's top scores between songs.
    public var showLeaderboard = true
    public var estimatedWordWipe = true
    public var resultSeconds: Double = 10
    public var lyricSize: Double = 96
    public var backgroundSpeed: Double = 28
    public var background: TVBackground = .artworkBlobs

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = TVDisplaySettings.defaults
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decode(T.self, forKey: k)) ?? fallback }
        showPreviousLine = v(.showPreviousLine, d.showPreviousLine)
        showNextLine = v(.showNextLine, d.showNextLine)
        showBackingVocals = v(.showBackingVocals, d.showBackingVocals)
        showSingerNames = v(.showSingerNames, d.showSingerNames)
        showSongInfo = v(.showSongInfo, d.showSongInfo)
        showUpNext = v(.showUpNext, d.showUpNext)
        showProgress = v(.showProgress, d.showProgress)
        showPitchGuide = v(.showPitchGuide, d.showPitchGuide)
        showLiveScore = v(.showLiveScore, d.showLiveScore)
        showCountdown = v(.showCountdown, d.showCountdown)
        showJoinQR = v(.showJoinQR, d.showJoinQR)
        showTranslation = v(.showTranslation, d.showTranslation)
        translationLanguage = try? c.decodeIfPresent(String.self, forKey: .translationLanguage)
        showScoreReveal = v(.showScoreReveal, d.showScoreReveal)
        showScoreDetails = v(.showScoreDetails, d.showScoreDetails)
        showConfetti = v(.showConfetti, d.showConfetti)
        showLeaderboard = v(.showLeaderboard, d.showLeaderboard)
        estimatedWordWipe = v(.estimatedWordWipe, d.estimatedWordWipe)
        lyricSize = v(.lyricSize, d.lyricSize)
        resultSeconds = max(7, v(.resultSeconds, d.resultSeconds))
        backgroundSpeed = v(.backgroundSpeed, d.backgroundSpeed)
        background = v(.background, d.background)
    }

    static let defaults = TVDisplaySettings()
}

public enum TVBackground: String, Codable, Sendable, CaseIterable {
    case artworkBlobs
    case artwork
    case plain
}

public struct PlaybackSettings: Codable, Sendable, Hashable {
    public var defaultGuideVocal: Double = 0.0
    public var countdownBetweenSongs = true
    public var autoAdvance = true
    public var micEnabled = true
    public var micGain: Double = 0.8
    public var micReverb: Double = 0.35
    public var musicVolume: Double = 0.9
    public var playOriginalWhenNotReady = false
    /// One of `MicPreset` raw values.
    public var micPreset = MicPreset.hall.rawValue
    public var micEcho: Double = 0
    /// Ducks the mics when a howl builds up.
    public var feedbackProtection = true
    /// Evens out loudness between songs.
    public var normalizeLoudness = true
    /// "easy", "normal" or "hard": how close to the note still counts.
    public var difficulty = "normal"
    /// Record each performance (music plus voice) for replay and sharing.
    public var recordPerformances = false
    /// Recordings older than this are deleted unless kept. 0 keeps them forever.
    public var keepRecordingsDays: Double = 30

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = PlaybackSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decode(T.self, forKey: k)) ?? fallback }
        defaultGuideVocal = v(.defaultGuideVocal, d.defaultGuideVocal)
        countdownBetweenSongs = v(.countdownBetweenSongs, d.countdownBetweenSongs)
        autoAdvance = v(.autoAdvance, d.autoAdvance)
        micEnabled = v(.micEnabled, d.micEnabled)
        micGain = v(.micGain, d.micGain)
        micReverb = v(.micReverb, d.micReverb)
        musicVolume = v(.musicVolume, d.musicVolume)
        playOriginalWhenNotReady = v(.playOriginalWhenNotReady, d.playOriginalWhenNotReady)
        micPreset = v(.micPreset, d.micPreset)
        micEcho = v(.micEcho, d.micEcho)
        feedbackProtection = v(.feedbackProtection, d.feedbackProtection)
        normalizeLoudness = v(.normalizeLoudness, d.normalizeLoudness)
        difficulty = v(.difficulty, d.difficulty)
        recordPerformances = v(.recordPerformances, d.recordPerformances)
        keepRecordingsDays = v(.keepRecordingsDays, d.keepRecordingsDays)
    }
}

public enum MicPreset: String, Codable, Sendable, CaseIterable {
    case natural, studio, hall, stadium, echo, radio

    public var name: String {
        switch self {
        case .natural: "Natural"
        case .studio: "Studio"
        case .hall: "Concert hall"
        case .stadium: "Stadium"
        case .echo: "Echo"
        case .radio: "Radio"
        }
    }
}

public struct QueueSettings: Codable, Sendable, Hashable {
    /// Singers take turns: a new song goes after everyone else's next song.
    public var fairRotation = true
    /// When the queue runs dry, queue a crowd favourite as an open mic.
    public var autoFill = false
    public var guestsCanQueue = true
    public var guestsCanRemoveOwn = true
    public var maxQueuedPerSinger = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = QueueSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decode(T.self, forKey: k)) ?? fallback }
        fairRotation = v(.fairRotation, d.fairRotation)
        autoFill = v(.autoFill, d.autoFill)
        guestsCanQueue = v(.guestsCanQueue, d.guestsCanQueue)
        guestsCanRemoveOwn = v(.guestsCanRemoveOwn, d.guestsCanRemoveOwn)
        maxQueuedPerSinger = v(.maxQueuedPerSinger, d.maxQueuedPerSinger)
    }
}

public struct ThemeSettings: Codable, Sendable, Hashable {
    public var preset = "ember"

    public init() {}
}

public struct ServiceSettings: Codable, Sendable, Hashable {
    public var singAPIBase = "https://lyrics-api-production-b10f.up.railway.app"
    public var singAPIEnabled = true
    public var lrclibEnabled = true
    public var neteaseEnabled = true
    public var kugouEnabled = true
    public var aiAlignmentEnabled = true
    public var catalogSearchEnabled = true
    public var timeoutSeconds: Double = 6

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = ServiceSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decode(T.self, forKey: k)) ?? fallback }
        singAPIBase = v(.singAPIBase, d.singAPIBase)
        singAPIEnabled = v(.singAPIEnabled, d.singAPIEnabled)
        lrclibEnabled = v(.lrclibEnabled, d.lrclibEnabled)
        neteaseEnabled = v(.neteaseEnabled, d.neteaseEnabled)
        kugouEnabled = v(.kugouEnabled, d.kugouEnabled)
        aiAlignmentEnabled = v(.aiAlignmentEnabled, d.aiAlignmentEnabled)
        catalogSearchEnabled = v(.catalogSearchEnabled, d.catalogSearchEnabled)
        timeoutSeconds = v(.timeoutSeconds, d.timeoutSeconds)
    }
}

public struct StorageSettings: Codable, Sendable, Hashable {
    /// Cap on everything Sing! keeps in its caches, in GB. 0 means no cap.
    public var limitGB: Double = 0
    /// Cap on separated stems alone, in GB. 0 means no cap.
    public var stemsLimitGB: Double = 0
    /// Warn when the disk has less free space than this, in GB.
    public var lowDiskWarningGB: Double = 10
    /// Over a cap, delete the stems of songs not played for the longest time (pinned and favorite songs stay).
    public var autoFree = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = StorageSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decode(T.self, forKey: k)) ?? fallback }
        limitGB = v(.limitGB, d.limitGB)
        stemsLimitGB = v(.stemsLimitGB, d.stemsLimitGB)
        lowDiskWarningGB = v(.lowDiskWarningGB, d.lowDiskWarningGB)
        autoFree = v(.autoFree, d.autoFree)
    }
}

public struct SystemSettings: Codable, Sendable, Hashable {
    /// Separate and analyse the whole library in the background, not only queued songs.
    public var processLibraryInBackground = true
    /// Stop background work while someone is singing so playback never stutters.
    public var pauseProcessingWhileSinging = true
    /// Pause after this many minutes of continuous processing to let the Mac cool down. 0 means never.
    public var restAfterMinutes: Double = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = SystemSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decode(T.self, forKey: k)) ?? fallback }
        processLibraryInBackground = v(.processLibraryInBackground, d.processLibraryInBackground)
        pauseProcessingWhileSinging = v(.pauseProcessingWhileSinging, d.pauseProcessingWhileSinging)
        restAfterMinutes = v(.restAfterMinutes, d.restAfterMinutes)
    }
}

public struct NetworkSettings: Codable, Sendable, Hashable {
    /// Name pads see on the network. Empty uses the Mac's name.
    public var bonjourName = ""
    /// Port for pads; the live socket uses the next one. Applies after a restart.
    public var port = 47800
    /// 0 means no limit.
    public var maxPads = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = NetworkSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decode(T.self, forKey: k)) ?? fallback }
        bonjourName = v(.bonjourName, d.bonjourName)
        port = v(.port, d.port)
        maxPads = v(.maxPads, d.maxPads)
    }
}

public struct PrivacySettings: Codable, Sendable, Hashable {
    /// Hides explicit songs from search and the catalog, and songs the host marked as not for kids.
    public var familyMode = false
    /// Save plays, scores and stats. Off means tonight leaves no trace (and nothing is recorded).
    public var keepHistory = true
    public var guestsSeeStats = true
    public var guestsCanRequest = true
    public var guestsCanCreateSingers = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = PrivacySettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decode(T.self, forKey: k)) ?? fallback }
        familyMode = v(.familyMode, d.familyMode)
        keepHistory = v(.keepHistory, d.keepHistory)
        guestsSeeStats = v(.guestsSeeStats, d.guestsSeeStats)
        guestsCanRequest = v(.guestsCanRequest, d.guestsCanRequest)
        guestsCanCreateSingers = v(.guestsCanCreateSingers, d.guestsCanCreateSingers)
    }
}

/// Per-song choices the host can edit: timing, mix, key, tempo and family visibility.
public struct SongSettings: Codable, Sendable, Hashable {
    public var lyricOffsetMs: Int
    public var defaultGuideVocal: Double?
    public var keyShift: Int
    public var tempo: Double
    public var hiddenInFamilyMode: Bool
    public var pinned: Bool

    public init(lyricOffsetMs: Int = 0, defaultGuideVocal: Double? = nil, keyShift: Int = 0, tempo: Double = 1, hiddenInFamilyMode: Bool = false, pinned: Bool = false) {
        self.lyricOffsetMs = lyricOffsetMs
        self.defaultGuideVocal = defaultGuideVocal
        self.keyShift = keyShift
        self.tempo = tempo
        self.hiddenInFamilyMode = hiddenInFamilyMode
        self.pinned = pinned
    }
}
