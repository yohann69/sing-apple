import Foundation

public struct PitchNote: Codable, Sendable, Hashable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var midi: Float

    public init(start: TimeInterval, end: TimeInterval, midi: Float) {
        self.start = start
        self.end = end
        self.midi = midi
    }
}

/// The reference melody of a song, extracted once from the separated vocals.
public struct PitchTrack: Codable, Sendable, Hashable {
    public var version: Int
    public var notes: [PitchNote]
    public var low: Float
    public var high: Float

    public init(version: Int = 1, notes: [PitchNote]) {
        self.version = version
        self.notes = notes
        let sorted = notes.map(\.midi).sorted()
        low = sorted.isEmpty ? 48 : sorted[Int(Double(sorted.count - 1) * 0.03)] - 2
        high = sorted.isEmpty ? 72 : sorted[Int(Double(sorted.count - 1) * 0.97)] + 2
    }

    public func note(at t: TimeInterval) -> PitchNote? {
        var lo = 0, hi = notes.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if notes[mid].end < t { lo = mid + 1 } else if notes[mid].start > t { hi = mid - 1 } else { return notes[mid] }
        }
        return nil
    }

    public func notes(in range: ClosedRange<TimeInterval>) -> ArraySlice<PitchNote> {
        var lo = 0, hi = notes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if notes[mid].end < range.lowerBound { lo = mid + 1 } else { hi = mid }
        }
        var end = lo
        while end < notes.count, notes[end].start <= range.upperBound { end += 1 }
        return notes[lo..<end]
    }

    /// Octave-tolerant: moves a sung pitch by whole octaves to the octave closest to the target.
    public static func foldOctave(_ sung: Float, toward target: Float) -> Float {
        var s = sung
        while s - target > 6 { s -= 12 }
        while target - s > 6 { s += 12 }
        return s
    }
}

public struct LivePitchPoint: Sendable, Hashable {
    public var time: TimeInterval
    public var midi: Float
    public var onTarget: Bool

    public init(time: TimeInterval, midi: Float, onTarget: Bool) {
        self.time = time
        self.midi = midi
        self.onTarget = onTarget
    }
}
