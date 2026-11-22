import AVFoundation
import Foundation
import Testing
@testable import SingHost

@MainActor @Suite struct AudioCueTests {
    /// Phones can be the only mics: the chain runs without ever opening the Mac's input.
    @Test func micChainRunsWithPhonesOnly() throws {
        let mic = MicEngine()
        try mic.start(macMic: false)
        #expect(mic.isRunning)
        #expect(!mic.usesMacMic)
        #expect(mic.channelLevels.isEmpty)
        mic.stop()
        #expect(!mic.isRunning)
    }

    /// The jingle plays, then the bed takes over and keeps looping until stopped.
    @Test func jingleHandsOverToLoopingBed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func tone(_ name: String, seconds: Double) throws -> URL {
            let url = dir.appendingPathComponent(name)
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            let n = AVAudioFrameCount(44100 * seconds)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
            buf.frameLength = n
            for i in 0..<Int(n) { let v = Float(0.01 * sin(Double(i) * 0.05)); buf.floatChannelData![0][i] = v; buf.floatChannelData![1][i] = v }
            try AVAudioFile(forWriting: url, settings: fmt.settings).write(from: buf)
            return url
        }
        let engine = PlaybackEngine()
        engine.playCue(jingle: try tone("j.caf", seconds: 1), bed: try tone("b.caf", seconds: 0.5), volume: 0.01)
        try await Task.sleep(for: .seconds(2))
        #expect(engine.cuePlaying)
        engine.stopCue(fade: 0.2)
        try await Task.sleep(for: .seconds(0.6))
        #expect(!engine.cuePlaying)
    }
}
