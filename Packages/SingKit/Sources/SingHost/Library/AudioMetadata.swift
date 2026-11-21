import AVFoundation
import Foundation

public struct AudioMetadata: Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var year: Int?
    public var genre: String?
    public var isrc: String?
    public var language: String?
    public var durationMs: Int = 0
    public var artwork: Data?
    public var syncedLyrics: String?
    public var plainLyrics: String?
}

public enum AudioMetadataReader {
    public static let supportedExtensions: Set<String> = ["mp3", "flac", "wav", "m4a", "aac", "aif", "aiff", "caf", "alac"]

    public static func read(_ url: URL) async throws -> AudioMetadata {
        var meta = url.pathExtension.lowercased() == "flac" ? ((try? FLACReader.read(url)) ?? AudioMetadata()) : AudioMetadata()
        let asset = AVURLAsset(url: url)
        if meta.durationMs == 0, let d = try? await asset.load(.duration), d.isNumeric {
            meta.durationMs = Int(d.seconds * 1000)
        }
        if meta.durationMs == 0, let file = try? AVAudioFile(forReading: url) {
            meta.durationMs = Int(Double(file.length) / file.fileFormat.sampleRate * 1000)
        }
        if url.pathExtension.lowercased() != "flac" {
            let items = (try? await asset.load(.metadata)) ?? []
            for item in items {
                let key = item.identifier?.rawValue ?? ""
                let common = item.commonKey?.rawValue
                let str = try? await item.load(.stringValue)
                switch common {
                case "title": meta.title = meta.title ?? str
                case "artist": meta.artist = meta.artist ?? str
                case "albumName": meta.album = meta.album ?? str
                case "type": meta.genre = meta.genre ?? str
                case "language": meta.language = meta.language ?? str
                case "creationDate": meta.year = meta.year ?? str.flatMap { Int($0.prefix(4)) }
                case "artwork":
                    if meta.artwork == nil { meta.artwork = try? await item.load(.dataValue) }
                default: break
                }
                if key.hasSuffix("TSRC") || key.lowercased().contains("isrc") { meta.isrc = meta.isrc ?? str }
                if key.hasSuffix("USLT") || key.hasSuffix("%A9lyr"), let lyr = str { assignLyrics(lyr, to: &meta) }
                if key.hasSuffix("TYER") || key.hasSuffix("TDRC") { meta.year = meta.year ?? str.flatMap { Int($0.prefix(4)) } }
            }
        }
        if meta.title == nil || meta.artist == nil {
            let parsed = parseFilename(url.deletingPathExtension().lastPathComponent)
            meta.title = meta.title ?? parsed.title
            meta.artist = meta.artist ?? parsed.artist
        }
        return meta
    }

    static func assignLyrics(_ text: String, to meta: inout AudioMetadata) {
        if text.range(of: #"\[\d{1,2}:\d{2}"#, options: .regularExpression) != nil {
            meta.syncedLyrics = meta.syncedLyrics ?? text
        } else {
            meta.plainLyrics = meta.plainLyrics ?? text
        }
    }

    /// "01 - Artist - Title", "Artist - Title", "07 Title".
    public static func parseFilename(_ name: String) -> (artist: String?, title: String) {
        var stem = name.trimmingCharacters(in: .whitespaces)
        if let r = stem.range(of: #"^\d{1,3}[\s._-]+"#, options: .regularExpression) {
            stem.removeSubrange(r)
        }
        let parts = stem.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.count >= 2 { return (parts[0], parts.dropFirst().joined(separator: " - ")) }
        return (nil, stem)
    }
}

/// Reads STREAMINFO, VORBIS_COMMENT and PICTURE blocks of a FLAC file.
enum FLACReader {
    static func read(_ url: URL) throws -> AudioMetadata {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data("fLaC".utf8) else { throw CocoaError(.fileReadCorruptFile) }
        var meta = AudioMetadata()
        var last = false
        while !last {
            guard let header = try handle.read(upToCount: 4), header.count == 4 else { break }
            last = header[0] & 0x80 != 0
            let type = header[0] & 0x7F
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            guard let block = try handle.read(upToCount: length), block.count == length else { break }
            switch type {
            case 0: parseStreamInfo(block, into: &meta)
            case 4: parseVorbis(block, into: &meta)
            case 6: if meta.artwork == nil { meta.artwork = parsePicture(block) }
            default: break
            }
        }
        return meta
    }

