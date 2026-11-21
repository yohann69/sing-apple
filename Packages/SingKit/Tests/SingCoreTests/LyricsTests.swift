import Foundation
import Testing
@testable import SingCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct TTMLTests {
    @Test func parsesSyllablesDuetsBackgroundAndTranslation() throws {
        let lyrics = try TTMLParser.parse(try fixture("duet.ttml"))
        #expect(lyrics.kind == .syllable)
        #expect(lyrics.language == "en")
        #expect(lyrics.lines.count == 3)
        let first = lyrics.lines[0]
        #expect(first.text == "Every window glows")
        #expect(first.words.count == 3)
        #expect(first.words[0].map(\.text) == ["Ev", "ery"])
        #expect(first.backgroundText == "(glows bright)")
        #expect(first.translation == "Chaque fenêtre")
        #expect(first.agent == "v1")
        #expect(lyrics.lines[1].start == 4)
        #expect(lyrics.lines[2].start == 7)
        #expect(lyrics.agents.first?.name == "Lea")
        #expect(lyrics.isDuet)
    }

    @Test func parsesLineTiming() throws {
        let lyrics = try TTMLParser.parse(try fixture("line.ttml"))
        #expect(lyrics.kind == .line)
        #expect(lyrics.lines[0].start == 10.5)
        #expect(lyrics.lines[0].text == "Hello there friend")
        #expect(!lyrics.isDuet)
    }

    @Test func timeFormats() {
        #expect(TTMLParser.parseTime("1:02.5") == 62.5)
        #expect(TTMLParser.parseTime("01:01:02.5") == 3662.5)
        #expect(TTMLParser.parseTime("12.3s") == 12.3)
        #expect(TTMLParser.parseTime("1500ms") == 1.5)
        #expect(TTMLParser.parseTime("abc") == nil)
    }

    @Test func rejectsGarbage() {
        #expect(throws: (any Error).self) { try TTMLParser.parse(Data("<html></html>".utf8)) }
    }
}

@Suite struct LRCTests {
    @Test func parsesLinesWithEstimatedWords() throws {
        let lrc = "[ar:Someone]\n[00:01.00]Hello world\n[00:03.50]\n[00:10.00][00:20.00]Repeat me\n"
        let lyrics = try LRCParser.parse(lrc, source: .embedded)
        #expect(lyrics.kind == .line)
        #expect(lyrics.lines.map(\.text) == ["Hello world", "Repeat me", "Repeat me"])
        let first = lyrics.lines[0]
        #expect(first.start == 1)
        #expect(first.end <= 3.5)
        #expect(first.segments.count == 2)
        #expect(first.segments[0].start == 1)
        #expect(abs(first.segments[1].end - first.end) < 0.0001)
        #expect(lyrics.lines[2].start == 20)
    }

    @Test func parsesEnhancedLRC() throws {
        let lrc = "[00:01.00]<00:01.00>Hel<00:01.30>lo <00:01.60>world<00:02.40>\n[00:03.00]Next"
        let lyrics = try LRCParser.parse(lrc, source: .lrclib)
        #expect(lyrics.kind == .word)
        let words = lyrics.lines[0].words
        #expect(words.count == 2)
        #expect(words[0].map(\.text) == ["Hel", "lo"])
        #expect(words[1][0].start == 1.6)
        #expect(words[1][0].end == 2.4)
    }

    @Test func offsetTag() throws {
        let lyrics = try LRCParser.parse("[offset:500]\n[00:02.00]Late line", source: .embedded)
        #expect(lyrics.lines[0].start == 1.5)
    }

    @Test func lineLookup() throws {
        let lyrics = try LRCParser.parse("[00:01.00]a\n[00:02.00]b\n[00:03.00]c", source: .embedded)
        #expect(lyrics.lineIndex(at: 0.5) == nil)
        #expect(lyrics.lineIndex(at: 2.1) == 1)
        #expect(lyrics.lineIndex(at: 99) == 2)
    }
}

@Suite struct ProtocolTests {
    @Test func roundTripsMessages() throws {
        let msgs: [ClientMessage] = [.enqueue(.init(songID: 3, singerIDs: [1, 2], playNext: true)), .remove(entryID: "x"), .transport(.skip), .setGuideVocal(0.2), .ping]
        for m in msgs {
            let data = try SingProtocol.encoder().encode(m)
            let back = try SingProtocol.decoder().decode(ClientMessage.self, from: data)
            #expect(try SingProtocol.encoder().encode(back) == data)
        }
        let json = String(decoding: try SingProtocol.encoder().encode(ClientMessage.transport(.play)), as: UTF8.self)
        #expect(json == #"{"data":{"command":"play"},"type":"transport"}"#)
    }

    @Test func settingsToleratesMissingKeys() throws {
        let s = try SingProtocol.decoder().decode(SingSettings.self, from: Data(#"{"tv":{"showPitchGuide":false}}"#.utf8))
        #expect(s.tv.showPitchGuide == false)
        #expect(s.tv.showNextLine == true)
        #expect(s.playback.autoAdvance == true)
    }
}
