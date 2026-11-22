import Foundation
import Testing
@testable import SingHost
import SingCore

struct QueueTests {
    func entry(_ singer: Singer, _ title: String) -> QueueEntry {
        QueueEntry(song: SongSummary(id: 1, title: title, artist: "", durationMs: 1000), singers: [singer])
    }

    @Test func fairRotationInterleavesSingers() throws {
        let a = Singer(id: 1, name: "A", colorHex: "#fff"), b = Singer(id: 2, name: "B", colorHex: "#fff"), c = Singer(id: 3, name: "C", colorHex: "#fff")
        var q = QueueModel()
        for t in ["a1", "a2", "a3"] { try q.add(entry(a, t), fairRotation: true) }
        try q.add(entry(b, "b1"), fairRotation: true)
        try q.add(entry(b, "b2"), fairRotation: true)
        try q.add(entry(c, "c1"), fairRotation: true)
        #expect(q.entries.map(\.song.title) == ["a1", "b1", "c1", "a2", "b2", "a3"])
    }

    @Test func plainQueueAppends() throws {
        let a = Singer(id: 1, name: "A", colorHex: "#fff"), b = Singer(id: 2, name: "B", colorHex: "#fff")
        var q = QueueModel()
        try q.add(entry(a, "a1"))
        try q.add(entry(a, "a2"))
        try q.add(entry(b, "b1"))
        #expect(q.entries.map(\.song.title) == ["a1", "a2", "b1"])
    }
}

import AVFoundation

struct RecordingMixTests {
    func tone(_ url: URL, freq: Float, seconds: Double) throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let f = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = AVAudioFrameCount(seconds * 48000)
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        b.frameLength = n
        for c in 0..<2 { for i in 0..<Int(n) { b.floatChannelData![c][i] = 0.2 * sin(2 * .pi * freq * Float(i) / 48000) } }
        try f.write(from: b)
    }

    @Test func mixesVoiceOverMusicIntoAAC() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try tone(dir.appendingPathComponent("m.caf"), freq: 220, seconds: 3)
        try tone(dir.appendingPathComponent("v.caf"), freq: 440, seconds: 3)
        let out = dir.appendingPathComponent("mix.m4a")
        let d = try RecordingMixer.mix(music: dir.appendingPathComponent("m.caf"), voice: dir.appendingPathComponent("v.caf"), to: out, voiceDelay: 0.1)
        #expect(abs(d - 3) < 0.05)
        let read = try AVAudioFile(forReading: out)
        #expect(read.length > 140_000)
    }

    @Test func servesByteRanges() {
        let data = Data((0..<100).map { UInt8($0) })
        let req = HTTPRequest(method: "GET", path: "/x", query: [:], headers: ["range": "bytes=10-19"], body: Data())
        let r = SingServer.audio(data, req)
        #expect(r.status == 206)
        #expect(r.body == data.subdata(in: 10..<20))
        #expect(r.extraHeaders["Content-Range"] == "bytes 10-19/100")
    }
}

struct HumSearchTests {
    func track(_ midis: [Float]) -> PitchTrack {
        PitchTrack(notes: midis.enumerated().map { PitchNote(start: Double($0.offset) * 0.4, end: Double($0.offset) * 0.4 + 0.3, midi: $0.element) })
    }

    @Test func findsTransposedPhrase() {
        var g = SystemRandomNumberGenerator()
        let songs: [(SongID, PitchTrack)] = (1...20).map { id in (Int64(id), track((0..<80).map { _ in Float(Int.random(in: 55...72, using: &g)) })) }
        let target = songs[7].1.notes[30..<40].map { $0.midi + 3 }
        let r = HumSearch.rank(hum: track(target), songs: songs)
        #expect(r.first?.0 == 8)
    }
}
