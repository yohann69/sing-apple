import Foundation
import Testing
@testable import SingHost
@testable import SingCore

private let cacheDir = ProcessInfo.processInfo.environment["SING_CACHE_SONG"] ?? ""

@Suite(.enabled(if: !cacheDir.isEmpty))
struct AlignmentTests {
    @Test func upgradesLineSyncedWithSpeech() async throws {
        let dir = URL(fileURLWithPath: cacheDir)
        let lrc = try String(contentsOf: dir.appendingPathComponent("embedded.lrc"), encoding: .utf8)
        let lyrics = try LRCParser.parse(lrc, source: .embedded)
        let start = Date()
        let words = try await SpeechAligner.recognize(vocals: dir.appendingPathComponent("vocals.caf"), language: SpeechAligner.language(for: lyrics, hint: nil))
        let r = LyricsAligner.align(lyrics, recognized: words, duration: 280)
        print("ALIGN recognized \(words.count) words in \(Date().timeIntervalSince(start))s, matched \(Int(r.matchedRatio * 100))% of \(lyrics.lines.reduce(0) { $0 + $1.words.count }) lyric words")
        for l in r.lyrics.lines.prefix(6) {
            print("ALIGN", l.segments.map { String(format: "%.2f", $0.start) }.joined(separator: " "))
        }
        #expect(r.matchedRatio > 0.2)
    }
}
