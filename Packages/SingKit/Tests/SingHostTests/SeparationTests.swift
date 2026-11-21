import Foundation
import Testing
@testable import SingHost

private let modelPath = ProcessInfo.processInfo.environment["SING_MODEL"] ?? ""
private let refDir = ProcessInfo.processInfo.environment["SING_REF"] ?? ""

@Suite(.enabled(if: !modelPath.isEmpty && !refDir.isEmpty))
struct SeparationTests {
    @Test func matchesPyTorchDemucs() throws {
        let mix = try StereoAudio.load(URL(fileURLWithPath: refDir).appendingPathComponent("firework20.wav"))
        let ref = try StereoAudio.load(URL(fileURLWithPath: refDir).appendingPathComponent("firework20_vocals_torch.wav"))
        let start = Date()
        let sep = try DemucsSeparator(modelURL: URL(fileURLWithPath: modelPath))
        let loaded = Date()
        let vocals = try sep.separateVocals(mix)
        let done = Date()
        var signal: Double = 0, noise: Double = 0
        for i in 0..<min(ref.count, vocals.count) {
            signal += Double(ref.left[i] * ref.left[i])
            let d = Double(ref.left[i] - vocals.left[i])
            noise += d * d
        }
        let sdr = 10 * log10(signal / max(noise, 1e-12))
        print("SEPARATION load \(loaded.timeIntervalSince(start))s run \(done.timeIntervalSince(loaded))s for 20s audio, SDR vs torch \(sdr) dB")
        try vocals.write(to: URL(fileURLWithPath: refDir).appendingPathComponent("firework20_vocals_swift.caf"))
        #expect(sdr > 30)
    }
}
