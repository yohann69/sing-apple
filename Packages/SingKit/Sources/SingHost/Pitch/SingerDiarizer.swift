import Accelerate
import CoreML
import Foundation
import SingCore

/// Tells singers apart when the lyrics do not say who sings what: each line gets a timbre and
/// register fingerprint from the vocal stem, then two clusters are kept only if they are clearly distinct.
public enum SingerDiarizer {
    static let rate: Double = 16000

    public struct Outcome: Sendable {
        public var lyrics: Lyrics
        public var separation: Double
    }

    /// One ECAPA voice embedding per sung line (the speaker model runs on Core ML).
    public static func embeddings(_ lyrics: Lyrics, vocals: URL, model: URL) throws -> [(line: Int, vector: [Double])] {
        let audio = try StereoAudio.load(vocals, sampleRate: rate)
        let mono = vDSP.multiply(0.5, vDSP.add(audio.left, audio.right))
        var url = model
        if url.pathExtension == "mlpackage" { url = try MLModel.compileModel(at: url) }
        let ml = try MLModel(contentsOf: url)
        var out: [(Int, [Double])] = []
        for (li, line) in lyrics.lines.enumerated() {
            let a = max(0, Int((line.start - 0.05) * rate)), b = min(mono.count, Int((line.end + 0.1) * rate))
            guard b - a >= Int(0.8 * rate) else { continue }
            var slice = Array(mono[a..<b])
            var rms: Float = 0
            vDSP_rmsqv(slice, 1, &rms, vDSP_Length(slice.count))
            guard rms > 0.005 else { continue }
            if slice.count > 480_000 { slice = Array(slice.prefix(480_000)) }
            let arr = try MLMultiArray(shape: [1, NSNumber(value: slice.count)], dataType: .float32)
            let p = arr.dataPointer.assumingMemoryBound(to: Float.self)
            slice.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: slice.count) }
            let r = try ml.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": arr]))
            guard let e = r.featureValue(for: "embedding")?.multiArrayValue else { continue }
            var v = (0..<e.count).map { Double(e[$0].floatValue) }
            let norm = max(1e-9, v.reduce(0) { $0 + $1 * $1 }.squareRoot())
            v = v.map { $0 / norm }
            out.append((li, v))
        }
        return out
    }

    public static func label(_ lyrics: Lyrics, vocals: URL, artist: String, model: URL) throws -> Outcome? {
        guard lyrics.kind >= .line, !lyrics.isDuet, lyrics.lines.count >= 8 else { return nil }
        let emb = try embeddings(lyrics, vocals: vocals, model: model)
        guard emb.count >= 8 else { return nil }
        let (assign, silhouette) = kmeans2(emb.map(\.vector))
        let small = min(assign.filter { $0 == 0 }.count, assign.filter { $0 == 1 }.count)
        let multipleArtists = artist.range(of: #"(&|,|feat\.?|ft\.|with| x )"#, options: [.regularExpression, .caseInsensitive]) != nil
        let threshold = multipleArtists ? 0.12 : 0.3
        guard silhouette > threshold, Double(small) >= Double(assign.count) * 0.12 else {
            return Outcome(lyrics: lyrics, separation: silhouette)
        }
        var out = lyrics
        let firstCluster = assign[0]
        for (k, e) in emb.enumerated() {
            out.lines[e.line].agent = assign[k] == firstCluster ? "v1" : "v2"
        }
        var last = "v1"
        for i in out.lines.indices {
            if let a = out.lines[i].agent { last = a } else { out.lines[i].agent = last }
        }
        out.agents = [Agent(id: "v1"), Agent(id: "v2")]
        return Outcome(lyrics: out, separation: silhouette)
    }

    static func kmeans2(_ x: [[Double]]) -> ([Int], Double) {
        func dist(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot() }
        var best: [Int] = []
        var bestS = -1.0
        for seed in 0..<12 {
            var c0 = x[(seed * 7) % x.count], c1 = x.max { dist($0, c0) < dist($1, c0) }!
            var assign = [Int](repeating: 0, count: x.count)
            for _ in 0..<30 {
                assign = x.map { dist($0, c0) <= dist($0, c1) ? 0 : 1 }
                for k in 0...1 {
                    let members = x.indices.filter { assign[$0] == k }.map { x[$0] }
                    guard !members.isEmpty else { continue }
                    let mean = (0..<x[0].count).map { d in members.reduce(0) { $0 + $1[d] } / Double(members.count) }
                    if k == 0 { c0 = mean } else { c1 = mean }
                }
            }
            var total = 0.0
            for i in x.indices {
                let same = x.indices.filter { assign[$0] == assign[i] && $0 != i }
                let other = x.indices.filter { assign[$0] != assign[i] }
                guard !same.isEmpty, !other.isEmpty else { continue }
                let a = same.reduce(0) { $0 + dist(x[i], x[$1]) } / Double(same.count)
                let b = other.reduce(0) { $0 + dist(x[i], x[$1]) } / Double(other.count)
                total += (b - a) / max(a, b)
            }
            let s = total / Double(x.count)
            if s > bestS { bestS = s; best = assign }
        }
        return (best, bestS)
    }

    static func melFilterbank(bins: Int, filters: Int, sampleRate: Double) -> [[Float]] {
        func mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let lo = mel(80), hi = mel(7600)
        let points = (0...(filters + 1)).map { hz(lo + (hi - lo) * Double($0) / Double(filters + 1)) }
        let binHz = sampleRate / 2 / Double(bins - 1)
        return (1...filters).map { i in
            (0..<bins).map { k in
                let f = Double(k) * binHz
                let l = points[i - 1], c = points[i], r = points[i + 1]
                if f < l || f > r { return 0 }
                return Float(f <= c ? (f - l) / (c - l) : (r - f) / (r - c))
            }
        }
    }

    static func dct(_ x: [Float], count: Int) -> [Float] {
        let n = Float(x.count)
        return (0..<count).map { k in
            x.enumerated().reduce(Float(0)) { $0 + $1.element * cos(.pi * Float(k) * (Float($1.offset) + 0.5) / n) }
        }
    }
}
