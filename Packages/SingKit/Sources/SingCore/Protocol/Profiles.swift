import Foundation

/// What a singer chooses for themself; applied when one of their songs starts.
public struct SingerPrefs: Codable, Sendable, Hashable {
    public var hideScore = false
    public var hideFromLeaderboard = false
    public var hideStats = false
    public var micPreset: String?
    public var guideVocal: Double?
    /// Semitones added to every song they sing.
    public var keyOffset = 0
    /// Comfortable range in MIDI notes, learned from what they sing.
    public var rangeLow: Double?
    public var rangeHigh: Double?
    /// "name", "emoji" or "both" on the TV.
    public var nameStyle = "both"
    public var hasPIN = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = SingerPrefs()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decode(T.self, forKey: k)) ?? fallback }
        hideScore = v(.hideScore, d.hideScore)
        hideFromLeaderboard = v(.hideFromLeaderboard, d.hideFromLeaderboard)
        hideStats = v(.hideStats, d.hideStats)
        micPreset = try? c.decodeIfPresent(String.self, forKey: .micPreset)
        guideVocal = try? c.decodeIfPresent(Double.self, forKey: .guideVocal)
        keyOffset = v(.keyOffset, d.keyOffset)
        rangeLow = try? c.decodeIfPresent(Double.self, forKey: .rangeLow)
        rangeHigh = try? c.decodeIfPresent(Double.self, forKey: .rangeHigh)
        nameStyle = v(.nameStyle, d.nameStyle)
        hasPIN = v(.hasPIN, d.hasPIN)
    }
}

public struct SingerPINRequest: Codable, Sendable {
    public var pin: String?
    public init(pin: String?) { self.pin = pin }
}

public struct MergeSingers: Codable, Sendable {
    public var from: SingerID
    public var into: SingerID
    public init(from: SingerID, into: SingerID) { self.from = from; self.into = into }
}

/// A named set of settings ("Party", "Family", "Practice") the host switches in one tap.
public struct SettingsProfile: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var settings: SingSettings
    public init(name: String, settings: SingSettings) { self.name = name; self.settings = settings }
}

public struct SmartKey: Codable, Sendable, Hashable {
    public var semitones: Int
    public var reason: String
    public init(semitones: Int, reason: String) { self.semitones = semitones; self.reason = reason }
}

public struct AuditEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(at.timeIntervalSince1970)-\(action)" }
    public var at: Date
    public var who: String
    public var action: String
    public init(at: Date, who: String, action: String) { self.at = at; self.who = who; self.action = action }
}
