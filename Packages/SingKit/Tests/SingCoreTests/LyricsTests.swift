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

@Suite struct WordSyncedTests {
    @Test func yrc() throws {
        let text = """
        {"t":0,"c":[{"tx":"作词: "},{"tx":"Someone"}]}
        [8550,3990](8550,360,0)Do (8910,390,0)you (9300,300,0)ever
        [12600,2000](12600,500,0)Hel(13100,400,0)lo (13500,600,0)there
        [15000,1000](15000,1000,0)Bye
        """
        let l = try #require(WordSyncedParser.parseYRC(text, source: .netease))
        #expect(l.lines.count == 3)
        #expect(l.kind == .syllable)
        #expect(l.lines[0].text == "Do you ever")
        #expect(l.lines[1].words[0].map(\.text) == ["Hel", "lo"])
        #expect(l.lines[0].segments[1].start == 8.91)
    }

    @Test func krc() throws {
        let text = "[ti:x]\n[1000,2000]<0,500,0>Un <500,500,0>deux\n[4000,1000]<0,1000,0>trois\n[6000,1000]<0,400,0>quatre <400,600,0>cinq"
        let l = try #require(WordSyncedParser.parseKRC(text, source: .kugou))
        #expect(l.kind == .word)
        #expect(l.lines[0].segments[1].start == 1.5)
        #expect(l.lines[2].text == "quatre cinq")
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["SING_NETWORK"] != nil))
struct ProviderNetworkTests {
    @Test func netease() async throws {
        let l = try await NetEaseProvider().fetch(LyricsQuery(title: "Firework", artist: "Katy Perry", durationMs: 227_893))
        #expect(l?.kind ?? .plain >= .word)
    }

    @Test func kugou() async throws {
        let l = try await KugouProvider().fetch(LyricsQuery(title: "Désolé", artist: "Sexion d'Assaut", durationMs: 204_453))
        #expect(l?.kind ?? .plain >= .word)
        #expect((l?.lines.count ?? 0) > 20)
    }
}