    private static func parseStreamInfo(_ b: Data, into meta: inout AudioMetadata) {
        guard b.count >= 18 else { return }
        let bytes = [UInt8](b)
        let sampleRate = Int(bytes[10]) << 12 | Int(bytes[11]) << 4 | Int(bytes[12]) >> 4
        let total = (UInt64(bytes[13] & 0x0F) << 32) | UInt64(bytes[14]) << 24 | UInt64(bytes[15]) << 16 | UInt64(bytes[16]) << 8 | UInt64(bytes[17])
        if sampleRate > 0 { meta.durationMs = Int(Double(total) / Double(sampleRate) * 1000) }
    }

    private static func parseVorbis(_ b: Data, into meta: inout AudioMetadata) {
        var r = LEReader(data: b)
        guard let vendorLen = r.u32(), r.skip(Int(vendorLen)), let count = r.u32() else { return }
        var artists: [String] = []
        for _ in 0..<count {
            guard let len = r.u32(), let raw = r.bytes(Int(len)), let s = String(data: raw, encoding: .utf8),
                  let eq = s.firstIndex(of: "=") else { continue }
            let key = s[..<eq].uppercased()
            let value = String(s[s.index(after: eq)...])
            switch key {
            case "TITLE": meta.title = meta.title ?? value
            case "ARTIST": artists.append(value)
            case "ALBUM": meta.album = meta.album ?? value
            case "GENRE": meta.genre = meta.genre ?? value
            case "ISRC": meta.isrc = meta.isrc ?? value
            case "LANGUAGE": meta.language = meta.language ?? value
            case "DATE", "YEAR": meta.year = meta.year ?? Int(value.prefix(4))
            case "SYNCEDLYRICS": meta.syncedLyrics = meta.syncedLyrics ?? value
            case "LYRICS", "UNSYNCEDLYRICS": AudioMetadataReader.assignLyrics(value, to: &meta)
            default: break
            }
        }
        if !artists.isEmpty {
            let split = artists.flatMap { $0.components(separatedBy: ";") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            meta.artist = split.count > 1 ? split.dropLast().joined(separator: ", ") + " & " + split.last! : split.first
        }
    }

    private static func parsePicture(_ b: Data) -> Data? {
        var r = BEReader(data: b)
        guard r.u32() != nil, let mimeLen = r.u32(), r.skip(Int(mimeLen)), let descLen = r.u32(), r.skip(Int(descLen)),
              r.skip(16), let len = r.u32(), let data = r.bytes(Int(len)) else { return nil }
        return data
    }

    struct LEReader {
        let data: Data
        var offset = 0
        mutating func u32() -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            let s = data.startIndex + offset
            defer { offset += 4 }
            return UInt32(data[s]) | UInt32(data[s + 1]) << 8 | UInt32(data[s + 2]) << 16 | UInt32(data[s + 3]) << 24
        }
        mutating func skip(_ n: Int) -> Bool {
            guard offset + n <= data.count else { return false }
            offset += n
            return true
        }
        mutating func bytes(_ n: Int) -> Data? {
            guard offset + n <= data.count else { return nil }
            defer { offset += n }
            return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + n))
        }
    }

    struct BEReader {
        let data: Data
        var offset = 0
        mutating func u32() -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            let s = data.startIndex + offset
            defer { offset += 4 }
            return UInt32(data[s]) << 24 | UInt32(data[s + 1]) << 16 | UInt32(data[s + 2]) << 8 | UInt32(data[s + 3])
        }
        mutating func skip(_ n: Int) -> Bool {
            guard offset + n <= data.count else { return false }
            offset += n
            return true
        }
        mutating func bytes(_ n: Int) -> Data? {
            guard offset + n <= data.count else { return nil }
            defer { offset += n }
            return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + n))
        }
    }
}
