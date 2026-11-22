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
    }
}

public struct QueueSettings: Codable, Sendable, Hashable {
    public var guestsCanQueue = true
    public var guestsCanRemoveOwn = true
    public var maxQueuedPerSinger = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = QueueSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decode(T.self, forKey: k)) ?? fallback }
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
