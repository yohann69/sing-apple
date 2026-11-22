#if os(macOS)
import AVFoundation
import Foundation

/// Writes what an engine tap hears to a file; safe to feed from the audio thread.
final class TapRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    let url: URL

    init(url: URL, format: AVAudioFormat) throws {
        self.url = url
        file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { try? file?.write(from: buffer) }
    }

    func close() {
        lock.withLock { file = nil }
    }
}

/// Mixes the recorded voice over the recorded music into one shareable AAC file.
enum RecordingMixer {
    /// `voiceDelay` is how late the voice arrived (output plus input latency); it is trimmed from the voice start.
    static func mix(music: URL, voice: URL, to out: URL, voiceDelay: TimeInterval, voiceGain: Float = 1.0) throws -> TimeInterval {
        let m = try AVAudioFile(forReading: music)
        let v = try AVAudioFile(forReading: voice)
        let rate = m.processingFormat.sampleRate
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
        try? FileManager.default.removeItem(at: out)
        let writer = try AVAudioFile(forWriting: out, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let skip = AVAudioFramePosition(voiceDelay * v.processingFormat.sampleRate)
        if skip < v.length { v.framePosition = max(0, skip) }
        let chunk: AVAudioFrameCount = 8192
        let mb = AVAudioPCMBuffer(pcmFormat: m.processingFormat, frameCapacity: chunk)!
        let vb = AVAudioPCMBuffer(pcmFormat: v.processingFormat, frameCapacity: chunk)!
        let ob = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk)!
        let sameRate = v.processingFormat.sampleRate == rate
        var total: AVAudioFramePosition = 0
        while m.framePosition < m.length {
            try m.read(into: mb, frameCount: chunk)
            let n = Int(mb.frameLength)
            if n == 0 { break }
            vb.frameLength = 0
            if sameRate, v.framePosition < v.length { try? v.read(into: vb, frameCount: AVAudioFrameCount(n)) }
            ob.frameLength = AVAudioFrameCount(n)
            for c in 0..<2 {
                let mc = mb.floatChannelData![min(c, Int(mb.format.channelCount) - 1)]
                let vc = vb.floatChannelData![min(c, Int(vb.format.channelCount) - 1)]
                let oc = ob.floatChannelData![c]
                let vn = Int(vb.frameLength)
                for i in 0..<n {
                    let s = mc[i] + (i < vn ? vc[i] * voiceGain : 0)
                    oc[i] = max(-1, min(1, s))
                }
            }
            try writer.write(from: ob)
            total += AVAudioFramePosition(n)
        }
        return Double(total) / rate
    }
}
#endif
