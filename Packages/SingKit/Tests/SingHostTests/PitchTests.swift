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

@Suite(.enabled(if: ProcessInfo.processInfo.environment["SING_CACHE_SONG"] != nil && ProcessInfo.processInfo.environment["SING_CREPE"] != nil))
struct CrepeTests {
    @Test func realVocalsWithLyrics() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SING_CACHE_SONG"]!)
        let lyrics = try? JSONDecoder().decode(Lyrics.self, from: Data(contentsOf: dir.appendingPathComponent("lyrics.json")))
        let start = Date()
        let ex = try CrepeExtractor(modelURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SING_CREPE"]!))
        let track = try ex.extract(vocals: dir.appendingPathComponent("vocals.caf"), lyrics: lyrics)
        let slides = track.notes.filter { $0.endMidi != nil }.count
        let voicedSecs = track.notes.reduce(0) { $0 + $1.end - $1.start }
        var wordsWithPitch = 0, words = 0
        for l in lyrics?.lines ?? [] { for w in l.segments { words += 1; if track.target(at: (w.start + w.end) / 2) != nil { wordsWithPitch += 1 } } }
        print("CREPE \(track.notes.count) pieces (\(slides) slides) \(Int(voicedSecs))s voiced in \(Date().timeIntervalSince(start))s, range \(track.low)-\(track.high), words with pitch \(wordsWithPitch)/\(words)")
        try JSONEncoder().encode(track).write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("crepe-pitch.json"))
        #expect(track.notes.count > 50)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["SING_CACHE_ROOT"] != nil))
struct DiarizeTests {
    @Test func realSongs() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SING_CACHE_ROOT"]!)
        let artists = ["9262277d": "Youssoupha & Noémie", "214462ca": "Katy Perry", "033f6fd4": "P!nk & Nate Ruess", "d7aa461b": "Michael Jackson", "8c346eef": "Justin Bieber & Nicki Minaj", "d431f35d": "Sexion d'Assaut"]
        for dir in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard let lyrics = try? JSONDecoder().decode(Lyrics.self, from: Data(contentsOf: dir.appendingPathComponent("lyrics.json"))) else { continue }
            let artist = artists[String(dir.lastPathComponent.prefix(8))] ?? ""
            let pitch = try? JSONDecoder().decode(PitchTrack.self, from: Data(contentsOf: dir.appendingPathComponent("pitch.json")))
            let start = Date()
            _ = pitch
            let out = try SingerDiarizer.label(lyrics, vocals: dir.appendingPathComponent("vocals.caf"), artist: artist, model: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SING_ECAPA"]!))
            let v2 = out?.lyrics.lines.filter { $0.agent == "v2" }.count ?? 0
            print("DIAR \(artist): sil \(String(format: "%.2f", out?.separation ?? -1)) duet \(out?.lyrics.isDuet ?? false) v2 lines \(v2)/\(lyrics.lines.count) in \(Int(Date().timeIntervalSince(start)))s")
            if artist.contains("&"), let o = out { for l in o.lyrics.lines where l.agent == "v2" { print("DIAR   v2 \(l.start) \(l.text.prefix(30))") } }
        }
    }
}
