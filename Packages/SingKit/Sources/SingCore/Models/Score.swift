import Foundation

public struct ScoreCategory: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var value: Int
    public var note: String
    public var id: String { name }

    public init(name: String, value: Int, note: String) {
        self.name = name
        self.value = value
        self.note = note
    }
}

/// What the TV and the singer's pad show when a song ends.
public struct PerformanceResult: Codable, Sendable, Hashable {
    public var entryID: String
    public var songTitle: String
    public var artist: String
    public var singers: [Singer]
    public var total: Int?
    public var grade: String?
    public var title: String
    public var comment: String
    public var categories: [ScoreCategory]
    public var badges: [String]
    public var leaderboard: [RankedName]
    public var endedAt: Date
    /// Set once the performance recording is mixed.
    public var recordingID: Int64?
    /// A link anyone on the same Wi-Fi can open to listen.
    public var shareURL: String?

    public init(entryID: String, songTitle: String, artist: String, singers: [Singer], total: Int?, grade: String?, title: String, comment: String, categories: [ScoreCategory], badges: [String], leaderboard: [RankedName], endedAt: Date = .now) {
        self.entryID = entryID
        self.songTitle = songTitle
        self.artist = artist
        self.singers = singers
        self.total = total
        self.grade = grade
        self.title = title
        self.comment = comment
        self.categories = categories
        self.badges = badges
        self.leaderboard = leaderboard
        self.endedAt = endedAt
    }
}

/// Collects mic pitch frames during a song and turns them into a score against the reference melody.
public struct ScoreKeeper: Sendable {
    struct Frame { var time: Double; var midi: Float?; var level: Float }
    private var frames: [Frame] = []

    public init() {}

    public mutating func add(time: TimeInterval, sungMidi: Float?, level: Float) {
        frames.append(Frame(time: time, midi: sungMidi, level: level))
    }

    public var voicedCount: Int { frames.filter { $0.midi != nil }.count }

    public func result(track: PitchTrack?, upTo end: TimeInterval) -> (total: Int, categories: [ScoreCategory])? {
        guard let track, voicedCount >= 20 else { return nil }
        let notes = track.notes.filter { $0.end <= end + 0.5 }
        guard notes.count >= 3 else { return nil }

        var targetFrames = 0, hits = 0
        var deviations: [Double] = []
        var onsetScores: [Double] = []
        var covered = 0
        var noteIdx = 0
        var perNote: [Int: [Float]] = [:]
        for f in frames {
            while noteIdx < notes.count, notes[noteIdx].end < f.time { noteIdx += 1 }
            guard noteIdx < notes.count, notes[noteIdx].start <= f.time else { continue }
            targetFrames += 1
            guard let m = f.midi else { continue }
            let target = notes[noteIdx].midi(at: f.time)
            let folded = PitchTrack.foldOctave(m, toward: target)
            if abs(folded - target) < 1 { hits += 1 }
            perNote[noteIdx, default: []].append(folded - target)
        }
        for (i, n) in notes.enumerated() {
            let inNote = frames.filter { $0.time >= n.start - 0.3 && $0.time <= n.end }
            let voiced = inNote.filter { $0.midi != nil }
            if Double(voiced.count) >= Double(max(1, inNote.count)) * 0.3 { covered += 1 }
            if let first = voiced.first { onsetScores.append(max(0, 1 - abs(first.time - n.start) / 0.35)) }
            if let d = perNote[i], d.count >= 3 {
                let mean = d.reduce(0, +) / Float(d.count)
                let v = d.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(d.count)
                deviations.append(Double(v.squareRoot()))
            }
        }
        let levels = frames.filter { $0.midi != nil }.map { Double($0.level) }
        let mean = levels.reduce(0, +) / Double(max(levels.count, 1))
        let sd = (levels.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(levels.count, 1))).squareRoot()
        let cv = mean > 0 ? sd / mean : 0

        let pitch = Double(hits) / Double(max(targetFrames, 1))
        let rhythm = onsetScores.isEmpty ? 0 : onsetScores.reduce(0, +) / Double(onsetScores.count)
        let stability = deviations.isEmpty ? 0.5 : max(0, 1 - (deviations.reduce(0, +) / Double(deviations.count)) / 1.2)
        let dynamics = 0.55 + 0.45 * min(1, cv / 0.45)
        let coverage = Double(covered) / Double(notes.count)
        func pct(_ x: Double) -> Int { Int((max(0, min(1, x)) * 100).rounded()) }
        let cats = [
            ScoreCategory(name: "Pitch", value: pct(pitch), note: pitch > 0.8 ? "Right on the notes" : pitch > 0.55 ? "Mostly in tune" : "Keep an ear on the melody"),
            ScoreCategory(name: "Rhythm", value: pct(rhythm), note: rhythm > 0.75 ? "Locked to the beat" : "A little off the beat at times"),
            ScoreCategory(name: "Stability", value: pct(stability), note: stability > 0.75 ? "Steady held notes" : "Some wobble on long notes"),
            ScoreCategory(name: "Dynamics", value: pct(dynamics), note: dynamics > 0.8 ? "Lots of light and shade" : "Try more contrast"),
            ScoreCategory(name: "Coverage", value: pct(coverage), note: "Sang \(covered) of \(notes.count) notes"),
        ]
        let total = 0.4 * pitch + 0.2 * rhythm + 0.15 * stability + 0.1 * dynamics + 0.15 * coverage
        return (pct(total), cats)
    }

    public static func grade(_ total: Int) -> String {
        switch total {
        case 95...: "S"
        case 85..<95: "A"
        case 70..<85: "B"
        case 55..<70: "C"
        default: "D"
        }
    }

    public static func title(for categories: [ScoreCategory]) -> String {
        guard let best = categories.max(by: { $0.value < $1.value }) else { return "Bravo!" }
        switch best.name {
        case "Pitch": return "Pitch perfect"
        case "Rhythm": return "Rhythm machine"
        case "Stability": return "Rock steady"
        case "Dynamics": return "Full of feeling"
        default: return "Never missed a note"
        }
    }
}
