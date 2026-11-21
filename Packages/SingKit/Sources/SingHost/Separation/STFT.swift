import Accelerate
import Foundation

/// STFT/iSTFT matching `torch.stft(normalized=True, center=True, pad_mode="reflect")` with a periodic Hann window.
public final class STFT: @unchecked Sendable {
    public let nfft: Int
    public let hop: Int
    let window: [Float]
    private let forward: vDSP.DiscreteFourierTransform<Float>
    private let inverse: vDSP.DiscreteFourierTransform<Float>

    public init(nfft: Int = 4096, hop: Int = 1024) throws {
        self.nfft = nfft
        self.hop = hop
        window = (0..<nfft).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(nfft)) }
        forward = try vDSP.DiscreteFourierTransform(count: nfft, direction: .forward, transformType: .complexReal, ofType: Float.self)
        inverse = try vDSP.DiscreteFourierTransform(count: nfft, direction: .inverse, transformType: .complexReal, ofType: Float.self)
    }

    public static func reflectPad(_ x: [Float], left: Int, right: Int) -> [Float] {
        let n = x.count
        var out = [Float](repeating: 0, count: n + left + right)
        for i in 0..<out.count {
            var j = i - left
            if n == 1 { j = 0 }
            while j < 0 || j >= n {
                if j < 0 { j = -j }
                if j >= n { j = 2 * (n - 1) - j }
            }
            out[i] = x[j]
        }
        return out
    }

    /// Returns (re, im) as [frame][bin] for bins 0...nfft/2.
    public func stft(_ signal: [Float]) -> (re: [[Float]], im: [[Float]]) {
        let padded = Self.reflectPad(signal, left: nfft / 2, right: nfft / 2)
        let frames = 1 + (padded.count - nfft) / hop
        let half = nfft / 2
        let scale = 1 / sqrt(Float(nfft)) / 2
        var re = [[Float]](repeating: [], count: frames)
        var im = [[Float]](repeating: [], count: frames)
        var evens = [Float](repeating: 0, count: half)
        var odds = [Float](repeating: 0, count: half)
        var outR = [Float](repeating: 0, count: half)
        var outI = [Float](repeating: 0, count: half)
        padded.withUnsafeBufferPointer { p in
            for f in 0..<frames {
                let base = f * hop
                for k in 0..<half {
                    evens[k] = p[base + 2 * k] * window[2 * k]
                    odds[k] = p[base + 2 * k + 1] * window[2 * k + 1]
                }
                forward.transform(inputReal: evens, inputImaginary: odds, outputReal: &outR, outputImaginary: &outI)
                var r = [Float](repeating: 0, count: half + 1)
                var i = [Float](repeating: 0, count: half + 1)
                r[0] = outR[0] * scale
                r[half] = outI[0] * scale
                for k in 1..<half {
                    r[k] = outR[k] * scale
                    i[k] = outI[k] * scale
                }
                re[f] = r
                im[f] = i
            }
        }
        return (re, im)
    }

    /// Inverse of `stft`, trimmed to `length` samples after removing the centre padding.
    public func istft(re: [[Float]], im: [[Float]], length: Int) -> [Float] {
        let frames = re.count
        let half = nfft / 2
        let total = nfft + hop * (frames - 1)
        var out = [Float](repeating: 0, count: total)
        var env = [Float](repeating: 0, count: total)
        var inR = [Float](repeating: 0, count: half)
        var inI = [Float](repeating: 0, count: half)
        var evens = [Float](repeating: 0, count: half)
        var odds = [Float](repeating: 0, count: half)
        let scale = sqrt(Float(nfft)) / Float(nfft)
        for f in 0..<frames {
            inR[0] = re[f][0]
            inI[0] = re[f][half]
            for k in 1..<half {
                inR[k] = re[f][k]
                inI[k] = im[f][k]
            }
            inverse.transform(inputReal: inR, inputImaginary: inI, outputReal: &evens, outputImaginary: &odds)
            let base = f * hop
            for k in 0..<half {
                let a = 2 * k, b = 2 * k + 1
                out[base + a] += evens[k] * scale * window[a]
                out[base + b] += odds[k] * scale * window[b]
                env[base + a] += window[a] * window[a]
                env[base + b] += window[b] * window[b]
            }
        }
        let start = nfft / 2
        var result = [Float](repeating: 0, count: length)
        for i in 0..<length {
            let j = start + i
            guard j < total else { break }
            result[i] = env[j] > 1e-11 ? out[j] / env[j] : 0
        }
        return result
    }
}
