import AppKit
import SwiftUI
import Testing
@testable import SingCore
@testable import SingDesign

private let outDir = ProcessInfo.processInfo.environment["SING_SNAPSHOTS"] ?? ""

@MainActor
@Suite(.enabled(if: !outDir.isEmpty))
struct SnapshotTests {
    func line(_ id: Int, _ text: String, _ start: Double, agent: String? = nil, bg: String? = nil) -> LyricLine {
        let words = text.split(separator: " ").map(String.init)
        let segs = WordTimingEstimator.segments(words: words, start: start, end: start + 3)
        let bgSegs = bg.map { WordTimingEstimator.segments(words: $0.split(separator: " ").map(String.init), start: start + 1, end: start + 3) } ?? []
        return LyricLine(id: id, start: start, end: start + 3, agent: agent, segments: segs, background: bgSegs)
    }

    func render(_ name: String, _ model: TVStageModel, time: Double) throws {
        let view = TVStageView(model: model) { time }
            .environment(\.singTheme, .ember)
            .frame(width: 1920, height: 1080)
        let r = ImageRenderer(content: view)
        r.scale = 1
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("render failed"); return
        }
        try png.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png"))
    }

    @Test func tvScreens() throws {
        let lea = Singer(id: 1, name: "Léa", colorHex: "#FF8A3D")
        let tom = Singer(id: 2, name: "Tom", colorHex: "#4CC9F0")
        let song = SongSummary(id: 1, title: "Neon Harbor", artist: "The Paper Lanterns", durationMs: 200_000, readiness: .ready, palette: ["#C1ADB5", "#4B6EAA", "#B28681", "#E0D2D5"])
        let solo = Lyrics(kind: .word, source: .manual, lines: [
            line(0, "We kept the lights on for the ships", 10),
            line(1, "Every window whispers your name tonight", 13.2, bg: "your name, your name"),
            line(2, "And I answer from the other side", 16.4),
        ])
        let entry = QueueEntry(song: song, singers: [lea])
        let next = QueueEntry(song: SongSummary(id: 2, title: "Paper Moon", artist: "Someone", durationMs: 180_000), singers: [tom])
        var np = NowPlaying(entry: entry, state: .playing)
        var model = TVStageModel(nowPlaying: np, lyrics: solo, upNext: next, settings: TVDisplaySettings(), artwork: nil, joinURL: "sing://192.168.1.2:47800?code=123456", guestCode: "123456", preparingProgress: 0.42, countdownEnd: nil, duration: 200, queuePreview: [next])
        var notes: [PitchNote] = []
        var t = 8.0
        for (i, m) in [60, 62, 64, 64, 67, 65, 64, 62, 60, 62, 64, 67, 69, 67, 64, 62, 60, 59, 60, 62].enumerated() {
            let d = [0.4, 0.3, 0.6, 0.25][i % 4]
            notes.append(PitchNote(start: t, end: t + d, midi: Float(m)))
            t += d + 0.12
        }
        model.pitch = PitchTrack(notes: notes)
        let livePts = stride(from: 12.0, to: 14.6, by: 0.033).map { x -> LivePitchPoint in
            let target = model.pitch!.note(at: x)?.midi ?? 62
            return LivePitchPoint(time: x, midi: target + Float(sin(x * 7) * 0.6), onTarget: true)
        }
        model.live = { (livePts, 87) }
        try render("tv-solo", model, time: 14.6)

        let duet = Lyrics(kind: .word, source: .manual, agents: [Agent(id: "v1"), Agent(id: "v2")], lines: [
            line(0, "Every window whispers your name tonight", 13.2, agent: "v1"),
            line(1, "And I answer from the other side", 16.4, agent: "v2"),
        ])
        model.lyrics = duet
        np.entry = QueueEntry(song: song, singers: [lea, tom])
        model.nowPlaying = np
        try render("tv-duet", model, time: 17.5)

        if let path = ProcessInfo.processInfo.environment["SING_PITCH"], let d = try? Data(contentsOf: URL(fileURLWithPath: path)), let real = try? JSONDecoder().decode(PitchTrack.self, from: d) {
            model.pitch = real.version >= 2 ? real : real.simplified()
            model.live = { ([], nil) }
            try render("tv-pitch-real", model, time: 60)
        }
        model.nowPlaying.state = .finished
        model.result = PerformanceResult(entryID: "x", songTitle: "Neon Harbor", artist: "x", singers: [lea], total: 87, grade: "A", title: "Pitch perfect", comment: "Great run. Only dynamics kept it from the top.",
            categories: [ScoreCategory(name: "Pitch", value: 91, note: "Right on the notes"), ScoreCategory(name: "Rhythm", value: 84, note: "Locked to the beat"), ScoreCategory(name: "Stability", value: 78, note: "Some wobble on long notes"), ScoreCategory(name: "Dynamics", value: 70, note: "Try more contrast"), ScoreCategory(name: "Coverage", value: 92, note: "Sang 230 of 250 notes")],
            badges: ["Pitch 91"], leaderboard: [RankedName(name: "Léa", count: 87, colorHex: "#FF8A3D"), RankedName(name: "Tom", count: 81, colorHex: "#4CC9F0")], endedAt: Date().addingTimeInterval(-7))
        try render("tv-result", model, time: 0)
        model.nowPlaying.state = .idle
        try render("tv-idle", model, time: 0)
        model.nowPlaying.state = .preparing
        try render("tv-preparing", model, time: 0)
        model.nowPlaying.state = .playing
        model.lyrics = solo
        try render("tv-gap", model, time: 8.5)
    }
}
