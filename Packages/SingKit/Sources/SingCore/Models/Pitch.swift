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

    /// The display version of a detailed contour: each phrase is averaged over ~0.35 s windows,
    /// then reduced to a few flat notes and slides so it shows the shape, not every syllable.
    public func coarse(window: TimeInterval = 0.35, epsilon: Float = 1.1, minPhrase: TimeInterval = 0.3) -> PitchTrack {
        var phrases: [[PitchNote]] = []
        for n in notes {
            if let last = phrases.last?.last, n.start - last.end < 0.2 { phrases[phrases.count - 1].append(n) } else { phrases.append([n]) }
        }
        var out: [PitchNote] = []
        for ph in phrases {
            let start = ph[0].start, end = ph[ph.count - 1].end
            guard end - start >= minPhrase else { continue }
            var pts: [(Double, Float)] = []
            var t = start
            while t < end {
                let w = min(window, end - t)
                var samples: [Float] = []
                var u = t
                while u < t + w {
                    if let n = ph.first(where: { $0.start <= u && $0.end >= u }) { samples.append(n.midi(at: u)) }
                    u += 0.02
                }
                if !samples.isEmpty {
                    samples.sort()
                    pts.append((t + w / 2, samples[samples.count / 2]))
                }
                t += w
            }
            guard pts.count >= 1 else { continue }
            if pts.count == 1 {
                out.append(PitchNote(start: start, end: end, midi: pts[0].1.rounded()))
                continue
            }
            pts[0].0 = start
            pts[pts.count - 1].0 = end
            let kept = Self.rdp(pts, epsilon: epsilon)
            for k in 0..<(kept.count - 1) {
                let a = kept[k], b = kept[k + 1]
                let flat = abs(b.1 - a.1) < 0.8
                let m = flat ? ((a.1 + b.1) / 2).rounded() : a.1
                out.append(PitchNote(start: a.0, end: b.0, midi: m, endMidi: flat ? nil : b.1))
            }
        }
        var t = PitchTrack(version: version, notes: out)
        t.low = low
        t.high = high
        return t
    }

    static func rdp(_ pts: [(Double, Float)], epsilon: Float) -> [(Double, Float)] {
        guard pts.count > 2 else { return pts }
        let a = pts[0], b = pts[pts.count - 1]
        var maxD: Float = 0
        var idx = 0
        for i in 1..<(pts.count - 1) {
            let f = Float((pts[i].0 - a.0) / max(b.0 - a.0, 1e-6))
            let d = abs(pts[i].1 - (a.1 + (b.1 - a.1) * f))
            if d > maxD { maxD = d; idx = i }
        }
        guard maxD > epsilon else { return [a, b] }
        return Array(rdp(Array(pts[0...idx]), epsilon: epsilon).dropLast()) + rdp(Array(pts[idx...]), epsilon: epsilon)
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
