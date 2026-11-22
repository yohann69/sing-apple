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
