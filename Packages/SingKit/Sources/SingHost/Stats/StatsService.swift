import Foundation
import GRDB
import SingCore

public final class StatsService: Sendable {
    let db: SingDatabase

    public init(db: SingDatabase) {
        self.db = db
    }

    public func stats(_ period: StatsPeriod, sessionID: Int64?, now: Date = .now) async throws -> StatsResponse {
        try await db.writer.read { db in
            var whereClause = "1 = 1"
            var args: [any DatabaseValueConvertible] = []
            switch period {
            case .tonight:
                if let sessionID {
                    whereClause = "p.sessionId = ?"
                    args.append(sessionID)
                } else {
                    whereClause = "p.startedAt >= ?"
                    args.append(now.addingTimeInterval(-12 * 3600))
                }
            case .year:
                whereClause = "p.startedAt >= ?"
                args.append(Calendar.current.date(from: Calendar.current.dateComponents([.year], from: now)) ?? now)
            case .allTime: break
            }
            let a = StatementArguments(args.map { $0.databaseValue })
            let counts = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT songId, COUNT(*) n FROM play WHERE songId IS NOT NULL AND skipped = 0 GROUP BY songId").map { ($0["songId"] as Int64, $0["n"] as Int) })

            func songs(_ sql: String) throws -> [RankedSong] {
                try Row.fetchAll(db, sql: sql, arguments: a).compactMap { row in
                    guard let song = try SongRecord.fetchOne(db, key: row["songId"] as Int64) else { return nil }
                    return RankedSong(song: song.summary(playCount: counts[song.id ?? 0] ?? 0), count: row["n"])
                }
            }

            let totals = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) n, COUNT(DISTINCT p.songId) d,
                       COALESCE(SUM((julianday(COALESCE(p.endedAt, p.startedAt)) - julianday(p.startedAt)) * 1440), 0) m
                FROM play p WHERE skipped = 0 AND \(whereClause)
                """, arguments: a)
            let topSongs = try songs("SELECT p.songId, COUNT(*) n FROM play p WHERE p.songId IS NOT NULL AND skipped = 0 AND \(whereClause) GROUP BY p.songId ORDER BY n DESC, MAX(p.startedAt) DESC LIMIT 10")
            let skipped = try songs("SELECT p.songId, COUNT(*) n FROM play p WHERE p.songId IS NOT NULL AND skipped = 1 AND \(whereClause) GROUP BY p.songId ORDER BY n DESC LIMIT 5")
            let artists = try Row.fetchAll(db, sql: "SELECT s.artist name, COUNT(*) n FROM play p JOIN song s ON s.id = p.songId WHERE skipped = 0 AND \(whereClause) GROUP BY s.artist ORDER BY n DESC LIMIT 10", arguments: a).map { RankedName(name: $0["name"], count: $0["n"]) }
            let singers = try Row.fetchAll(db, sql: "SELECT si.name name, si.colorHex color, COUNT(*) n FROM play p JOIN playSinger ps ON ps.playId = p.id JOIN singer si ON si.id = ps.singerId WHERE skipped = 0 AND \(whereClause) GROUP BY si.id ORDER BY n DESC LIMIT 10", arguments: a).map { RankedName(name: $0["name"], count: $0["n"], colorHex: $0["color"]) }
            let decades = try Row.fetchAll(db, sql: "SELECT (s.year / 10) * 10 dec, COUNT(*) n FROM play p JOIN song s ON s.id = p.songId WHERE s.year IS NOT NULL AND skipped = 0 AND \(whereClause) GROUP BY dec ORDER BY dec", arguments: a).map { RankedName(name: "\($0["dec"] as Int)s", count: $0["n"]) }
            let nights = try Row.fetchAll(db, sql: """
                SELECT se.id id, se.startedAt startedAt, COUNT(DISTINCT p.id) plays, COUNT(DISTINCT ps.singerId) singers
                FROM session se JOIN play p ON p.sessionId = se.id LEFT JOIN playSinger ps ON ps.playId = p.id
                WHERE p.skipped = 0 GROUP BY se.id ORDER BY plays DESC LIMIT 5
                """).map { NightSummary(id: $0["id"], startedAt: $0["startedAt"], plays: $0["plays"], singers: $0["singers"]) }
            return StatsResponse(
                period: period, totalPlays: totals?["n"] ?? 0, totalMinutes: Int((totals?["m"] as Double?) ?? 0),
                distinctSongs: totals?["d"] ?? 0, topSongs: topSongs, topArtists: artists, topSingers: singers,
                mostSkipped: skipped, busiestNights: nights, decades: decades
            )
        }
    }

    public func singerStats(_ singerID: SingerID) async throws -> SingerStats? {
        try await db.writer.read { db in
            guard let singer = try SingerRecord.fetchOne(db, key: singerID) else { return nil }
            let plays = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playSinger ps JOIN play p ON p.id = ps.playId WHERE ps.singerId = ? AND p.skipped = 0", arguments: [singerID]) ?? 0
            func songs(_ sql: String) throws -> [RankedSong] {
                try Row.fetchAll(db, sql: sql, arguments: [singerID]).compactMap { row in
                    guard let s = try SongRecord.fetchOne(db, key: row["songId"] as Int64) else { return nil }
                    return RankedSong(song: s.summary(), count: row["n"])
                }
            }
            let top = try songs("SELECT p.songId, COUNT(*) n FROM playSinger ps JOIN play p ON p.id = ps.playId WHERE ps.singerId = ? AND p.skipped = 0 AND p.songId IS NOT NULL GROUP BY p.songId ORDER BY n DESC LIMIT 10")
            let recent = try songs("SELECT p.songId, 1 n FROM playSinger ps JOIN play p ON p.id = ps.playId WHERE ps.singerId = ? AND p.songId IS NOT NULL ORDER BY p.startedAt DESC LIMIT 10")
            return SingerStats(singer: singer.singer, plays: plays, topSongs: top, recent: recent)
        }
    }

    /// Simple, explainable suggestions: favourites not sung lately, more from loved artists, crowd favourites, ready now.
    public func suggestions(for singerID: SingerID?, limit: Int = 20, now: Date = .now) async throws -> [Suggestion] {
        try await db.writer.read { db in
            var out: [Suggestion] = []
            var seen = Set<Int64>()
            let never = Set(try Int64.fetchAll(db, sql: "SELECT songId FROM rating WHERE neverSuggest = 1 AND (? IS NULL OR singerId = ?)", arguments: [singerID, singerID]))
            func add(_ sql: String, _ args: StatementArguments, reason: (Row, SongRecord) -> String) throws {
                for row in try Row.fetchAll(db, sql: sql, arguments: args) {
                    guard out.count < limit, let id = row["songId"] as Int64?, !seen.contains(id), !never.contains(id),
                          let song = try SongRecord.fetchOne(db, key: id), !song.missing else { continue }
                    seen.insert(id)
                    out.append(Suggestion(song: song.summary(), reason: reason(row, song)))
                }
            }
            let weekAgo = now.addingTimeInterval(-7 * 86400)
            if let singerID {
                try add("""
                    SELECT p.songId songId, COUNT(*) n, MAX(p.startedAt) last FROM playSinger ps JOIN play p ON p.id = ps.playId
                    WHERE ps.singerId = ? AND p.skipped = 0 AND p.songId IS NOT NULL GROUP BY p.songId HAVING last < ? ORDER BY n DESC LIMIT 6
                    """, [singerID, weekAgo]) { row, _ in "You sang it \(row["n"] as Int) times, not lately" }
                try add("""
                    SELECT s.id songId, a.artist artist, a.n n FROM song s JOIN (
                      SELECT s2.artist artist, COUNT(*) n FROM playSinger ps JOIN play p ON p.id = ps.playId JOIN song s2 ON s2.id = p.songId
                      WHERE ps.singerId = ? AND p.skipped = 0 GROUP BY s2.artist) a ON a.artist = s.artist
                    WHERE s.id NOT IN (SELECT p.songId FROM playSinger ps JOIN play p ON p.id = ps.playId WHERE ps.singerId = ? AND p.songId IS NOT NULL)
                    ORDER BY a.n DESC, s.readiness = 'ready' DESC LIMIT 6
                    """, [singerID, singerID]) { row, _ in "You love \(row["artist"] as String)" }
            }
            try add("""
                SELECT p.songId songId, COUNT(*) n FROM play p WHERE p.skipped = 0 AND p.songId IS NOT NULL
                GROUP BY p.songId ORDER BY n DESC LIMIT 8
                """, []) { row, _ in "Crowd favourite, sung \(row["n"] as Int) times" }
            try add("SELECT id songId FROM song WHERE readiness = 'ready' AND missing = 0 ORDER BY RANDOM() LIMIT 8", []) { _, _ in "Ready to sing now" }
            try add("SELECT id songId FROM song WHERE missing = 0 AND lastPlayedAt IS NULL ORDER BY addedAt DESC LIMIT 8", []) { _, _ in "Never sung yet" }
            return out
        }
    }
}
