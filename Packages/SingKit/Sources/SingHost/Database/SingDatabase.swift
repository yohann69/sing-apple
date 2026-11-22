import Foundation
import GRDB
import SingCore

public final class SingDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func open(at url: URL) throws -> SingDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: config)
        let needsBackup = try pool.read { db in
            try !Self.migrator.hasCompletedMigrations(db) && !Self.migrator.appliedIdentifiers(db).isEmpty
        }
        if needsBackup { try backup(pool, next: url) }
        return try SingDatabase(writer: pool)
    }

    public static func inMemory() throws -> SingDatabase {
        try SingDatabase(writer: DatabaseQueue())
    }

    private static func backup(_ pool: DatabasePool, next url: URL) throws {
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let dest = url.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let target = try DatabaseQueue(path: dest.appendingPathComponent("sing-before-migration-\(stamp).sqlite").path)
        try pool.backup(to: target)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "song") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("album", .text)
                t.column("durationMs", .integer).notNull()
                t.column("year", .integer)
                t.column("genre", .text)
                t.column("language", .text)
                t.column("isrc", .text).indexed()
                t.column("filePath", .text).notNull()
                t.column("audioHash", .text).notNull().unique()
                t.column("hasArtwork", .boolean).notNull().defaults(to: false)
                t.column("palette", .text)
                t.column("readiness", .text).notNull().defaults(to: Readiness.new.rawValue)
                t.column("lyricsKind", .text)
                t.column("isDuet", .boolean).notNull().defaults(to: false)
                t.column("missing", .boolean).notNull().defaults(to: false)
                t.column("lyricOffsetMs", .integer).notNull().defaults(to: 0)
                t.column("defaultGuideVocal", .double)
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("addedAt", .datetime).notNull()
                t.column("lastPlayedAt", .datetime)
            }
            try db.create(virtualTable: "songFts", using: FTS5()) { t in
                t.synchronize(withTable: "song")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.prefixes = [2, 3]
                t.column("title")
                t.column("artist")
                t.column("album")
            }
            try db.create(table: "singer") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("emoji", .text)
                t.column("colorHex", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("createdByPad", .text)
            }
            try db.create(table: "session") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text)
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
            }
            try db.create(table: "play") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("song", onDelete: .setNull)
                t.belongsTo("session", onDelete: .setNull)
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("percentCompleted", .double).notNull().defaults(to: 0)
                t.column("guideVocal", .double).notNull().defaults(to: 0)
                t.column("keyShift", .integer).notNull().defaults(to: 0)
                t.column("tempo", .double).notNull().defaults(to: 1)
                t.column("score", .double)
                t.column("skipped", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "playSinger") { t in
                t.belongsTo("play", onDelete: .cascade).notNull()
                t.belongsTo("singer", onDelete: .cascade).notNull()
                t.primaryKey(["playId", "singerId"])
            }
            try db.create(table: "queueEvent") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("session", onDelete: .setNull)
                t.column("type", .text).notNull()
                t.column("songId", .integer)
                t.column("singerIds", .text)
                t.column("padId", .text)
                t.column("at", .datetime).notNull()
            }
            try db.create(table: "queueEntry") { t in
                t.primaryKey("id", .text)
                t.column("position", .integer).notNull()
                t.belongsTo("song", onDelete: .cascade).notNull()
                t.column("singerIds", .text).notNull()
                t.column("addedBy", .text)
                t.column("addedAt", .datetime).notNull()
            }
            try db.create(table: "recording") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("play", onDelete: .cascade).notNull()
                t.column("dryPath", .text)
                t.column("wetPath", .text)
                t.column("mixPath", .text)
            }
            try db.create(table: "rating") { t in
                t.belongsTo("song", onDelete: .cascade).notNull()
                t.belongsTo("singer", onDelete: .cascade).notNull()
                t.column("value", .integer).notNull().defaults(to: 0)
                t.column("favorite", .boolean).notNull().defaults(to: false)
                t.column("neverSuggest", .boolean).notNull().defaults(to: false)
                t.primaryKey(["songId", "singerId"])
            }
            try db.create(table: "pad") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("model", .text)
                t.column("tokenHash", .text).notNull().unique()
                t.column("role", .text).notNull()
                t.column("pairedAt", .datetime).notNull()
                t.column("lastSeenAt", .datetime)
                t.column("revoked", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("json", .text).notNull()
            }
        }
        m.registerMigration("v2-recordings") { db in
            try db.alter(table: "recording") { t in
                t.add(column: "createdAt", .datetime)
                t.add(column: "durationMs", .integer).notNull().defaults(to: 0)
                t.add(column: "shareToken", .text)
                t.add(column: "kept", .boolean).notNull().defaults(to: false)
            }
        }
        return m
    }
}
