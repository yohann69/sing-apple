import Foundation
import Testing
@testable import SingHost
@testable import SingCore

@Suite struct PitchTests {
    @Test func detectsSineNotes() {
        let rate = MelodyExtractor.rate
        var mono: [Float] = []
        for (hz, secs) in [(220.0, 0.5), (0.0, 0.3), (330.0, 0.6), (440.0, 0.4)] {
            let n = Int(rate * secs)
            for i in 0..<n { mono.append(hz == 0 ? 0 : Float(0.5 * sin(2 * .pi * hz * Double(i) / rate))) }
        }
        let track = MelodyExtractor.extract(mono: mono)
        #expect(track.notes.count == 3)
        let midis = track.notes.map { Int($0.midi.rounded()) }
        #expect(midis == [57, 64, 69])
        #expect(abs(track.notes[1].start - 0.8) < 0.08)
    }

    @Test func octaveFolding() {
        #expect(PitchTrack.foldOctave(48, toward: 61) == 60)
        #expect(PitchTrack.foldOctave(75, toward: 62) == 63)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SING_CACHE_SONG"] != nil))
    func realVocals() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SING_CACHE_SONG"]!)
        let start = Date()
        let track = try MelodyExtractor.extract(vocals: dir.appendingPathComponent("vocals.caf"))
        print("PITCH \(track.notes.count) notes in \(Date().timeIntervalSince(start))s range \(track.low)-\(track.high)")
        #expect(track.notes.count > 100)
    }
}
