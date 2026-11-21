import Accelerate
import CoreML
import Foundation
import SingCore

/// Neural reference melody: CREPE on Core ML over the separated vocals, cleaned with the lyrics' timing,
/// then simplified into flat notes and slides.
public final class CrepeExtractor: @unchecked Sendable {
    static let rate: Double = 16000
    static let hop = 160
    static let frame = 1024
    static let batch = 256

    let model: MLModel

    public init(modelURL: URL) throws {
        var url = modelURL
        if url.pathExtension == "mlpackage" { url = try MLModel.compileModel(at: url) }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        model = try MLModel(contentsOf: url, configuration: config)
    }

    public struct Frame: Sendable { public var midi: Float; public var confidence: Float; public var rms: Float }

    /// One estimate every 10 ms.
    public func frames(_ mono: [Float]) throws -> [Frame] {
        let pad = Self.frame / 2
        var padded = [Float](repeating: 0, count: pad) + mono + [Float](repeating: 0, count: pad)
        let count = max(0, (padded.count - Self.frame) / Self.hop + 1)
        var out: [Frame] = []
        out.reserveCapacity(count)
        let input = try MLMultiArray(shape: [NSNumber(value: Self.batch), NSNumber(value: Self.frame)], dataType: .float32)
        let ptr = input.dataPointer.assumingMemoryBound(to: Float.self)
        var start = 0
        var rmsList: [Float] = []
        while start < count {
            let n = min(Self.batch, count - start)
            try padded.withUnsafeMutableBufferPointer { buf in
                for b in 0..<Self.batch {
                    let dst = ptr + b * Self.frame
                    guard b < n else { dst.update(repeating: 0, count: Self.frame); continue }
                    let src = buf.baseAddress! + (start + b) * Self.hop
                    var mean: Float = 0
                    vDSP_meanv(src, 1, &mean, vDSP_Length(Self.frame))
                    var negMean = -mean
                    vDSP_vsadd(src, 1, &negMean, dst, 1, vDSP_Length(Self.frame))
                    var rms: Float = 0
                    vDSP_rmsqv(dst, 1, &rms, vDSP_Length(Self.frame))
                    rmsList.append(rms)
                    var inv = 1 / max(rms, 1e-10)
                    vDSP_vsmul(dst, 1, &inv, dst, 1, vDSP_Length(Self.frame))
                }
                _ = buf
            }
            let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["frames": input]))
            guard let sal = result.featureValue(for: "salience")?.multiArrayValue else { throw SeparationError.badAudio("crepe output") }
            let strides = sal.strides.map(\.intValue)
            for b in 0..<n {
                var best = 0
                var bestV: Float = -1
                var row = [Float](repeating: 0, count: 360)
                for k in 0..<360 {
                    let v = value(sal, b * strides[0] + k * strides[1])
                    row[k] = v
                    if v > bestV { bestV = v; best = k }
                }
                let lo = max(0, best - 4), hi = min(359, best + 4)
                var wsum: Float = 0, csum: Float = 0
                for k in lo...hi { wsum += row[k]; csum += row[k] * (Float(k) * 20 + 1997.3794) }
                let cents = wsum > 0 ? csum / wsum : Float(best) * 20 + 1997.3794
                let hz = 10 * pow(2, cents / 1200)
                out.append(Frame(midi: 69 + 12 * log2(hz / 440), confidence: bestV, rms: rmsList[b]))
            }
            rmsList.removeAll(keepingCapacity: true)
            start += n
        }
        return out
    }

    private func value(_ a: MLMultiArray, _ off: Int) -> Float {
        switch a.dataType {
        case .float16: Float(a.dataPointer.assumingMemoryBound(to: Float16.self)[off])
        case .double: Float(a.dataPointer.assumingMemoryBound(to: Double.self)[off])
        default: a.dataPointer.assumingMemoryBound(to: Float.self)[off]
        }
    }

    public func extract(vocals: URL, lyrics: Lyrics?) throws -> PitchTrack {
        let audio = try StereoAudio.load(vocals, sampleRate: Self.rate)
        let mono = vDSP.multiply(0.5, vDSP.add(audio.left, audio.right))
        return Self.build(try frames(mono), lyrics: lyrics)
    }

    /// Voicing decision, lyric gating, smoothing, then a Ramer–Douglas–Peucker contour.
    public static func build(_ frames: [Frame], lyrics: Lyrics?, epsilon: Float = 0.6) -> PitchTrack {
        let dt = Double(hop) / rate
        let peak = frames.map(\.rms).max() ?? 1
        let words: [(Double, Double)] = lyrics.map { l in
            guard l.kind >= .word else { return [] }
            return l.lines.flatMap { $0.segments.map { ($0.start - 0.15, $0.end + 0.25) } }
        } ?? []
        var wi = 0
        var voiced = [Float?](repeating: nil, count: frames.count)
        for (i, f) in frames.enumerated() {
            let t = Double(i) * dt
            var inLyrics = words.isEmpty
            if !words.isEmpty {
                while wi < words.count, words[wi].1 < t { wi += 1 }
                inLyrics = wi < words.count && words[wi].0 <= t
            }
            guard inLyrics, f.rms > peak * 0.03, f.midi > 33, f.midi < 90 else { continue }
            if f.confidence >= (words.isEmpty ? 0.6 : 0.42) { voiced[i] = f.midi }
        }
        // Octave jumps for a single frame are tracker errors: fold them back onto their neighbours.
        for i in 1..<max(1, voiced.count - 1) {
            guard let v = voiced[i], let a = voiced[i - 1] ?? voiced[i + 1] else { continue }
            if abs(v - a) > 9 { voiced[i] = PitchTrack.foldOctave(v, toward: a) }
        }
        var smooth = voiced
        for i in 3..<max(3, voiced.count - 3) where voiced[i] != nil {
            let w = voiced[(i - 3)...(i + 3)].compactMap { $0 }
            if w.count >= 4 { smooth[i] = w.sorted()[w.count / 2] }
        }
        var notes: [PitchNote] = []
        var run: [(Double, Float)] = []
        var gapFrames = 0
        func flush() {
            defer { run = [] }
            guard run.count >= 15 else { return }
            let pts = rdp(run, epsilon: epsilon)
            for k in 0..<(pts.count - 1) {
                let a = pts[k], b = pts[k + 1]
                let slope = abs(b.1 - a.1)
                notes.append(PitchNote(start: a.0, end: b.0, midi: a.1, endMidi: slope < 0.35 ? nil : b.1))
            }
            if notes.last.map({ $0.endMidi == nil }) == true, pts.count >= 2 {
                let m = (pts[pts.count - 2].1 + pts[pts.count - 1].1) / 2
                notes[notes.count - 1].midi = m
            }
        }
        for (i, v) in smooth.enumerated() {
            let t = Double(i) * dt
            if let v {
                if let last = run.last, abs(v - last.1) > (gapFrames > 0 ? 2.5 : 4) { flush() }
                run.append((t, v))
                gapFrames = 0
            } else {
                gapFrames += 1
                if gapFrames > 12 { flush() }
            }
        }
        flush()
        var track = PitchTrack(version: PitchTrack.currentVersion, notes: notes)
        if track.high - track.low < 10 {
            let mid = (track.high + track.low) / 2
            track.low = mid - 5
            track.high = mid + 5
        }
        return track
    }

    static func rdp(_ pts: [(Double, Float)], epsilon: Float) -> [(Double, Float)] {
        guard pts.count > 2 else { return pts }
        let a = pts[0], b = pts[pts.count - 1]
        var maxD: Float = 0
        var idx = 0
        for i in 1..<(pts.count - 1) {
            let f = Float((pts[i].0 - a.0) / max(b.0 - a.0, 1e-6))
            let line = a.1 + (b.1 - a.1) * f
            let d = abs(pts[i].1 - line)
            if d > maxD { maxD = d; idx = i }
        }
        if maxD > epsilon {
            let left = rdp(Array(pts[0...idx]), epsilon: epsilon)
            let right = rdp(Array(pts[idx...]), epsilon: epsilon)
            return Array(left.dropLast()) + right
        }
        return [a, b]
    }
}
