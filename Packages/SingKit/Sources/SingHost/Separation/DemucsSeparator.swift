import AVFoundation
import Accelerate
import CoreML
import Foundation

public enum SeparationError: Error, LocalizedError {
    case modelMissing(URL)
    case badAudio(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let url): "Separation model not found at \(url.path)"
        case .badAudio(let s): "Could not read audio: \(s)"
        case .cancelled: "Separation cancelled"
        }
    }
}

public struct StereoAudio: Sendable {
    public var left: [Float]
    public var right: [Float]
    public var sampleRate: Double
    public var count: Int { left.count }

    public static func load(_ url: URL, sampleRate: Double = 44100) throws -> StereoAudio {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        let source = file.processingFormat
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)) else { throw SeparationError.badAudio("buffer") }
        try file.read(into: inBuf)
        if source.sampleRate == sampleRate, source.channelCount == 2, source.commonFormat == .pcmFormatFloat32, !source.isInterleaved {
            let n = Int(inBuf.frameLength)
            return StereoAudio(left: Array(UnsafeBufferPointer(start: inBuf.floatChannelData![0], count: n)), right: Array(UnsafeBufferPointer(start: inBuf.floatChannelData![1], count: n)), sampleRate: sampleRate)
        }
        guard let converter = AVAudioConverter(from: source, to: target) else { throw SeparationError.badAudio("converter") }
        if source.channelCount == 1 { converter.channelMap = [0, 0] }
        let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * sampleRate / source.sampleRate) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw SeparationError.badAudio("buffer") }
        var consumed = false
        var error: NSError?
        converter.convert(to: outBuf, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return inBuf
        }
        if let error { throw error }
        let n = Int(outBuf.frameLength)
        return StereoAudio(left: Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: n)), right: Array(UnsafeBufferPointer(start: outBuf.floatChannelData![1], count: n)), sampleRate: sampleRate)
    }

    public func write(to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16]
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).partial")
        try? FileManager.default.removeItem(at: tmp)
        do {
            let file = try AVAudioFile(forWriting: tmp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let chunk = 1 << 16
            var pos = 0
            while pos < count {
                let n = min(chunk, count - pos)
                let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
                buf.frameLength = AVAudioFrameCount(n)
                left.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress! + pos, count: n) }
                right.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress! + pos, count: n) }
                try file.write(from: buf)
                pos += n
            }
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }
}

/// Runs HTDemucs exported as a Core ML model without its STFT; spectrogram work happens here.
public final class DemucsSeparator: @unchecked Sendable {
    public static let segmentLength = 343_980
    static let sources = ["drums", "bass", "other", "vocals"]
    static let vocalsIndex = 3

    let model: MLModel
    let stft: STFT
    let nfft = 4096
    let hop = 1024
    var bins: Int { nfft / 2 }
    var frames: Int { Int((Double(Self.segmentLength) / Double(hop)).rounded(.up)) }

