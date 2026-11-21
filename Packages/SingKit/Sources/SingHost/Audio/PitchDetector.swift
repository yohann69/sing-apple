import Accelerate
import AVFoundation
import Foundation
import SingCore

/// YIN pitch detection on top of vDSP correlation.
public struct YIN: Sendable {
    public let sampleRate: Double
    public let window: Int
    let minLag: Int
    let maxLag: Int
    public var threshold: Float = 0.15

    public init(sampleRate: Double, window: Int = 1024, minHz: Double = 70, maxHz: Double = 1100) {
        self.sampleRate = sampleRate
        self.window = window
        minLag = max(2, Int(sampleRate / maxHz))
        maxLag = min(window - 1, Int(sampleRate / minHz))
    }

    public var needed: Int { window + maxLag + 1 }

    /// MIDI note of a frame of `needed` samples starting at `ptr`, or nil when unvoiced.
    public func midi(_ ptr: UnsafePointer<Float>) -> (midi: Float, confidence: Float)? {
        let lags = maxLag + 1
        var corr = [Float](repeating: 0, count: lags)
        vDSP_conv(ptr, 1, ptr, 1, &corr, 1, vDSP_Length(lags), vDSP_Length(window))
        var e0: Float = 0
        vDSP_svesq(ptr, 1, &e0, vDSP_Length(window))
        guard e0 > 1e-6 else { return nil }
        var energies = [Float](repeating: 0, count: lags)
        var e = e0
        energies[0] = e0
        for tau in 1..<lags {
            let out = ptr[tau - 1], inn = ptr[tau + window - 1]
            e += inn * inn - out * out
            energies[tau] = e
        }
        var d = [Float](repeating: 0, count: lags)
        for tau in 1..<lags { d[tau] = e0 + energies[tau] - 2 * corr[tau] }
        var cmnd = [Float](repeating: 1, count: lags)
        var running: Float = 0
        for tau in 1..<lags {
            running += d[tau]
            cmnd[tau] = running > 0 ? d[tau] * Float(tau) / running : 1
        }
        var tau = minLag
        var best = -1
        while tau < lags - 1 {
            if cmnd[tau] < threshold {
                while tau + 1 < lags - 1, cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                best = tau
                break
            }
            tau += 1
        }
        if best < 0 {
            var minV: Float = 1
            var idx: vDSP_Length = 0
            cmnd.withUnsafeBufferPointer { vDSP_minvi($0.baseAddress! + minLag, 1, &minV, &idx, vDSP_Length(lags - minLag - 1)) }
            guard minV < 0.3 else { return nil }
            best = minLag + Int(idx)
        }
        let x0 = best > 1 ? cmnd[best - 1] : cmnd[best]
        let x2 = best + 1 < lags ? cmnd[best + 1] : cmnd[best]
        let denom = 2 * (2 * cmnd[best] - x2 - x0)
        let shift = denom != 0 ? (x2 - x0) / denom : 0
        let period = Float(best) + max(-1, min(1, shift))
        let hz = Float(sampleRate) / period
        guard hz > 0 else { return nil }
        return (69 + 12 * log2(hz / 440), 1 - cmnd[best])
    }
}

public enum MelodyExtractor {
    public static let rate: Double = 16000
    public static let hop = 160

    /// Reference melody from a vocal stem: YIN every 10 ms, then stable stretches become note bars.
    public static func extract(vocals url: URL) throws -> PitchTrack {
        let audio = try StereoAudio.load(url, sampleRate: rate)
        let mono = vDSP.multiply(0.5, vDSP.add(audio.left, audio.right))
        return extract(mono: mono)
    }

    public static func extract(mono: [Float]) -> PitchTrack {
        let yin = YIN(sampleRate: rate, window: 640, minHz: 70, maxHz: 1000)
        let frames = max(0, (mono.count - yin.needed) / hop)
        var peak: Float = 0
        vDSP_maxmgv(mono, 1, &peak, vDSP_Length(mono.count))
        let gate = max(1e-4, peak * 0.04)
        var track = [Float?](repeating: nil, count: frames)
        mono.withUnsafeBufferPointer { buf in
            for f in 0..<frames {
                let p = buf.baseAddress! + f * hop
                var rms: Float = 0
                vDSP_rmsqv(p, 1, &rms, vDSP_Length(yin.window))
                guard rms > gate, let r = yin.midi(p), r.confidence > 0.7, r.midi > 36, r.midi < 90 else { continue }
                track[f] = r.midi
            }
        }
        return PitchTrack(notes: segment(track, frameSeconds: Double(hop) / rate, offset: Double(yin.window) / 2 / rate))
    }

    static func segment(_ raw: [Float?], frameSeconds: Double, offset: Double) -> [PitchNote] {
        var smooth = raw
        for i in 2..<max(2, raw.count - 2) {
            let w = raw[(i - 2)...(i + 2)].compactMap { $0 }
            smooth[i] = raw[i] == nil || w.count < 3 ? raw[i] : w.sorted()[w.count / 2]
        }
        var notes: [PitchNote] = []
        var run: [Float] = []
        var runStart = 0
        func close(_ end: Int) {
            defer { run = [] }
            guard run.count >= 6 else { return }
            let m = run.sorted()[run.count / 2]
            let s = Double(runStart) * frameSeconds + offset, e = Double(end) * frameSeconds + offset
            if let last = notes.last, abs(last.midi - m) < 0.6, s - last.end < 0.06 {
                notes[notes.count - 1].end = e
            } else {
                notes.append(PitchNote(start: s, end: e, midi: m))
            }
        }
        for (i, v) in smooth.enumerated() {
            guard let v else { close(i); continue }
            if run.isEmpty { runStart = i; run = [v]; continue }
            let center = run.sorted()[run.count / 2]
            if abs(v - center) > 0.9 { close(i); runStart = i; run = [v] } else { run.append(v) }
        }
        close(smooth.count)
        return notes
    }
}

/// Live singer pitch from the microphone tap, read by the main thread.
public final class LivePitch: @unchecked Sendable {
    private let lock = NSLock()
    private var _midi: Float?
    private var buffer: [Float] = []
    private var yin: YIN?

    public var midi: Float? { lock.withLock { _midi } }

    func process(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Double) {
        let detector: YIN = lock.withLock {
            if yin?.sampleRate != sampleRate { yin = YIN(sampleRate: sampleRate, window: Int(sampleRate * 0.04), minHz: 70, maxHz: 1000) }
            return yin!
        }
        buffer.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        if buffer.count > detector.needed * 2 { buffer.removeFirst(buffer.count - detector.needed) }
        guard buffer.count >= detector.needed else { return }
        let start = buffer.count - detector.needed
        var rms: Float = 0
        let result: Float? = buffer.withUnsafeBufferPointer { b in
            vDSP_rmsqv(b.baseAddress! + start, 1, &rms, vDSP_Length(detector.window))
            guard rms > 0.01, let r = detector.midi(b.baseAddress! + start), r.confidence > 0.75 else { return nil }
            return r.midi
        }
        lock.withLock { _midi = result }
    }
}
