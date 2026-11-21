import Foundation

/// Every user-facing toggle lives here. The Mac owns it and pushes it to every pad.
public struct SingSettings: Codable, Sendable, Hashable {
    public var tv = TVDisplaySettings()
    public var playback = PlaybackSettings()
    public var queue = QueueSettings()
    public var theme = ThemeSettings()
    public var services = ServiceSettings()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tv = (try? c.decode(TVDisplaySettings.self, forKey: .tv)) ?? TVDisplaySettings()
        playback = (try? c.decode(PlaybackSettings.self, forKey: .playback)) ?? PlaybackSettings()
        queue = (try? c.decode(QueueSettings.self, forKey: .queue)) ?? QueueSettings()
        theme = (try? c.decode(ThemeSettings.self, forKey: .theme)) ?? ThemeSettings()
        services = (try? c.decode(ServiceSettings.self, forKey: .services)) ?? ServiceSettings()
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
    public var showScoreReveal = true
    public var showScoreDetails = true
    public var showConfetti = true
    public var estimatedWordWipe = true
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
        showScoreReveal = v(.showScoreReveal, d.showScoreReveal)
        showScoreDetails = v(.showScoreDetails, d.showScoreDetails)
        showConfetti = v(.showConfetti, d.showConfetti)
        estimatedWordWipe = v(.estimatedWordWipe, d.estimatedWordWipe)
        lyricSize = v(.lyricSize, d.lyricSize)
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
    public var timeoutSeconds: Double = 6

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = ServiceSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decode(T.self, forKey: k)) ?? fallback }
        singAPIBase = v(.singAPIBase, d.singAPIBase)
        singAPIEnabled = v(.singAPIEnabled, d.singAPIEnabled)
        lrclibEnabled = v(.lrclibEnabled, d.lrclibEnabled)
        timeoutSeconds = v(.timeoutSeconds, d.timeoutSeconds)
    }
}