    public init(modelURL: URL, computeUnits: MLComputeUnits = .all) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw SeparationError.modelMissing(modelURL) }
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        var compiled = modelURL
        if modelURL.pathExtension == "mlpackage" || modelURL.pathExtension == "mlmodel" {
            compiled = try MLModel.compileModel(at: modelURL)
        }
        model = try MLModel(contentsOf: compiled, configuration: config)
        stft = try STFT(nfft: nfft, hop: hop)
    }

    /// Returns the vocal stem. Progress is reported from 0 to 1.
    public func separateVocals(_ audio: StereoAudio, progress: (@Sendable (Double) -> Bool)? = nil) throws -> StereoAudio {
        let n = audio.count
        let mono = zip(audio.left, audio.right).map { ($0 + $1) / 2 }
        let mean = vDSP.mean(mono)
        let std = max(1e-8, sqrt(vDSP.meanSquare(vDSP.add(-mean, mono))))
        let left = vDSP.divide(vDSP.add(-mean, audio.left), std)
        let right = vDSP.divide(vDSP.add(-mean, audio.right), std)

        let L = Self.segmentLength
        let stride = Int(0.75 * Double(L))
        var weight = [Float](repeating: 0, count: L)
        for i in 0..<L {
            weight[i] = i < L / 2 ? Float(i + 1) : Float(L - i)
        }
        let wmax = weight.max() ?? 1
        weight = weight.map { $0 / wmax }

        var outL = [Float](repeating: 0, count: n)
        var outR = [Float](repeating: 0, count: n)
        var sumW = [Float](repeating: 0, count: n)
        let offsets = Array(Swift.stride(from: 0, to: max(n, 1), by: stride))
        for (ci, offset) in offsets.enumerated() {
            let len = min(L, n - offset)
            var cl = [Float](repeating: 0, count: L)
            var cr = [Float](repeating: 0, count: L)
            for i in 0..<len {
                cl[i] = left[offset + i]
                cr[i] = right[offset + i]
            }
            let (vl, vr) = try runChunk(cl, cr)
            for i in 0..<len {
                outL[offset + i] += vl[i] * weight[i]
                outR[offset + i] += vr[i] * weight[i]
                sumW[offset + i] += weight[i]
            }
            if let progress, !progress(Double(ci + 1) / Double(offsets.count)) { throw SeparationError.cancelled }
        }
        for i in 0..<n {
            let w = max(sumW[i], 1e-8)
            outL[i] = outL[i] / w * std + mean
            outR[i] = outR[i] / w * std + mean
        }
        return StereoAudio(left: outL, right: outR, sampleRate: audio.sampleRate)
    }

    private func spec(_ x: [Float]) -> (re: [[Float]], im: [[Float]]) {
        let le = frames
        let pad = hop / 2 * 3
        let padded = STFT.reflectPad(x, left: pad, right: pad + le * hop - x.count)
        let z = stft.stft(padded)
        return (Array(z.re[2..<(2 + le)]), Array(z.im[2..<(2 + le)]))
    }

    private func ispec(re: [[Float]], im: [[Float]], length: Int) -> [Float] {
        let pad = hop / 2 * 3
        let le = hop * Int((Double(length) / Double(hop)).rounded(.up)) + 2 * pad
        let zero = [Float](repeating: 0, count: bins + 1)
        let fullRe = [zero, zero] + re.map { $0 + [0] } + [zero, zero]
        let fullIm = [zero, zero] + im.map { $0 + [0] } + [zero, zero]
        let x = stft.istft(re: fullRe, im: fullIm, length: le)
        return Array(x[pad..<(pad + length)])
    }

    private func runChunk(_ l: [Float], _ r: [Float]) throws -> ([Float], [Float]) {
        let L = Self.segmentLength
        let T = frames
        let F = bins
        let zl = spec(l)
        let zr = spec(r)

        let mix = try MLMultiArray(shape: [1, 2, NSNumber(value: L)], dataType: .float32)
        let mixPtr = mix.dataPointer.assumingMemoryBound(to: Float.self)
        l.withUnsafeBufferPointer { mixPtr.update(from: $0.baseAddress!, count: L) }
        r.withUnsafeBufferPointer { (mixPtr + L).update(from: $0.baseAddress!, count: L) }

        let mag = try MLMultiArray(shape: [1, 4, NSNumber(value: F), NSNumber(value: T)], dataType: .float32)
        let magPtr = mag.dataPointer.assumingMemoryBound(to: Float.self)
        let planes = [(zl.re), (zl.im), (zr.re), (zr.im)]
        for (c, plane) in planes.enumerated() {
            let base = c * F * T
            for t in 0..<T {
                let frame = plane[t]
                for f in 0..<F { magPtr[base + f * T + t] = frame[f] }
            }
        }

        let input = try MLDictionaryFeatureProvider(dictionary: ["mix": mix, "mag": mag])
        let out = try model.prediction(from: input)
        guard let freq = out.featureValue(for: "freq")?.multiArrayValue, let time = out.featureValue(for: "time")?.multiArrayValue else {
            throw SeparationError.badAudio("model output")
        }
        let fs = freq.strides.map(\.intValue)
        let ts = time.strides.map(\.intValue)
        let s = Self.vocalsIndex

        func readFreq(_ ch: Int) -> (re: [[Float]], im: [[Float]]) {
            var re = [[Float]](repeating: [Float](repeating: 0, count: F), count: T)
            var im = re
            let reC = s * 4 + ch * 2
            let imC = reC + 1
            for t in 0..<T {
                for f in 0..<F {
                    re[t][f] = value(freq, [0, reC, f, t], fs)
                    im[t][f] = value(freq, [0, imC, f, t], fs)
                }
            }
            return (re, im)
        }

        var result: [[Float]] = []
        for ch in 0..<2 {
            let z = readFreq(ch)
            var wave = ispec(re: z.re, im: z.im, length: L)
            let tc = s * 2 + ch
            for i in 0..<L { wave[i] += value(time, [0, tc, i], ts) }
            result.append(wave)
        }
        return (result[0], result[1])
    }

    @inline(__always)
    private func value(_ a: MLMultiArray, _ idx: [Int], _ strides: [Int]) -> Float {
        var off = 0
        for i in 0..<idx.count { off += idx[i] * strides[i] }
        switch a.dataType {
        case .float16: return Float(a.dataPointer.assumingMemoryBound(to: Float16.self)[off])
        case .double: return Float(a.dataPointer.assumingMemoryBound(to: Double.self)[off])
        default: return a.dataPointer.assumingMemoryBound(to: Float.self)[off]
        }
    }
}
