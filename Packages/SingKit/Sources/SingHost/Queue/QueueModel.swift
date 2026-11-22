import Foundation
import SingCore

public enum QueueError: Error, Equatable, LocalizedError {
    case notFound
    case limitReached(Int)
    case notAllowed

    public var errorDescription: String? {
        switch self {
        case .notFound: "That song is no longer in the queue."
        case .limitReached(let n): "Each singer can queue up to \(n) songs."
        case .notAllowed: "Only the host can do that."
        }
    }
}

/// Pure queue rules, kept free of I/O so they are easy to test.
public struct QueueModel: Sendable, Equatable {
    public private(set) var entries: [QueueEntry] = []

    public init(entries: [QueueEntry] = []) {
        self.entries = entries
    }

    public mutating func add(_ entry: QueueEntry, playNext: Bool = false, maxPerSinger: Int = 0, fairRotation: Bool = false) throws {
        if maxPerSinger > 0 {
            for singer in entry.singers {
                let count = entries.filter { $0.singers.contains { $0.id == singer.id } }.count
                if count >= maxPerSinger { throw QueueError.limitReached(maxPerSinger) }
            }
        }
        if playNext {
            entries.insert(entry, at: 0)
        } else if fairRotation {
            entries.insert(entry, at: fairIndex(for: entry))
        } else {
            entries.append(entry)
        }
    }

    /// Round-robin slot: after every other singer's song of the same round.
    func fairIndex(for entry: QueueEntry) -> Int {
        let key = Self.rotationKey(entry)
        let round = entries.filter { Self.rotationKey($0) == key }.count
        var seen: [String: Int] = [:]
        for (i, e) in entries.enumerated() {
            let k = Self.rotationKey(e)
            let r = seen[k, default: 0]
            seen[k] = r + 1
            if r > round { return i }
        }
        return entries.count
    }

    static func rotationKey(_ e: QueueEntry) -> String {
        if !e.singers.isEmpty { return e.singers.map { String($0.id) }.sorted().joined(separator: "+") }
        return e.addedBy ?? "anyone"
    }

    @discardableResult
    public mutating func remove(_ id: String) throws -> QueueEntry {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { throw QueueError.notFound }
        return entries.remove(at: i)
    }

    public mutating func move(_ id: String, to index: Int) throws {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { throw QueueError.notFound }
        let e = entries.remove(at: i)
        entries.insert(e, at: max(0, min(index, entries.count)))
    }

    public mutating func popNext() -> QueueEntry? {
        entries.isEmpty ? nil : entries.removeFirst()
    }

    /// Fills `estimatedStart` from song durations, the current song's remaining time and a gap between songs.
    public func withEstimates(now: Date = .now, remainingCurrent: TimeInterval, gap: TimeInterval = 8) -> [QueueEntry] {
        var t = now.addingTimeInterval(remainingCurrent + (remainingCurrent > 0 ? gap : 0))
        return entries.map { e in
            var copy = e
            copy.estimatedStart = t
            t = t.addingTimeInterval(Double(e.song.durationMs) / 1000 + gap)
            return copy
        }
    }

    /// How many songs before this singer is up next, if they are in the queue.
    public func songsAway(singer: SingerID) -> Int? {
        entries.firstIndex { $0.singers.contains { $0.id == singer } }
    }
}
