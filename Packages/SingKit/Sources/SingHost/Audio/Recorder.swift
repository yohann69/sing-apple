#if os(macOS)
import AVFoundation
import Foundation
import SingObjC

/// Writes what an engine tap hears to a file; safe to feed from the audio thread.
/// The file is created from the first buffer so its format always matches what the tap delivers.
final class TapRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var failed = false
    let url: URL

    init(url: URL) { self.url = url }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !failed else { return }
            if file == nil {
                let f = buffer.format
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: f.sampleRate, AVNumberOfChannelsKey: f.channelCount,
                                               AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false]
                file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: f.isInterleaved)
                if file == nil { failed = true; return }
            }
            guard let file else { return }
            var error: NSError?
            if !SingTryObjC({ try? file.write(from: buffer) }, &error) { failed = true }
        }
    }

    func close() {
        lock.withLock { file = nil }
    }
}

/// Joins a short excerpt of each recording, with fades, into one highlight reel.
enum HighlightReel {
    static func make(from files: [URL], to out: URL, excerpt: TimeInterval = 12, fade: TimeInterval = 0.6) throws -> Bool {
        var writer: AVAudioFile?
        var wrote = false
        for url in files {
            guard let f = try? AVAudioFile(forReading: url) else { continue }
            let rate = f.processingFormat.sampleRate
            if writer == nil {
                try? FileManager.default.removeItem(at: out)
                writer = try AVAudioFile(forWriting: out, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000],
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            guard let w = writer, w.processingFormat.sampleRate == rate else { continue }
            let len = AVAudioFrameCount(min(Double(f.length), excerpt * rate))
            f.framePosition = max(0, AVAudioFramePosition(Double(f.length) * 0.35))
            if f.framePosition + AVAudioFramePosition(len) > f.length { f.framePosition = max(0, f.length - AVAudioFramePosition(len)) }
            guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: len),
                  let out2 = AVAudioPCMBuffer(pcmFormat: w.processingFormat, frameCapacity: len) else { continue }
            try f.read(into: buf, frameCount: len)
            let n = Int(buf.frameLength), fadeN = Int(fade * rate)
            out2.frameLength = buf.frameLength
            for c in 0..<2 {
                let src = buf.floatChannelData![min(c, Int(buf.format.channelCount) - 1)]
                let dst = out2.floatChannelData![c]
                for i in 0..<n {
                    let g = min(1, Float(min(i, n - 1 - i)) / Float(max(1, fadeN)))
                    dst[i] = src[i] * g
                }
            }
            try w.write(from: out2)
            wrote = true
        }
        return wrote
    }
}

/// Mixes the recorded voice over the recorded music into one shareable AAC file.
enum RecordingMixer {
    /// `voiceDelay` is how late the voice arrived (output plus input latency); it is trimmed from the voice start.
    static func mix(music: URL, voice: URL, to out: URL, voiceDelay: TimeInterval, voiceGain: Float = 1.0) throws -> TimeInterval {
        let m = try AVAudioFile(forReading: music)
        let rate = m.processingFormat.sampleRate
        // The mic often runs at another rate than the music: bring the voice to the music's rate first.
        let v = try StereoAudio.load(voice, sampleRate: rate)
        let skip = min(v.left.count, max(0, Int(voiceDelay * rate)))
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
        try? FileManager.default.removeItem(at: out)
        let writer = try AVAudioFile(forWriting: out, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: AVAudioFrameCount = 8192
        let mb = AVAudioPCMBuffer(pcmFormat: m.processingFormat, frameCapacity: chunk)!
        let ob = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk)!
        var total = 0
        while m.framePosition < m.length {
            try m.read(into: mb, frameCount: chunk)
            let n = Int(mb.frameLength)
            if n == 0 { break }
            ob.frameLength = AVAudioFrameCount(n)
            for c in 0..<2 {
                let mc = mb.floatChannelData![min(c, Int(mb.format.channelCount) - 1)]
                let vc = c == 0 ? v.left : v.right
                let oc = ob.floatChannelData![c]
                for i in 0..<n {
                    let vi = skip + total + i
                    let s = mc[i] + (vi < vc.count ? vc[vi] * voiceGain : 0)
                    oc[i] = max(-1, min(1, s))
                }
            }
            try writer.write(from: ob)
            total += n
        }
        return Double(total) / rate
    }
}
#endif
