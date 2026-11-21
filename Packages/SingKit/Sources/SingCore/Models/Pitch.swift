import Foundation

/// A straight piece of the melody: flat when `endMidi` is nil, a slide (diagonal) otherwise.
public struct PitchNote: Codable, Sendable, Hashable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var midi: Float
    public var endMidi: Float?

    public init(start: TimeInterval, end: TimeInterval, midi: Float, endMidi: Float? = nil) {
        self.start = start
        self.end = end
        self.midi = midi
        self.endMidi = endMidi
    }

    public var finalMidi: Float { endMidi ?? midi }

    public func midi(at t: TimeInterval) -> Float {
        guard let e = endMidi, end > start else { return midi }
        let f = Float(max(0, min(1, (t - start) / (end - start))))
        return midi + (e - midi) * f
    }
}

/// The reference melody of a song, extracted once from the separated vocals.
public struct PitchTrack: Codable, Sendable, Hashable {
    public var version: Int
    public var notes: [PitchNote]
    public var low: Float
    public var high: Float

    public static let currentVersion = 2

    public init(version: Int = 1, notes: [PitchNote]) {
        self.version = version
        self.notes = notes
        let sorted = (notes.map(\.midi) + notes.compactMap(\.endMidi)).sorted()
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

    /// The melody's pitch at a time, following slides.
    public func target(at t: TimeInterval) -> Float? { note(at: t)?.midi(at: t) }

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

    /// A calmer version for display: close notes merge into longer bars that follow the melody's trend.
    public func simplified(maxGap: TimeInterval = 0.3, tolerance: Float = 2.5, minLength: TimeInterval = 0.45) -> PitchTrack {
        var merged: [PitchNote] = []
        var weight: [Double] = []
        for n in notes {
            let d = n.end - n.start
            if let last = merged.last, n.start - last.end <= maxGap, abs(n.midi - last.midi) <= tolerance {
                let w = weight[weight.count - 1]
                let m = Float((Double(last.midi) * w + Double(n.midi) * d) / (w + d))
                merged[merged.count - 1] = PitchNote(start: last.start, end: n.end, midi: m)
                weight[weight.count - 1] = w + d
            } else {
                merged.append(n)
                weight.append(d)
            }
        }
        let kept = merged.filter { $0.end - $0.start >= minLength }.map { PitchNote(start: $0.start, end: $0.end, midi: $0.midi.rounded()) }
        var out = PitchTrack(version: version, notes: kept)
        out.low = low
        out.high = high
        return out
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