@Suite struct AlignerTests {
    @Test func alignsRecognizedWordsAndFillsGaps() throws {
        let lyrics = try LRCParser.parse("[00:10.00]hello there my friend\n[00:20.00]we sing all night", source: .embedded)
        let rec = [
            TimedWord(text: "Hello", start: 10.4, end: 10.8), TimedWord(text: "their", start: 10.9, end: 11.3),
            TimedWord(text: "friend", start: 12.0, end: 12.6), TimedWord(text: "noise", start: 15, end: 15.2),
            TimedWord(text: "we", start: 20.2, end: 20.4), TimedWord(text: "sing", start: 20.5, end: 21.0), TimedWord(text: "night", start: 21.8, end: 22.5),
        ]
        let r = LyricsAligner.align(lyrics, recognized: rec, duration: 30)
        #expect(r.lyrics.kind >= .word)
        #expect(r.lyrics.source == .ai)
        let w0 = r.lyrics.lines[0].words.map { $0[0] }
        #expect(w0[0].start == 10.4)
        #expect(w0[1].start == 10.9)
        #expect(w0[2].start >= 11.3 && w0[2].start < 12.0)
        #expect(w0[3].start == 12.0)
        let w1 = r.lyrics.lines[1].words.map { LyricSegment(text: "", start: $0[0].start, end: $0.last!.end, endsWord: true) }
        #expect(w1[2].start >= 21.0 && w1[2].end <= 21.8 + 0.001)
        #expect(r.matchedRatio > 0.6)
        for l in r.lyrics.lines { for (a, b) in zip(l.segments, l.segments.dropFirst()) { #expect(a.start <= b.start) } }
    }
}

@Suite struct ScoreTests {
    @Test func perfectAndSilentSinging() throws {
        let notes = (0..<10).map { PitchNote(start: Double($0), end: Double($0) + 0.8, midi: 60 + Float($0 % 3)) }
        let track = PitchTrack(notes: notes)
        var good = ScoreKeeper()
        var t = 0.0
        while t < 10 {
            let n = track.note(at: t)
            good.add(time: t, sungMidi: n.map { $0.midi - 12 }, level: n == nil ? 0 : Float(0.2 + 0.2 * sin(t)))
            t += 0.033
        }
        let r = try #require(good.result(track: track, upTo: 10))
        #expect(r.total > 85)
        #expect(r.categories.first { $0.name == "Pitch" }?.value == 100)

        var off = ScoreKeeper()
        t = 0
        while t < 10 { off.add(time: t, sungMidi: 66, level: 0.3); t += 0.033 }
        let r2 = try #require(off.result(track: track, upTo: 10))
        #expect(r2.total < r.total)
        #expect(ScoreKeeper().result(track: track, upTo: 10) == nil)
    }
}

@Suite struct PitchSimplifyTests {
    @Test func mergesSyllablesIntoTrendBars() {
        let notes = [
            PitchNote(start: 0, end: 0.2, midi: 60.2), PitchNote(start: 0.25, end: 0.45, midi: 61.4), PitchNote(start: 0.5, end: 0.9, midi: 60.8),
            PitchNote(start: 1.5, end: 1.6, midi: 70),
            PitchNote(start: 2.0, end: 2.3, midi: 67), PitchNote(start: 2.35, end: 2.9, midi: 66),
        ]
        let s = PitchTrack(notes: notes).simplified()
        #expect(s.notes.count == 2)
        #expect(s.notes[0].start == 0 && s.notes[0].end == 0.9)
        #expect(s.notes[0].midi == 61)
        #expect(s.notes[1].midi == 66)
    }
}

struct NewFormatTests {
    @Test func ttmlWriterRoundTrips() throws {
        let segs = [LyricSegment(text: "Hel", start: 1, end: 1.3, endsWord: false), LyricSegment(text: "lo ", start: 1.3, end: 1.6, endsWord: true), LyricSegment(text: "world", start: 1.7, end: 2.2, endsWord: true)]
        var line = LyricLine(id: 0, start: 1, end: 2.2, agent: "v1", segments: segs)
        line.translation = "Bonjour le monde"
        let l = Lyrics(kind: .syllable, source: .ai, language: "en", agents: [Agent(id: "v1", name: "Léa")], lines: [line, LyricLine(id: 1, start: 3, end: 4, agent: "v1", segments: [LyricSegment(text: "again", start: 3, end: 4, endsWord: true)])])
        let back = try TTMLParser.parse(TTMLWriter.write(l, title: "T", artist: "A"))
        #expect(back.kind == .syllable)
        #expect(back.lines.count == 2)
        #expect(back.lines[0].text.trimmingCharacters(in: .whitespaces) == "Hello world")
        #expect(abs(back.lines[0].segments[1].start - 1.3) < 0.01)
        #expect(back.lines[0].translation == "Bonjour le monde")
        #expect(back.agents.first?.name == "Léa")
    }

    @Test func parsesQRCAndRichsync() {
        let qrc = "[1000,2000]Hel(1000,300)lo (1300,300)world(1700,500)\n[4000,1000]a(4000,200)b(4200,200)\n[6000,1000]c(6000,500)\n"
        let q = WordSyncedParser.parseQRC(qrc, source: .qq)
        #expect(q?.lines.count == 3)
        #expect(q?.lines[0].segments.count == 3)
        let rs = #"[{"ts":1.0,"te":2.0,"x":"hi you","l":[{"c":"h","o":0},{"c":"i","o":0.1},{"c":" ","o":0.3},{"c":"you","o":0.4}]}]"#
        let m = WordSyncedParser.parseMusixmatchRichsync(rs)
        #expect(m?.lines.first?.segments.map { $0.text.trimmingCharacters(in: .whitespaces) } == ["hi", "you"])
    }

    @Test func hyphenatesFrench() {
        #expect(Hyphenator.syllables("magnifique", language: "fr").count >= 3)
    }
}

struct SplitTests {
    @Test func longLinesAreCutAtWords() throws {
        let l = try LRCParser.parse("[00:10.00]one two three four five six seven eight nine ten eleven twelve\n[00:20.00]short line", source: .embedded)
        let s = l.splitForDisplay(maxChars: 20)
        #expect(s.lines.count == 5)
        #expect(s.lines.allSatisfy { $0.text.count <= 26 })
        #expect(s.lines[0].start == 10)
        #expect(s.lines[1].start > s.lines[0].start)
        #expect(s.lines.last?.text == "short line")
    }
}
